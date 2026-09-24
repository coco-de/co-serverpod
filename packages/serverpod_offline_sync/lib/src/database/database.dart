// The Database type is implemented here as a test-style proxy; some lints
// flag internal Serverpod APIs used by generated code.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:meta/meta.dart' show internal;
import 'package:serverpod_database/serverpod_database.dart';
import 'package:serverpod_serialization/serverpod_serialization.dart'
    show SerializationManager;
import 'package:uuid/uuid.dart';

import '../crdt/extensions.dart';
import '../crdt/merge.dart';
import '../generated/protocol.dart';
import '../hlc/hlc.dart';
import '../spaces/membership.dart';
import '../sync/engine.dart';
import '../sync/exceptions.dart';
import '../sync/integrity_violation.dart';
import 'merge_utils/database_helpers.dart';
import 'recorder.dart';
import 'session.dart';
import 'tombstone.dart';
import 'unsent_row_count.dart';

part 'space.dart';

/// Map of transaction hashes to the space they are associated with.
final spaceForTransaction = <Transaction, OfflineSyncSpace>{};

/// Map of transaction hashes to the authenticated user associated with them.
final userForTransaction = <Transaction, UuidValue>{};

/// Database proxy that runs insert/update/delete ORM operations inside a
/// transaction to record each change in the CRDT tables.
class OfflineSyncDatabase implements Database {
  /// Creates a CRDT-aware database wrapper around the inner database.
  OfflineSyncDatabase(
    Database delegate, {

    /// The list of tables to sync with CRDT.
    required List<Table> syncTables,

    /// Shared CRDT database metadata.
    OfflineSyncDatabaseContext? context,

    /// Maximum number of merge changes sent in one sync stream message.
    int syncBatchSize = OfflineSyncEngine.defaultSyncBatchSize,

    /// Delay between continuous sync rounds.
    Duration continuousSyncInterval = OfflineSyncEngine.defaultContinuousSyncInterval,

    /// The user ID to use for all CRDT operations. This should only be used for
    /// databases operating on the client side, where all data is for the same user.
    /// Otherwise, the user ID must be passed through the transaction.
    UuidValue? persistentUserId,

    /// The maximum clock drift, see [OfflineSyncDatabaseContext.maxClockDrift].
    /// Configures the new context when `context` is null. When `context` is
    /// given, a different value throws [ArgumentError].
    Duration? maxClockDrift,
  }) : this._(
         delegate,
         OfflineSyncDatabaseContext.resolve(
           context,
           syncTables: syncTables,
           serializationManager: delegate.serializationManager,
           maxClockDrift: maxClockDrift,
         ),
         syncTables: syncTables,
         syncBatchSize: syncBatchSize,
         continuousSyncInterval: continuousSyncInterval,
         persistentUserId: persistentUserId,
       );

  OfflineSyncDatabase._(
    this._delegate,
    this._context, {
    required this._syncTables,
    required this._syncBatchSize,
    required this._continuousSyncInterval,
    required UuidValue? persistentUserId,
  }) : _recorder = CrdtMutationRecorder(
         _delegate,
         context: _context,
         persistentUserId: persistentUserId,
       ) {
    // Fork (unibook#14218): a persistent user makes this a device, whose
    // spaces share the install's node. Every other database gives each space
    // its own node, see [OfflineSyncDatabaseContext.assignsNodePerSpace].
    if (persistentUserId != null) _context.bindPersistentUser();
  }

  final Database _delegate;
  final OfflineSyncDatabaseContext _context;
  final List<Table> _syncTables;
  final int _syncBatchSize;
  final Duration _continuousSyncInterval;

  final CrdtMutationRecorder _recorder;

  late final _sync = OfflineSyncEngine(
    syncTables: _syncTables,
    serializationManager: serializationManager,
    syncBatchSize: _syncBatchSize,
    continuousSyncInterval: _continuousSyncInterval,
    databaseContext: _context,
  );

  /// The maximum clock drift this database accepts, see
  /// [OfflineSyncDatabaseContext.maxClockDrift].
  Duration get maxClockDrift => _context.maxClockDrift;

  /// Initializes the CRDT database.
  Future<void> initialize() async {
    await _recorder.initialize();
  }

  Future<void> _ensureInitialized() async {
    await _recorder.ensureInitialized();
  }

  /// The hash describing the synchronized schema configured for this database.
  String get syncTablesHash => _sync.currentSyncTablesHash;

  /// Returns the current node identifier for the effective user.
  ///
  /// On a device every space shares this node. On a server each space has its
  /// own node (unibook#14218), and this is the node of the user's personal
  /// space.
  Future<UuidValue> currentNodeId({UuidValue? userId}) async {
    await _ensureInitialized();
    final effectiveUserId = await _requireUserId(userId);
    final user = await _recorder.getOrCreateSpace(effectiveUserId);
    return user.currentNode!.uuidNodeId;
  }

  /// Runs a symmetric CRDT sync session over a bidirectional event stream.
  Stream<OfflineSyncStreamEvent> sync({
    required Stream<OfflineSyncStreamEvent> inbound,
    required OfflineSyncPeerMode mode,
    UuidValue? userId,
    bool once = false,
    OfflineSyncOnMergeSuccess? onMergeSuccess,
  }) async* {
    await _ensureInitialized();
    final effectiveUserId = await _requireUserId(userId);
    yield* _sync.sync(
      _delegate.session,
      userId: effectiveUserId,
      inbound: inbound,
      once: once,
      onMergeSuccess: onMergeSuccess,
      mode: mode,
    );
  }

  /// Records the latest acknowledged sync checkpoint for [otherNodeId].
  Future<void> recordSyncCheckpoint(
    UuidValue otherNodeId,
    Hlc syncedHlc, {
    UuidValue? userId,
  }) async {
    await _ensureInitialized();
    final effectiveUserId = await _requireUserId(userId);
    await _recorder.recordSyncCheckpoint(
      effectiveUserId,
      otherNodeId,
      syncedHlc,
    );
  }

  /// Sets the checkpoint recorded for [nodeId] to [hlc], even when that moves
  /// it back or clears it, see [CrdtMutationRecorder.replaceSyncCheckpoint].
  @internal
  Future<void> replaceSyncCheckpoint(
    UuidValue nodeId,
    Hlc? hlc, {
    UuidValue? userId,
  }) async {
    await _ensureInitialized();
    final effectiveUserId = await _requireUserId(userId);
    await _recorder.replaceSyncCheckpoint(effectiveUserId, nodeId, hlc);
  }

  /// The tables whose commits can change [unsentRowCount].
  static final Set<String> _unsentRowCountTables = {
    CrdtDataRow.t.tableName,
    CrdtDataField.t.tableName,
    CrdtDataDeleted.t.tableName,
    OfflineSyncSpaceNode.t.tableName,
  };

  /// Counts the rows of the synchronized tables that hold a change this node
  /// wrote and the server has not confirmed yet.
  ///
  /// Meant for a device (a follower with a persistent user), for example to
  /// warn before signing out. A row counts once however many of its changes
  /// are pending: an insert, updated fields, and a synced delete. A row
  /// inserted and deleted before any sync still counts, since both are sent.
  /// Changes this node received from other nodes never count.
  ///
  /// "Confirmed" is what the device recorded from the server, not what it
  /// sent (the protocol has no acknowledgement):
  ///
  /// * the checkpoint the server reports for this node when a sync session
  ///   starts (its persisted `lastReceivedHlc`), replacing the recorded one,
  /// * the changes sent in a `once` session that the server closed
  ///   symmetrically, since the server closes only after merging them,
  /// * this node's changes the server sent back.
  ///
  /// So the count never undercounts what the engine will send next, and it can
  /// overcount until the next successful session: after a failed round the
  /// server merged anyway, and during a continuous session, whose rounds have
  /// no end the server confirms. Rows this node wrote in a space the server no
  /// longer syncs with this user keep counting, since nothing will send them.
  ///
  /// The checkpoints are read before the rows and again after them. When one
  /// went back in between (a server that lost data), the count runs again from
  /// the lower ones. So a sync that commits while the count runs can make it
  /// high, never low. Local writes that commit while it runs may or may not
  /// count: recount after them.
  Future<int> unsentRowCount() async {
    await _ensureInitialized();
    return _sync.countUnsentRows(
      _delegate.session,
      localNodeId: await currentNodeId(),
    );
  }

  /// Emits once on listen and again after commits that can change
  /// [unsentRowCount], at most once per [throttle].
  ///
  /// A commit to a synchronized table always triggers an event, whether or not
  /// the count changed. Use it to recount yourself; [watchUnsentRowCount]
  /// does the counting.
  ///
  /// Only supported on SQLite. The delegate throws [UnsupportedError]
  /// otherwise.
  Stream<void> watchUnsentRowCountTriggers({
    Duration? throttle = const Duration(milliseconds: 250),
  }) {
    return _delegate
        .unsafeWatch(
          'SELECT 1',
          triggerOnTables: _unsentRowCountTables,
          throttle: throttle,
        )
        .map((_) {});
  }

  /// Emits [unsentRowCount] on listen and again whenever it changes, including
  /// after local writes made while offline.
  ///
  /// Counts run one at a time, each after the commit that triggered it. A
  /// failed count is emitted as an error and the stream goes on.
  ///
  /// Only supported on SQLite. The delegate throws [UnsupportedError]
  /// otherwise.
  Stream<int> watchUnsentRowCount({
    Duration? throttle = const Duration(milliseconds: 250),
  }) {
    return countOnEachTrigger(
      watchUnsentRowCountTriggers(throttle: throttle),
      unsentRowCount,
    );
  }

  /// Merges remote CRDT changes into the local database for the given space.
  ///
  /// When [spaceId] is omitted, this uses the recorder's persistent user id.
  /// The merge locks the current space's CRDT tables and executes atomically
  /// inside [transactionForUser].
  Future<void> mergeChanges(
    CrdtMergeSet mergeSet, {
    UuidValue? spaceId,
  }) async {
    if (mergeSet.isEmpty) return;
    await _ensureInitialized();

    final effectiveSpaceId =
        spaceId ??
        _recorder.persistentUserId ??
        (throw StateError(
          'A space ID is required when merging changes without a persistent user.',
        ));
    try {
      await transactionForUser<void>(effectiveSpaceId, (tx) async {
        await _recorder.lockAndRefreshCurrentNodeHlc(tx);
        await _recorder.mergeChanges(mergeSet, tx);
      });
    } on OfflineSyncIntegrityViolationException catch (exception) {
      final persistedViolation = await recordOfflineSyncIntegrityViolation(
        _delegate.session,
        violation: exception.violation,
      );
      throw OfflineSyncIntegrityViolationException(persistedViolation);
    }
  }

  @override
  DatabaseAnalyzer get analyzer => _delegate.analyzer;

  @override
  DatabaseDialect get dialect => _delegate.dialect;

  @override
  DatabaseSerializationManager get serializationManager =>
      _delegate.serializationManager;

  /// Merges [where] with the CRDT visibility predicates scoped to the queried
  /// tables and the user associated with [transaction] (or the persistent user).
  ///
  /// Read filters are membership-wide. Write filters stay pinned to the acting
  /// space so mutations cannot cross space boundaries.
  Future<Expression?> _whereVisibleWithTombstone<T extends TableRow>(
    Expression? where,
    Include? include,
    Transaction? transaction, {
    required bool membershipWide,
  }) async {
    if (include == null && !_recorder.isCrdtTracked<T>()) return where;

    final spaceIds = await _spaceIdsForQueries(
      transaction,
      membershipWide: membershipWide,
    );
    return mergeWhereWithTombstone<T>(
      serializationManager,
      where,
      include,
      tableIdForName: _recorder.tableIdForName,
      spaceIds: () => spaceIds,
    );
  }

  @override
  Future<List<T>> find<T extends TableRow>({
    Expression? where,
    int? limit,
    int? offset,
    Column? orderBy,
    List<Column>? orderByList,
    bool orderDescending = false,
    Transaction? transaction,
    Include? include,
    LockMode? lockMode,
    LockBehavior? lockBehavior,
  }) async {
    await _ensureInitialized();
    final result = await _delegate.find<T>(
      where: await _whereVisibleWithTombstone<T>(
        where,
        include,
        transaction,
        membershipWide: true,
      ),
      limit: limit,
      offset: offset,
      orderBy: orderBy,
      orderByList: orderByList,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
    return _stripSpaceIdFromSpaceScopedRead(result, include, transaction);
  }

  /// CRDT tables whose writes change a visibility-filtered read without touching
  /// the queried domain table: deletes, restores and conflict projections only
  /// rewrite [CrdtDataRow] visibility, and space membership decides which spaces
  /// a read covers.
  static final List<Table> _watchVisibilityTables = [
    CrdtDataRow.t,
    OfflineSyncSpace.t,
    OfflineSyncSpaceMember.t,
  ];

  /// Emits the visible rows matching the query, then re-emits them whenever a
  /// committed write can change the result, as if [find] was re-run.
  ///
  /// Re-queries are triggered by writes to the queried table, to the tables
  /// referenced by [where], [orderBy], [orderByList] and [include], to
  /// [alsoTriggerOnTables], and to the CRDT visibility tables. The latter are
  /// required because a delete or a merged tombstone only writes CRDT metadata,
  /// never the domain row, and the visibility predicate is raw SQL that the
  /// delegate's dependency detection does not inspect.
  ///
  /// Every emission runs [find], so the tombstone and space predicates are
  /// rebuilt against the current membership instead of being frozen when the
  /// stream is created. Since every synced write touches the shared CRDT tables,
  /// a result that serializes identically to the previous emission is skipped.
  ///
  /// Only supported on SQLite. The delegate throws [UnsupportedError] otherwise.
  @override
  Stream<List<T>> watch<T extends TableRow>({
    Expression? where,
    int? limit,
    int? offset,
    Column? orderBy,
    List<Column>? orderByList,
    Include? include,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<Table>? alsoTriggerOnTables,
  }) {
    final table = serializationManager.getTableForType(T);
    if (table == null) {
      throw ArgumentError.value(T, 'T', 'is not a database table type');
    }
    final triggerTables = _watchTriggerTables(
      table,
      where: where,
      orderBy: orderBy,
      orderByList: orderByList,
      include: include,
      extraTables: [...?alsoTriggerOnTables, ..._watchVisibilityTables],
    );
    final restoreIncludeWheres = _captureIncludeWheres(include);
    String? lastEmitted;

    // The delegate only provides the commit signal; the CRDT-aware read below
    // is what rebuilds the visibility predicates on every change.
    return _delegate
        .unsafeWatch('SELECT 1', triggerOnTables: triggerTables, throttle: throttle)
        .asyncMap((_) {
          // find() ANDs the visibility predicate into IncludeList.where in place,
          // so the caller's predicates are restored before every re-run.
          for (final restore in restoreIncludeWheres) {
            restore();
          }
          return find<T>(
            where: where,
            // SQLite requires a LIMIT before an OFFSET, and -1 means no cap.
            limit: offset != null ? (limit ?? -1) : limit,
            offset: offset,
            orderBy: orderBy,
            orderByList: orderByList,
            include: include,
          );
        })
        .where((rows) {
          final encoded = SerializationManager.encode(rows);
          if (encoded == lastEmitted) return false;
          lastEmitted = encoded;
          return true;
        });
  }

  /// Raw SQL is not CRDT-filtered, same as [unsafeQuery], so this forwards to
  /// the delegate unchanged.
  @override
  Stream<DatabaseResult> unsafeWatch(
    String query, {
    QueryParameters? parameters,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<String>? triggerOnTables,
  }) {
    return _delegate.unsafeWatch(
      query,
      parameters: parameters,
      throttle: throttle,
      triggerOnTables: triggerOnTables,
    );
  }

  @override
  Future<T?> findById<T extends TableRow>(
    Object id, {
    Transaction? transaction,
    Include? include,
    LockMode? lockMode,
    LockBehavior? lockBehavior,
  }) async {
    await _ensureInitialized();
    final table = serializationManager.getTableForType(T);
    final where = table?.id.equals(id);
    final result = await _delegate.findFirstRow<T>(
      where: await _whereVisibleWithTombstone<T>(
        where,
        include,
        transaction,
        membershipWide: true,
      ),
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
    if (result == null) return null;
    return _stripSpaceIdFromSpaceScopedRead([result], include, transaction).single;
  }

  @override
  Future<T?> findFirstRow<T extends TableRow>({
    Expression? where,
    int? offset,
    Column? orderBy,
    List<Column>? orderByList,
    bool orderDescending = false,
    Transaction? transaction,
    Include? include,
    LockMode? lockMode,
    LockBehavior? lockBehavior,
  }) async {
    await _ensureInitialized();
    final result = await _delegate.findFirstRow<T>(
      where: await _whereVisibleWithTombstone<T>(
        where,
        include,
        transaction,
        membershipWide: true,
      ),
      offset: offset,
      orderBy: orderBy,
      orderByList: orderByList,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
    if (result == null) return null;
    return _stripSpaceIdFromSpaceScopedRead([result], include, transaction).single;
  }

  Future<R> _runTrackedWrite<R>(
    Transaction? transaction,
    TransactionFunction<R> action,
  ) => DatabaseUtil.runInTransactionOrSavepoint(
    _delegate,
    transaction,
    (tx) => _recorder.withCurrentNodeHlc(tx, (tx) async {
      await _recorder.lockAndRefreshCurrentNodeHlc(tx);
      return action(tx);
    }),
  );

  @override
  Future<List<T>> insert<T extends TableRow>(
    List<T> rows, {
    Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    if (rows.isEmpty) return [];
    await _ensureInitialized();
    if (!_recorder.isCrdtTracked<T>(rows.first.table)) {
      return _delegate.insert<T>(
        rows,
        transaction: transaction,
        ignoreConflicts: ignoreConflicts,
        noReturn: noReturn,
      );
    }
    return _runTrackedWrite(
      transaction,
      (tx) async {
        final prepared = _prepareRowsForInsert(rows, tx);
        final deletedRowIds = await _recorder.deletedRowIds(prepared.rows, tx);
        final rowsToInsert = [
          for (final row in prepared.rows)
            if (!deletedRowIds.contains(row.id)) row,
        ];
        final plannedInsert = await _recorder.planLocalInserts(rowsToInsert, tx);

        // Tracked rows can only skip RETURNING when the prepared rows are
        // exactly what gets inserted: every id is caller-provided and a
        // conflict throws instead of silently dropping rows.
        final skipReturn =
            noReturn && !ignoreConflicts && !rows.any((row) => row.id == null);

        final result = plannedInsert.rows.isEmpty
            ? <T>[]
            : await insertWithExplicitNulls<T>(
                _delegate,
                plannedInsert.rows,
                explicitNulls: {
                  for (final row in plannedInsert.rows)
                    if ({
                          for (final column in row.table.crdtSyncableColumns)
                            if (column.hasDefault &&
                                row.id != null &&
                                plannedInsert.attempts.containsKey((
                                  row.table.tableName,
                                  row.id as UuidValue,
                                  column.columnName,
                                )) &&
                                (row.toJsonForDatabase() as Map)[column.columnName] ==
                                    null)
                              column.columnName,
                        }
                        case final columns when columns.isNotEmpty)
                      row.id as UuidValue: columns,
                },
                transaction: tx,
                ignoreConflicts: ignoreConflicts,
                noReturn: skipReturn,
              );

        final insertedRows = skipReturn ? plannedInsert.rows : result;
        await _recorder.afterInsert<T>(
          insertedRows,
          tx,
          attempts: plannedInsert.attempts,
        );

        final reinsertedRows = await _reinsertTombstonedRows(
          prepared.rows,
          insertedRows,
          tx,
          deletedRowIds: deletedRowIds,
        );
        if (noReturn) return <T>[];

        final affectedRows = _orderAffectedRows(
          prepared.rows,
          insertedRows,
          reinsertedRows,
        );
        _stripStampedRows(affectedRows, prepared);
        return affectedRows;
      },
    );
  }

  @override
  Future<T> insertRow<T extends TableRow>(
    T row, {
    Transaction? transaction,
  }) async {
    return (await insert<T>([row], transaction: transaction)).single;
  }

  @override
  Future<List<T>> upsert<T extends TableRow>(
    List<T> rows, {
    required List<Column> conflictColumns,
    List<Column>? updateColumns,
    Expression? updateWhere,
    Transaction? transaction,
    bool noReturn = false,
  }) async {
    if (rows.isEmpty) return [];
    await _ensureInitialized();
    if (!_recorder.isCrdtTracked<T>(rows.first.table)) {
      return _delegate.upsert<T>(
        rows,
        conflictColumns: conflictColumns,
        updateColumns: updateColumns,
        updateWhere: updateWhere,
        transaction: transaction,
        noReturn: noReturn,
      );
    }
    return _runTrackedWrite(
      transaction,
      (tx) async {
        final prepared = _prepareRowsForInsert(rows, tx);
        final values = _recorder.withForeignKeyInsertDefaults(prepared.rows);
        final projection = await _recorder.prepareLocalUpsert(
          values,
          conflictColumns,
          updateColumns,
          tx,
        );

        // CRDT metadata needs the affected rows even when the public call uses
        // noReturn, because inserted rows may have database-generated ids.
        final result = await _delegate.upsert<T>(
          values,
          conflictColumns: conflictColumns,
          updateColumns: updateColumns,
          updateWhere: await _whereVisibleWithTombstone<T>(
            updateWhere,
            null,
            tx,
            membershipWide: false,
          ),
          transaction: tx,
        );

        final reinsertedRows = await _reinsertTombstonedRows(
          prepared.rows,
          result,
          tx,
        );

        final insertedRows = await _rowsWithoutCrdtMetadata(result, tx);
        await _recorder.afterInsert(insertedRows, tx);

        final insertedRowIds = {
          for (final row in insertedRows)
            if (row.id is UuidValue) row.id as UuidValue,
        };
        final updatedRows = [
          for (final row in result)
            if (row.id is! UuidValue || !insertedRowIds.contains(row.id)) row,
        ];
        await _recorder.afterUpdate(
          updatedRows,
          updateColumns,
          tx,
          projectionUnchanged: projection.projectionUnchanged,
          domainBeforeUpsert: projection.domain,
          upsertRows: updateColumns == null && projection.domain.isNotEmpty
              ? prepared.rows
              : const [],
        );
        if (noReturn) return <T>[];
        _stripStampedRows(result, prepared);
        for (final row in reinsertedRows) {
          final rowId = row.id;
          if (rowId == null || !prepared.explicitRowIds.contains(rowId)) {
            _stripSpaceId(row);
          }
        }
        return [...result, ...reinsertedRows];
      },
    );
  }

  /// Reinserts upserted rows whose conflict target is a tombstoned row.
  ///
  /// The visibility filter merged into `updateWhere` keeps the delegate upsert
  /// from updating hidden rows, so they come back missing from [result]. From
  /// the caller's perspective a deleted row does not exist, so the upsert must
  /// behave as an insert: the domain row is overwritten with the incoming
  /// values — ignoring `updateColumns` and `updateWhere` — and the tombstone
  /// is lifted, mirroring the [insertRow] reinsert path.
  Future<List<T>> _reinsertTombstonedRows<T extends TableRow>(
    List<T> preparedRows,
    List<T> result,
    Transaction transaction, {
    Set<UuidValue>? deletedRowIds,
  }) async {
    final returnedIds = <Object>{
      for (final row in result)
        if (row.id != null) row.id as Object,
    };

    final missingRows = [
      for (final row in preparedRows)
        if (row.id case final rowId? when !returnedIds.contains(rowId)) row,
    ];
    deletedRowIds ??= await _recorder.deletedRowIds(missingRows, transaction);
    final rowsToReinsert = [
      for (final row in missingRows)
        if (deletedRowIds.contains(row.id)) row,
    ];
    if (rowsToReinsert.isEmpty) return [];
    // Hidden targets were filtered out of the delegate's upsert results, so
    // its duplicate-target check cannot see these restorations. Check the
    // submitted identities before turning them into ordinary updates.
    if (rowsToReinsert.map((row) => row.id).toSet().length != rowsToReinsert.length) {
      throw DatabaseQueryException(
        'ON CONFLICT DO UPDATE command cannot affect row a second time',
        code: switch (dialect) {
          DatabaseDialect.postgres => PgErrorCode.cardinalityViolation,
          DatabaseDialect.sqlite => SqliteErrorCode.integrityConstraintViolation,
        },
      );
    }

    final plannedReinserts = await _recorder.planLocalUpdates(
      rowsToReinsert,
      null,
      transaction,
      restoring: true,
    );
    final reinsertedRows = await _delegate.update<T>(
      plannedReinserts.rows,
      transaction: transaction,
    );
    await _recorder.afterReinsert(reinsertedRows, transaction);
    return reinsertedRows;
  }

  List<T> _orderAffectedRows<T extends TableRow>(
    List<T> preparedRows,
    List<T> insertedRows,
    List<T> reinsertedRows,
  ) {
    if (insertedRows.length + reinsertedRows.length != preparedRows.length) {
      return [...insertedRows, ...reinsertedRows];
    }

    final reinsertedIds = {for (final row in reinsertedRows) row.id};
    final inserted = insertedRows.iterator;
    final reinserted = reinsertedRows.iterator;
    return [
      for (final row in preparedRows)
        reinsertedIds.contains(row.id)
            ? (reinserted..moveNext()).current
            : (inserted..moveNext()).current,
    ];
  }

  Future<List<T>> _rowsWithoutCrdtMetadata<T extends TableRow>(
    List<T> rows,
    Transaction transaction,
  ) async {
    if (rows.isEmpty) return [];

    final rowIds = {
      for (final row in rows)
        if (row.id is UuidValue) row.id as UuidValue,
    };
    if (rowIds.isEmpty) return [];

    final tableId = _recorder.tableIdForName(rows.first.table.tableName)!;
    final spaceId = _requireEffectiveSpace(transaction).id!;
    final crdtRows = await CrdtDataRow.db.find(
      _delegate.session,
      where: (t) =>
          t.spaceId.equals(spaceId) &
          t.tblId.equals(tableId) &
          t.uuidRowId.inSet(rowIds),
      transaction: transaction,
    );
    final existingRowIds = crdtRows.map((row) => row.uuidRowId).toSet();

    return [
      for (final row in rows)
        if (row.id is UuidValue && !existingRowIds.contains(row.id)) row,
    ];
  }

  @override
  Future<T?> upsertRow<T extends TableRow>(
    T row, {
    required List<Column> conflictColumns,
    List<Column>? updateColumns,
    Expression? updateWhere,
    Transaction? transaction,
  }) async {
    await _ensureInitialized();
    final result = await upsert<T>(
      [row],
      conflictColumns: conflictColumns,
      updateColumns: updateColumns,
      updateWhere: updateWhere,
      transaction: transaction,
    );
    if (result.length > 1) {
      throw DatabaseUnexpectedResultException(
        'Failed to upsert row, affected number of rows is ${result.length} != 1',
      );
    }
    return result.firstOrNull;
  }

  @override
  Future<List<T>> update<T extends TableRow>(
    List<T> rows, {
    List<Column>? columns,
    Transaction? transaction,
    bool noReturn = false,
  }) async {
    if (rows.isEmpty) return [];
    await _ensureInitialized();
    if (!_recorder.isCrdtTracked<T>(rows.first.table)) {
      return _delegate.update<T>(
        rows,
        columns: columns,
        transaction: transaction,
        noReturn: noReturn,
      );
    }
    return _runTrackedWrite(
      transaction,
      (tx) async {
        final plannedUpdates = await _recorder.planLocalUpdates(rows, columns, tx);
        final updatedRows = [
          for (final row in plannedUpdates.rows)
            await _updateRowWithoutRecording(
              row,
              stripSpaceId: _shouldStripReturnedSpaceId(row, tx),
              transaction: tx,
              columns: columns,
            ),
        ];

        await _recorder.afterUpdate(
          updatedRows,
          columns,
          tx,
          projectionUnchanged: plannedUpdates.projectionUnchanged,
        );
        return noReturn ? <T>[] : updatedRows;
      },
    );
  }

  @override
  Future<T> updateRow<T extends TableRow>(
    T row, {
    List<Column>? columns,
    Transaction? transaction,
  }) async {
    await _ensureInitialized();
    if (!_recorder.isCrdtTracked<T>(row.table)) {
      return _delegate.updateRow<T>(
        row,
        columns: columns,
        transaction: transaction,
      );
    }
    return _runTrackedWrite(
      transaction,
      (tx) async {
        final plannedUpdates = await _recorder.planLocalUpdates([row], columns, tx);
        final stripSpaceId = _shouldStripReturnedSpaceId(row, tx);
        final updatedRow = await _updateRowWithoutRecording(
          plannedUpdates.rows.single,
          stripSpaceId: stripSpaceId,
          transaction: tx,
          columns: columns,
        );

        await _recorder.afterUpdate(
          [updatedRow],
          columns,
          tx,
          projectionUnchanged: plannedUpdates.projectionUnchanged,
        );
        return updatedRow;
      },
    );
  }

  Future<T> _updateRowWithoutRecording<T extends TableRow>(
    T row, {
    required Transaction transaction,
    required bool stripSpaceId,
    List<Column>? columns,
  }) async {
    final values = row.toJsonForDatabase() as Map<String, dynamic>;
    final columnValues = (columns ?? row.table.managedColumns).crdtSyncableColumns
        .map((c) => ColumnValue(c, values[c.columnName]))
        .toList();

    final where = row.table.id.equals(row.id);
    final updatedRows = await _delegate.updateWhere<T>(
      columnValues: columnValues,
      where: (await _whereVisibleWithTombstone<T>(
        where,
        null,
        transaction,
        membershipWide: false,
      ))!,
      transaction: transaction,
    );

    if (updatedRows.isEmpty) {
      throw DatabaseUnexpectedResultException(
        'Failed to update row, no rows updated',
      );
    }

    final updatedRow = updatedRows.single;
    if (stripSpaceId) _stripSpaceId(updatedRow);
    return updatedRow;
  }

  @override
  Future<T?> updateById<T extends TableRow>(
    Object id, {
    required List<ColumnValue> columnValues,
    Transaction? transaction,
  }) async {
    await _ensureInitialized();
    final table = serializationManager.getTableForType(T);
    if (table == null) return null;

    final updatedRows = await updateWhere<T>(
      columnValues: columnValues,
      where: table.id.equals(id),
      transaction: transaction,
    );

    if (updatedRows.isEmpty) return null;
    return updatedRows.single;
  }

  @override
  Future<List<T>> updateWhere<T extends TableRow>({
    required List<ColumnValue> columnValues,
    required Expression where,
    int? limit,
    int? offset,
    Column? orderBy,
    List<Column>? orderByList,
    bool orderDescending = false,
    Transaction? transaction,
    bool noReturn = false,
  }) async {
    await _ensureInitialized();
    if (!_recorder.isCrdtTracked<T>()) {
      return _delegate.updateWhere<T>(
        columnValues: columnValues,
        where: where,
        limit: limit,
        offset: offset,
        orderBy: orderBy,
        orderByList: orderByList,
        transaction: transaction,
        noReturn: noReturn,
      );
    }

    _assertNoSpaceIdColumnValues<T>(columnValues);
    return _runTrackedWrite(
      transaction,
      (tx) async {
        final result = await _delegate.updateWhere<T>(
          columnValues: columnValues,
          where: (await _whereVisibleWithTombstone<T>(
            where,
            null,
            tx,
            membershipWide: false,
          ))!,
          limit: limit,
          offset: offset,
          orderBy: orderBy,
          orderByList: orderByList,
          transaction: tx,
        );

        final columns = columnValues.map((e) => e.column).toList();
        _recorder.validateAuthoredRows(result, columns);
        await _recorder.afterUpdate(
          result,
          columns,
          tx,
          authoredColumnValues: true,
        );
        if (noReturn) return <T>[];
        result.forEach(_stripSpaceId);
        return result;
      },
    );
  }

  @override
  Future<List<T>> delete<T extends TableRow>(
    List<T> rows, {
    Column? orderBy,
    List<Column>? orderByList,
    bool orderDescending = false,
    Transaction? transaction,
    bool noReturn = false,
  }) async {
    if (rows.isEmpty) return [];
    await _ensureInitialized();
    return deleteWhere<T>(
      where: rows.first.table.id.inSet(
        rows.map((row) => row.id).castToIdType().toSet(),
      ),
      orderBy: orderBy,
      orderByList: orderByList,
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  @override
  Future<T> deleteRow<T extends TableRow>(
    T row, {
    Transaction? transaction,
  }) async {
    await _ensureInitialized();
    final deletedRows = await deleteWhere<T>(
      where: row.table.id.equals(row.id),
      transaction: transaction,
    );

    if (deletedRows.isEmpty) {
      throw DatabaseUnexpectedResultException(
        'Failed to delete row, no rows deleted.',
      );
    }

    return deletedRows.single;
  }

  @override
  Future<List<T>> deleteWhere<T extends TableRow>({
    required Expression where,
    Column? orderBy,
    List<Column>? orderByList,
    bool orderDescending = false,
    Transaction? transaction,
    bool noReturn = false,
  }) async {
    await _ensureInitialized();
    if (!_recorder.isCrdtTracked<T>()) {
      return _delegate.deleteWhere<T>(
        where: where,
        orderBy: orderBy,
        orderByList: orderByList,
        transaction: transaction,
        noReturn: noReturn,
      );
    }

    return _runTrackedWrite(
      transaction,
      (tx) async {
        final rows = await _delegate.find<T>(
          where: await _whereVisibleWithTombstone<T>(
            where,
            null,
            tx,
            membershipWide: false,
          ),
          orderBy: orderBy,
          orderByList: orderByList,
          transaction: tx,
        );

        await _recorder.insteadOfDelete<T>(rows, tx);
        if (noReturn) return <T>[];
        return _stripSpaceIdFromSpaceScopedRead(rows, null, tx);
      },
    );
  }

  @override
  Future<int> count<T extends TableRow>({
    Expression? where,
    int? limit,
    bool useCache = true,
    Transaction? transaction,
  }) async {
    await _ensureInitialized();
    return _delegate.count<T>(
      where: await _whereVisibleWithTombstone<T>(
        where,
        null,
        transaction,
        membershipWide: true,
      ),
      limit: limit,
      useCache: useCache,
      transaction: transaction,
    );
  }

  @override
  Future<void> lockRows<T extends TableRow>({
    required Expression where,
    required LockMode lockMode,
    required Transaction transaction,
    LockBehavior lockBehavior = LockBehavior.wait,
  }) async {
    await _ensureInitialized();
    return _delegate.lockRows<T>(
      where: (await _whereVisibleWithTombstone<T>(
        where,
        null,
        transaction,
        membershipWide: false,
      ))!,
      lockMode: lockMode,
      transaction: transaction,
      lockBehavior: lockBehavior,
    );
  }

  @override
  Future<R> transaction<R>(
    TransactionFunction<R> transactionFunction, {
    TransactionSettings? settings,
  }) async {
    // Do not initialize CRDT here. Serverpod runs database migrations inside
    // [transaction] before CRDT tables exist. Callers that need CRDT state
    // ([transactionForUser], mutating ORM methods) initialize explicitly.
    return _delegate.transaction(
      _recorder.hasPersistentSpace
          ? (tx) => _recorder.withCurrentNodeHlc(tx, transactionFunction)
          : transactionFunction,
      settings: settings,
    );
  }

  /// Executes the [transactionFunction] in a transaction with the provided [userId].
  ///
  /// Without [spaceId], writes act in the user's personal space. With [spaceId],
  /// [userId] stays the authenticated identity and [spaceId] is the space being
  /// acted in; the pair is checked before the transaction starts.
  Future<R> transactionForUser<R>(
    UuidValue userId,
    TransactionFunction<R> transactionFunction, {
    UuidValue? spaceId,
    TransactionSettings? settings,
  }) async {
    await _ensureInitialized();
    final effectiveSpaceId = spaceId ?? userId;
    await _assertCanActInSpace(userId, effectiveSpaceId);

    // Ensure that the space exists with a node before starting the transaction.
    final space = await _recorder.getOrCreateSpace(effectiveSpaceId);

    return transaction<R>(
      (tx) async {
        try {
          spaceForTransaction[tx] = space;
          userForTransaction[tx] = userId;
          return await _recorder.withCurrentNodeHlc(tx, transactionFunction);
        } finally {
          spaceForTransaction.remove(tx);
          userForTransaction.remove(tx);
        }
      },
      settings: settings,
    );
  }

  Future<void> _assertCanActInSpace(UuidValue userId, UuidValue spaceId) async {
    if (userId == spaceId) return;

    // Authoritative membership: the source of truth on the server, the
    // read-only cache on a follower (empty until populated). A null role means
    // no membership row at all; a non-writable role means membership without
    // write access.
    final role = await OfflineSyncSpaceMembership.roleOf(
      _delegate.session,
      userUuid: userId,
      spaceUuid: spaceId,
    );
    if (role == null) {
      throw OfflineSyncSpaceMembershipException(userId: userId, spaceId: spaceId);
    }
    if (!role.canWrite) {
      throw OfflineSyncSpaceRoleException(userId: userId, spaceId: spaceId, role: role);
    }
  }

  Future<List<int>?> _spaceIdsForQueries(
    Transaction? transaction, {
    required bool membershipWide,
  }) async {
    if (!membershipWide) {
      return _actingSpaceIdsForQueries(transaction);
    }

    final userId = _userIdForQueries(transaction);
    if (userId == null) return null;

    // On the server this is authoritative membership; on a persistent client it
    // is the server-projected membership cache.
    final spaceGroups = await Future.wait<List<OfflineSyncSpace>>([
      OfflineSyncSpace.db.find(
        _delegate.session,
        where: (t) => t.uuidSpaceId.equals(userId),
      ),
      OfflineSyncSpaceMember.db
          .find(
            _delegate.session,
            where: (t) => t.userUuid.equals(userId),
            include: OfflineSyncSpaceMember.include(space: OfflineSyncSpace.include()),
          )
          .then((memberships) => [for (final member in memberships) member.space!]),
    ]);
    return {
      for (final spaces in spaceGroups)
        for (final space in spaces) space.id!,
    }.toList();
  }

  List<int>? _actingSpaceIdsForQueries(Transaction? transaction) {
    final spaceId = _recorder.spaceForQueries(transaction)?.id;
    return spaceId == null ? null : [spaceId];
  }

  UuidValue? _userIdForQueries(Transaction? transaction) {
    if (transaction != null) {
      final userId = userForTransaction[transaction];
      if (userId != null) return userId;
    }
    return _recorder.persistentUserId;
  }

  Future<UuidValue> _requireUserId(UuidValue? userId) async {
    return userId ??
        _recorder.persistentUserId ??
        (throw StateError(
          'A user ID is required when syncing without a persistent user.',
        ));
  }

  @override
  Future<int> unsafeExecute(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
    QueryParameters? parameters,
  }) async {
    return _delegate.unsafeExecute(
      query,
      timeoutInSeconds: timeoutInSeconds,
      transaction: transaction,
      parameters: parameters,
    );
  }

  @override
  Future<DatabaseResult> unsafeQuery(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
    QueryParameters? parameters,
  }) async {
    return _delegate.unsafeQuery(
      query,
      timeoutInSeconds: timeoutInSeconds,
      transaction: transaction,
      parameters: parameters,
    );
  }

  @override
  Future<int> unsafeSimpleExecute(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
  }) async {
    return _delegate.unsafeSimpleExecute(
      query,
      timeoutInSeconds: timeoutInSeconds,
      transaction: transaction,
    );
  }

  @override
  Future<DatabaseResult> unsafeSimpleQuery(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
  }) async {
    return _delegate.unsafeSimpleQuery(
      query,
      timeoutInSeconds: timeoutInSeconds,
      transaction: transaction,
    );
  }

  @override
  Future<bool> testConnection() => _delegate.testConnection();
}

/// Collects the tables a typed watch reads: the queried [table], every table
/// referenced by [where], [orderBy], [orderByList] and the [include] graph
/// (relation hops included), plus [extraTables].
///
/// Mirrors the collection Serverpod runs for its own watches, which it does not
/// export.
Set<String> _watchTriggerTables(
  Table table, {
  Expression? where,
  Column? orderBy,
  List<Column>? orderByList,
  Include? include,
  Iterable<Table> extraTables = const [],
}) {
  final tables = <String>{};

  void addTable(Table table) {
    tables.add(table.unqualifiedTableName);
    final hops = table.tableRelation?.getRelations;
    if (hops == null) return;
    for (final hop in hops) {
      tables
        ..add(hop.fieldTable.unqualifiedTableName)
        ..add(hop.foreignTable.unqualifiedTableName);
    }
  }

  void addColumn(Column? column) {
    if (column == null) return;
    if (column is Order) {
      addColumn(column.column);
      return;
    }
    addTable(column.table);
    if (column is ColumnCount) column.innerWhere?.columns.forEach(addColumn);
  }

  void addInclude(Include? include) {
    if (include == null) return;
    addTable(include.table);
    if (include is IncludeList) {
      include.where?.columns.forEach(addColumn);
      addColumn(include.orderBy);
      include.orderByList?.forEach(addColumn);
      addInclude(include.include);
    }
    include.includes.values.forEach(addInclude);
  }

  addTable(table);
  where?.columns.forEach(addColumn);
  addColumn(orderBy);
  orderByList?.forEach(addColumn);
  addInclude(include);
  extraTables.forEach(addTable);
  return tables;
}

/// Snapshots every [IncludeList.where] in [include] and returns callbacks that
/// restore them.
List<void Function()> _captureIncludeWheres(Include? include) {
  final restorers = <void Function()>[];

  void capture(Include? include) {
    if (include == null) return;
    if (include is IncludeList) {
      final original = include.where;
      restorers.add(() => include.where = original);
      capture(include.include);
    }
    include.includes.values.forEach(capture);
  }

  capture(include);
  return restorers;
}
