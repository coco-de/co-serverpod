import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:serverpod_database/serverpod_database.dart';
import 'package:uuid/uuid.dart';

import '../crdt/extensions.dart';
import '../crdt/merge.dart';
import '../database/database.dart';
import '../database/merge_utils/database_helpers.dart';
import '../database/recorder.dart';
import '../database/unique_index_utils.dart';
import '../generated/protocol.dart';
import '../hlc/hlc.dart';
import '../managers/space.dart';
import '../spaces/membership.dart';
import '../utils/case_when.dart' show Case;
import 'exceptions.dart';
import 'integrity_violation.dart';
import 'outbound_batch.dart';
import 'space_state.dart';

export 'space_state.dart' show OfflineSyncPeerMode;

/// Callback function for when a merge is successful.
typedef OfflineSyncOnMergeSuccess =
    FutureOr<void> Function(UuidValue spaceUuid, Hlc syncedHlc);

/// A tuple representing the ownership of a domain row.
typedef DomainRowOwner = ({bool exists, int? spaceId});

/// A cache of domain row owners by table name and row id.
typedef DomainRowOwnerCache = Map<(String, UuidValue), DomainRowOwner>;

/// The shared CRDT synchronization logic used by both client and server nodes.
class OfflineSyncEngine {
  /// Creates a new [OfflineSyncEngine] instance.
  OfflineSyncEngine({
    /// The list of tables to sync with CRDT.
    required List<Table> syncTables,

    /// The serialization manager to use for deserializing merge changes.
    required DatabaseSerializationManager serializationManager,

    /// Shared CRDT database metadata.
    OfflineSyncDatabaseContext? databaseContext,

    /// Maximum number of merge changes sent in one sync stream message.
    int syncBatchSize = defaultSyncBatchSize,

    /// Delay between continuous sync rounds. It is also the shortest delay a
    /// session can ask for, see [resolveContinuousSyncInterval].
    this._continuousSyncInterval = defaultContinuousSyncInterval,

    /// The longest delay between continuous sync rounds a session can ask
    /// for, see [resolveContinuousSyncInterval] (fork, unibook#14207).
    /// Defaults to [defaultMaxContinuousSyncInterval], or to
    /// `continuousSyncInterval` when that is longer. A value below
    /// `continuousSyncInterval` throws [ArgumentError].
    Duration? maxContinuousSyncInterval,

    /// The maximum clock drift, see [OfflineSyncDatabaseContext.maxClockDrift].
    /// Configures the new context when `databaseContext` is null. When
    /// `databaseContext` is given, a different value throws [ArgumentError].
    Duration? maxClockDrift,

    /// How much one outbound batch may carry (fork, unibook#14251), see
    /// [OfflineSyncBatchBudget]. Unlimited by default: every pending change in
    /// one batch, as upstream.
    this._batchBudget = OfflineSyncBatchBudget.unlimited,

    /// Rows this peer does not send, and rows it sends again in full (fork,
    /// unibook#14251), see [OfflineSyncRowIsolation]. None by default.
    this._rowIsolation,
  }) : _syncTables = syncTables,
       _serializationManager = serializationManager,
       _databaseContext = OfflineSyncDatabaseContext.resolve(
         databaseContext,
         syncTables: syncTables,
         serializationManager: serializationManager,
         maxClockDrift: maxClockDrift,
       ),
       _syncBatchSize = syncBatchSize,
       _maxContinuousSyncInterval = resolveMaxContinuousSyncInterval(
         _continuousSyncInterval,
         maxContinuousSyncInterval,
       ) {
    if (syncBatchSize < 1) {
      throw ArgumentError.value(syncBatchSize, 'syncBatchSize', 'Must be >= 1');
    }
  }

  /// Default maximum number of merge changes sent in one stream message.
  static const defaultSyncBatchSize = 100;

  /// Default delay between continuous sync rounds.
  static const defaultContinuousSyncInterval = Duration(milliseconds: 200);

  /// Default longest delay between continuous sync rounds a session can ask
  /// for (fork, unibook#14207).
  ///
  /// While it waits, a peer does not read the other side, so a session whose
  /// device left ends only after up to this long. A session that needs updates
  /// less often than this should not run continuously.
  static const defaultMaxContinuousSyncInterval = Duration(seconds: 30);

  /// The longest delay between continuous sync rounds a session can ask for,
  /// given [continuousSyncInterval] and the configured maximum (fork,
  /// unibook#14207).
  ///
  /// Without [maxContinuousSyncInterval] it is
  /// [defaultMaxContinuousSyncInterval], or [continuousSyncInterval] when that
  /// is longer, so an interval configured before the maximum existed keeps
  /// working. A [maxContinuousSyncInterval] below [continuousSyncInterval]
  /// throws [ArgumentError] rather than being raised silently.
  static Duration resolveMaxContinuousSyncInterval(
    Duration continuousSyncInterval,
    Duration? maxContinuousSyncInterval,
  ) {
    if (maxContinuousSyncInterval == null) {
      return continuousSyncInterval > defaultMaxContinuousSyncInterval
          ? continuousSyncInterval
          : defaultMaxContinuousSyncInterval;
    }
    if (maxContinuousSyncInterval < continuousSyncInterval) {
      throw ArgumentError.value(
        maxContinuousSyncInterval,
        'maxContinuousSyncInterval',
        'Must be >= continuousSyncInterval ($continuousSyncInterval)',
      );
    }
    return maxContinuousSyncInterval;
  }

  final List<Table> _syncTables;
  final DatabaseSerializationManager _serializationManager;
  final OfflineSyncDatabaseContext _databaseContext;

  /// The maximum clock drift of every database this engine wraps, see
  /// [OfflineSyncDatabaseContext.maxClockDrift].
  Duration get maxClockDrift => _databaseContext.maxClockDrift;
  final int _syncBatchSize;
  final Duration _continuousSyncInterval;
  final Duration _maxContinuousSyncInterval;

  /// The configured delay between continuous sync rounds, the shortest a
  /// session can ask for.
  Duration get continuousSyncInterval => _continuousSyncInterval;

  /// The longest delay between continuous sync rounds a session can ask for.
  Duration get maxContinuousSyncInterval => _maxContinuousSyncInterval;

  final OfflineSyncBatchBudget _batchBudget;
  final OfflineSyncRowIsolation? _rowIsolation;

  /// How much one outbound batch may carry (fork, unibook#14251).
  OfflineSyncBatchBudget get batchBudget => _batchBudget;

  /// The rows this peer holds back or sends again in full (fork,
  /// unibook#14251), or null.
  OfflineSyncRowIsolation? get rowIsolation => _rowIsolation;

  /// The delay between this session's continuous rounds (fork,
  /// unibook#14207).
  ///
  /// [local] is what this peer asks for, [peer] what the other peer asked for
  /// in its [OfflineSyncConnect.continuousSyncInterval]. The slower request
  /// wins, so neither peer can make the other one faster. It is then bounded
  /// by this engine's settings: never below [continuousSyncInterval], so a
  /// request cannot make this peer run more often than configured, and never
  /// above [maxContinuousSyncInterval]. Without either request it is
  /// [continuousSyncInterval], as before sessions could ask.
  @visibleForTesting
  Duration resolveContinuousSyncInterval({Duration? local, Duration? peer}) {
    final floor = _continuousSyncInterval;
    final requested = local ?? floor;
    final peerRequested = peer ?? floor;
    final wanted = requested > peerRequested ? requested : peerRequested;
    if (wanted < floor) return floor;
    if (wanted > _maxContinuousSyncInterval) return _maxContinuousSyncInterval;
    return wanted;
  }

  /// Wraps [database] in a CRDT-aware database using this sync context.
  OfflineSyncDatabase wrapDatabase(Database database, {UuidValue? persistentUserId}) {
    if (database is OfflineSyncDatabase) return database;
    return OfflineSyncDatabase(
      database,
      syncTables: _syncTables,
      syncBatchSize: _syncBatchSize,
      continuousSyncInterval: _continuousSyncInterval,
      maxContinuousSyncInterval: _maxContinuousSyncInterval,
      persistentUserId: persistentUserId,
      context: _databaseContext,
      batchBudget: _batchBudget,
      rowIsolation: _rowIsolation,
    );
  }

  late final Map<String, Table> _syncTablesByName = {
    for (final table in _syncTables) table.tableName: table,
  };

  late final Map<String, String> _classNamesByTableName = {
    for (final definition in _serializationManager.getTargetTableDefinitions())
      if (definition.dartName != null) definition.name: definition.dartName!,
  };

  /// The deterministic hash representing the current synchronized schema.
  late final String currentSyncTablesHash = computeSyncTablesHash(
    _syncTables,
    tableDefinitions: _serializationManager.getTargetTableDefinitions(),
  );

  /// Computes a deterministic fixed-size hash of the synchronized schema.
  ///
  /// The [tableDefinitions] is the list of all table definitions in the
  /// database, which must include the definitions for all [syncTables].
  static String computeSyncTablesHash(
    List<Table> syncTables, {
    required List<TableDefinition> tableDefinitions,
  }) {
    final canonicalSignature = _computeCanonicalSyncTablesSignature(
      syncTables,
      tableDefinitions: tableDefinitions,
    );
    // Use two deterministic namespace-based UUIDv5 hashes to keep the payload
    // fixed-size while substantially reducing the practical collision risk.
    const uuid = Uuid();
    return '${uuid.v5(Namespace.url.value, canonicalSignature)}:'
        '${uuid.v5(Namespace.oid.value, canonicalSignature)}';
  }

  /// Streams pending changes for every space in [checkpointsBySpaceUuid].
  ///
  /// Changes are emitted in insert, update, then delete order. Domain row and
  /// column payloads are resolved incrementally as each change is yielded.
  ///
  /// Foreign-key columns with an active projection override are sent with their
  /// durable [CrdtDataAttemptedValue.value], not the visible value stored
  /// in the domain table. Peers need the attempted fact to converge; local FK
  /// projection materializes only the safe visible value into domain tables.
  ///
  /// Resolves the spaces' internal ids once and keeps their checkpoint vectors
  /// scoped by those internal ids. Node ids are stable per replica and may
  /// appear in multiple spaces, so checkpoint filtering must compare both
  /// `spaceId` and `uuidNodeId`. This still runs one query per change kind for
  /// the whole pass, all three from one snapshot before the first change is
  /// yielded (fork, unibook#14183: see [_readPendingChanges]). Per-row
  /// ownership and integrity checks resolve against each row's own space.
  ///
  /// All changes for nodes that are not present in a space's checkpoint list
  /// are collected and emitted. Passing an empty list for a space will collect
  /// all of its changes. Each change carries its [CrdtMergeChange.uuidSpaceId].
  Stream<CrdtMergeChange> collectPendingChanges(
    DatabaseSession session, {
    required Map<UuidValue, List<Hlc>> checkpointsBySpaceUuid,
  }) async* {
    if (checkpointsBySpaceUuid.isEmpty) return;

    final spaces = await OfflineSyncSpace.db.find(
      session,
      where: (t) => t.uuidSpaceId.inSet(checkpointsBySpaceUuid.keys.toSet()),
    );
    final spaceUuidById = {
      for (final space in spaces) space.id!: space.uuidSpaceId,
    };
    final checkpointsBySpaceId = {
      for (final space in spaces)
        space.id!: checkpointsBySpaceUuid[space.uuidSpaceId] ?? const <Hlc>[],
    };

    try {
      await for (final change in _streamPendingChanges(
        session,
        spaceUuidById,
        checkpointsBySpaceId,
      )) {
        yield change;
      }
    } on PendingOutboundIntegrityViolation catch (violation) {
      await _recordAndThrowIntegrityViolation(session, violation);
    }
  }

  /// Streams one outbound batch of the pending changes for every space in
  /// [checkpointsBySpaceUuid], under [batchBudget] and [rowIsolation] (fork,
  /// unibook#14251).
  ///
  /// Reads the same snapshot as [collectPendingChanges], leaves out the
  /// isolated rows, adds every change of the released rows this session has
  /// not sent yet, and plans the batch with [planOutboundUnits]: HLC order,
  /// cut where resuming from the advanced checkpoints skips nothing. It streams
  /// whole units while they fit and stops before the first that does not,
  /// setting [_OutboundBatch.hasMore]. A unit that does not fit an empty batch
  /// is sent group by group while they fit, and a group that does not fit an
  /// empty batch part by part while they fit; that first part is sent even
  /// when it alone exceeds the budget, so every batch makes progress.
  ///
  /// Changes are resolved (their domain values read) one unit at a time, so a
  /// unit that ends up not fitting was read for nothing; the next round reads
  /// it again.
  Stream<CrdtMergeChange> _collectPlannedBatch(
    DatabaseSession session, {
    required Map<UuidValue, List<Hlc>> checkpointsBySpaceUuid,
    required _OutboundBatch outbound,
    required _ReleasedRowsSent released,
  }) async* {
    if (checkpointsBySpaceUuid.isEmpty) return;

    // Read once: the implementation may change the sets while this runs.
    final isolatedRows = {...?_rowIsolation?.isolatedRows};
    final releasedRows = {...?_rowIsolation?.releasedRows}..removeAll(isolatedRows);

    final spaces = await OfflineSyncSpace.db.find(
      session,
      where: (t) => t.uuidSpaceId.inSet(checkpointsBySpaceUuid.keys.toSet()),
    );
    final spaceUuidById = {
      for (final space in spaces) space.id!: space.uuidSpaceId,
    };
    final checkpointsBySpaceId = {
      for (final space in spaces)
        space.id!: checkpointsBySpaceUuid[space.uuidSpaceId] ?? const <Hlc>[],
    };

    try {
      final pending = await _readPendingChanges(
        session,
        checkpointsBySpaceId,
        releasedRows: releasedRows,
      );

      final planned = <_PlannedChange>[];
      final seen = <(OutboundChangeKind, int)>{};
      void plan(_PlannedChange change) {
        // A change read both as pending and as released is pending.
        if (!seen.add((change.ref.kind, change.sourceId))) return;
        if (isolatedRows.contains(change.rowKey)) return;
        // A released row's change goes once per session.
        if (change.forced && released.entries.contains(change.sentKey)) return;
        planned.add(change);
      }

      for (final (rows, forced) in [
        (pending.rows, false),
        (pending.releasedRows, true),
      ]) {
        for (final row in rows) {
          if (_sendsInsert(row)) plan(_PlannedChange.insert(row, forced: forced));
        }
      }
      for (final (fields, forced) in [
        (pending.fields, false),
        (pending.releasedFields, true),
      ]) {
        for (final field in fields) {
          if (_sendsUpdate(field)) plan(_PlannedChange.update(field, forced: forced));
        }
      }
      for (final (tombstones, forced) in [
        (pending.tombstones, false),
        (pending.releasedTombstones, true),
      ]) {
        for (final tombstone in tombstones) {
          if (_sendsDelete(tombstone)) {
            plan(_PlannedChange.delete(tombstone, forced: forced));
          }
        }
      }
      if (planned.isEmpty) return;

      final attemptedValueFieldsByRowId = await _loadAttemptedValueFields(session, [
        for (final change in planned) ?change.row,
      ]);
      // Domain ownership is immutable while a collection runs, so read each
      // row's owner at most once.
      final ownerCache = DomainRowOwnerCache();
      Future<CrdtMergeChange> resolve(_PlannedChange change) =>
          switch (change.ref.kind) {
            OutboundChangeKind.insert => _resolveInsert(
              session,
              spaceUuidById,
              change.row!,
              attemptedValueFieldsByRowId[change.row!.id!],
              ownerCache,
            ),
            OutboundChangeKind.update => _resolveUpdate(
              session,
              spaceUuidById,
              change.field!,
              ownerCache,
            ),
            OutboundChangeKind.delete => _resolveDelete(
              session,
              spaceUuidById,
              change.tombstone!,
              ownerCache,
            ),
          };
      void markSent(_PlannedChange change) {
        if (!releasedRows.contains(change.rowKey)) return;
        // Pending or not: once sent, the checkpoint is past it, and the next
        // collection reads it only as released.
        released.entries.add(change.sentKey);
        released.rows.add(change.rowKey);
      }

      final meter = OutboundBatchMeter(_batchBudget);
      final units = planOutboundUnits([for (final change in planned) change.ref]);
      for (final unit in units) {
        if (!meter.isEmpty && !meter.fitsChanges(unit.length)) {
          outbound.hasMore = true;
          return;
        }
        final parts = [
          for (final part in unit.parts)
            [
              for (final index in part)
                (planned: planned[index], change: await resolve(planned[index])),
            ],
        ];
        final partPayloads = [
          for (final part in parts)
            part.fold(0, (sum, entry) => sum + meter.payloadOf(entry.change)),
        ];
        final unitPayload = partPayloads.fold(0, (sum, chars) => sum + chars);
        if (meter.fits(changes: unit.length, payloadChars: unitPayload)) {
          meter.add(changes: unit.length, payloadChars: unitPayload);
          for (final part in parts) {
            for (final entry in part) {
              markSent(entry.planned);
              yield entry.change;
            }
          }
          continue;
        }
        if (!meter.isEmpty) {
          outbound.hasMore = true;
          return;
        }
        // The unit alone exceeds the budget: its groups go whole while they
        // fit, and one that does not fit an empty batch keeps only what
        // resuming needs.
        var firstPart = 0;
        for (final group in unit.groups) {
          final groupEnd = firstPart + group.length;
          final groupParts = parts.sublist(firstPart, groupEnd);
          final groupPayloads = partPayloads.sublist(firstPart, groupEnd);
          firstPart = groupEnd;
          final groupLength = groupParts.fold(0, (sum, part) => sum + part.length);
          final groupPayload = groupPayloads.fold(0, (sum, chars) => sum + chars);
          if (meter.fits(changes: groupLength, payloadChars: groupPayload)) {
            meter.add(changes: groupLength, payloadChars: groupPayload);
            for (final part in groupParts) {
              for (final entry in part) {
                markSent(entry.planned);
                yield entry.change;
              }
            }
            continue;
          }
          if (!meter.isEmpty) {
            outbound.hasMore = true;
            return;
          }
          for (var index = 0; index < groupParts.length; index++) {
            final part = groupParts[index];
            if (!meter.isEmpty &&
                !meter.fits(changes: part.length, payloadChars: groupPayloads[index])) {
              outbound.hasMore = true;
              return;
            }
            meter.add(changes: part.length, payloadChars: groupPayloads[index]);
            for (final entry in part) {
              markSent(entry.planned);
              yield entry.change;
            }
          }
        }
      }
    } on PendingOutboundIntegrityViolation catch (violation) {
      await _recordAndThrowIntegrityViolation(session, violation);
    }
  }

  /// Creates the [OfflineSyncSinceHlc] checkpoint for a space handshake.
  ///
  /// [OfflineSyncSinceHlc.nodeCheckpoints] reflects the latest change this node
  /// has received from each known node, tagged with the source node id.
  Future<OfflineSyncSinceHlc> createSyncSinceHlc(
    DatabaseSession session, {
    required UuidValue spaceId,
  }) async {
    final space = await OfflineSyncSpaceManager(
      session,
      context: _databaseContext,
    ).getOrCreate(spaceId);
    final localNodeId = space.currentNode!.uuidNodeId;

    final spaceNodes = await OfflineSyncSpaceNode.db.find(
      session,
      where: (t) =>
          t.spaceId.equals(space.id) & t.nodeId.notEquals(space.currentNodeId),
      include: OfflineSyncSpaceNode.include(node: CrdtNode.include()),
    );

    return OfflineSyncSinceHlc(
      uuidSpaceId: spaceId,
      nodeCheckpoints: [
        // The local node is always included to avoid collecting its own changes.
        Hlc.now(localNodeId),
        for (final spaceNode in spaceNodes)
          spaceNode.lastReceivedHlc ?? Hlc.zero(spaceNode.node!.uuidNodeId),
      ],
    );
  }

  /// Merges a remote [mergeSet] and records the sync checkpoint for [otherNodeId]
  /// from its own changes in the set.
  ///
  /// Inbound merge applies each remote change, then materializes foreign-key
  /// projection into domain tables via [OfflineSyncDatabase.mergeChanges].
  ///
  /// Throws if the merge fails. The sync stream should be closed so the next
  /// attempt resumes from the last persisted checkpoint.
  ///
  /// Returns the greatest HLC synced in the batch, or `null` if the batch is
  /// empty.
  Future<Hlc?> _mergeInboundBatch(
    DatabaseSession session, {
    required UuidValue spaceId,
    required UuidValue otherNodeId,
    required CrdtMergeSet mergeSet,
  }) async {
    if (mergeSet.isEmpty) return null;
    final maxSyncedHlc = mergeSet.maxHlc;
    final offlineSyncDb = _openOfflineSyncDatabase(session);
    await offlineSyncDb.mergeChanges(mergeSet, spaceId: spaceId);
    // Fork (unibook#14218): the checkpoint of [otherNodeId] takes only its own
    // changes. Upstream recorded the batch maximum whichever node authored it,
    // and the stored timestamp kept that node's id, so the next handshake
    // named that node and left [otherNodeId] without a checkpoint: all its
    // changes in the space went out again every session until it wrote a
    // later one. With a server node per space, the node a connect frame names
    // can hold history in a space it no longer writes in (a space that left a
    // shared node), where that never happens.
    Hlc? maxOwnHlc;
    for (final change in mergeSet) {
      if (change.uuidNodeId != otherNodeId) continue;
      maxOwnHlc = change.hlc.maxBetween(maxOwnHlc);
    }
    if (maxOwnHlc != null) {
      await offlineSyncDb.recordSyncCheckpoint(
        otherNodeId,
        maxOwnHlc,
        userId: spaceId,
      );
    }
    return maxSyncedHlc;
  }

  /// Runs a symmetric CRDT sync session over a bidirectional event stream.
  ///
  /// Both peers exchange [OfflineSyncConnect] and a lockstep [OfflineSyncSpaceSet]
  /// before the data loop. Each cycle sends a combined batch — space
  /// announcement when grants changed, [OfflineSyncSinceHlc] for newly active
  /// spaces, and [OfflineSyncMergeChunk]s — closed by [OfflineSyncEndOfBatch] when
  /// anything was sent. Inbound frames are de-multiplexed by collectNextBatch
  /// until [OfflineSyncEndOfBatch] when this peer sent a batch, or an idle timeout
  /// when both peers had nothing to send.
  ///
  /// When [once] is true the loop may run an extra cycle after handshakes
  /// complete so merge data can flow; then it closes symmetrically. Continuous
  /// mode loops with [_continuousSyncInterval] between idle cycles.
  ///
  /// [continuousSyncInterval] asks for a longer delay between this continuous
  /// session's rounds (fork, unibook#14207). It travels to the other peer in
  /// [OfflineSyncConnect.continuousSyncInterval], and each peer waits
  /// [resolveContinuousSyncInterval] of both requests under its own settings.
  /// A `once` session has no rounds to space: it sends no request and ignores
  /// the peer's.
  Stream<OfflineSyncStreamEvent> sync(
    DatabaseSession session, {
    required UuidValue userId,
    required Stream<OfflineSyncStreamEvent> inbound,
    required OfflineSyncPeerMode mode,
    bool once = false,
    OfflineSyncOnMergeSuccess? onMergeSuccess,
    Duration? continuousSyncInterval,
  }) async* {
    // Fork (unibook#14218): a follower is a device, whose spaces share one
    // node. Its own checkpoints and its unsent row count follow that one node,
    // the one its connect frame names, so a follower whose spaces each had a
    // node would silently leave every other space's writes out of them.
    if (mode == OfflineSyncPeerMode.follower && _databaseContext.assignsNodePerSpace) {
      throw StateError(
        'A follower syncs as a device: open its database with a persistent '
        'user, so that its spaces share one CRDT node. This database gives '
        'every space its own node, as a server does.',
      );
    }

    // Idle timeouts are a continuous-only affordance: they let an idle cycle
    // settle into an empty batch without closing the stream. A `once` session
    // is strictly lockstep — every batch ends with a [OfflineSyncEndOfBatch] and
    // the session with a [OfflineSyncClose] — so it must wait for those end frames
    // rather than truncate a slow peer's batch on a timeout.
    final inboundIterator = StreamIterator(
      once
          ? inbound
          : inbound.timeout(
              const Duration(seconds: 1),
              onTimeout: (sink) => sink.add(OfflineSyncIdleTimeout()),
            ),
    );

    var sessionCompleted = false;
    try {
      final space = await OfflineSyncSpaceManager(
        session,
        context: _databaseContext,
      ).getOrCreate(userId);
      // Fork (unibook#14218): a server gives each space its own node, so a
      // session over several spaces has several server nodes, and this frame
      // names the one of the user's personal space. That stays consistent: a
      // device only keys its per-space checkpoint of this peer with it
      // ([_mergeInboundBatch]), every change carries its own node id, and each
      // space's handshake excludes that space's own node
      // ([createSyncSinceHlc]).
      final localNodeId = space.currentNode!.uuidNodeId;
      yield OfflineSyncConnect(
        localNodeId: localNodeId,
        syncTablesHash: currentSyncTablesHash,
        continuousSyncInterval: once ? null : continuousSyncInterval,
      );

      final peerConnect = await inboundIterator.moveAndThrowIfNot<OfflineSyncConnect>();
      _validateSyncTablesHash(peerConnect.syncTablesHash);
      // Fork (unibook#14207): fixed for the session. Only the continuous loop
      // below waits it; a `once` session returns before that.
      final roundInterval = resolveContinuousSyncInterval(
        local: continuousSyncInterval,
        peer: peerConnect.continuousSyncInterval,
      );

      final spaces = OfflineSyncSpaceState(
        session,
        context: _databaseContext,
        userId: userId,
        mode: mode,
        peerNodeId: peerConnect.localNodeId,
      );

      await spaces.reconcile();
      yield OfflineSyncSpaceSet(spaces: spaces.localGrants);
      spaces.markAnnounced();
      final peerSpaceSet = await inboundIterator
          .moveAndThrowIfNot<OfflineSyncSpaceSet>();
      await spaces.adoptPeerGrants(peerSpaceSet.spaces);

      // Fork (unibook#14251): what this session sent of the released rows,
      // so each is sent once per session and confirmed at its end.
      final released = _ReleasedRowsSent();

      while (true) {
        await spaces.reconcile();

        final hadSendableCheckpoints = spaces.sendableCheckpoints.isNotEmpty;
        var hasChanges = false;
        final outboundSpaces = <UuidValue>{};

        if (spaces.shouldAnnounce) {
          yield OfflineSyncSpaceSet(spaces: spaces.localGrants);
          spaces.markAnnounced();
          hasChanges = true;
        }

        for (final spaceId in spaces.activeSpaceIds) {
          if (!spaces.markHandshakeSent(spaceId)) continue;
          yield await createSyncSinceHlc(session, spaceId: spaceId);
          hasChanges = true;
        }

        // Fork (unibook#14251): with a batch budget or row isolation, the
        // batch is planned (HLC order, cut where resuming skips nothing) and
        // may end before every pending change is sent.
        final outbound = _OutboundBatch();
        final pendingLocalChanges = _batchBudget.isUnlimited && _rowIsolation == null
            ? collectPendingChanges(
                session,
                checkpointsBySpaceUuid: spaces.sendableCheckpoints,
              )
            : _collectPlannedBatch(
                session,
                checkpointsBySpaceUuid: spaces.sendableCheckpoints,
                outbound: outbound,
                released: released,
              );

        await for (final changes in pendingLocalChanges.chunked(_syncBatchSize)) {
          hasChanges = true;
          for (final change in changes) {
            spaces.advanceCheckpoint(change.uuidSpaceId, change);
            outboundSpaces.add(change.uuidSpaceId);
          }
          yield OfflineSyncMergeChunk(changes: changes);
        }
        if (hasChanges || once) {
          yield OfflineSyncEndOfBatch(hasMore: outbound.hasMore);
        }

        final batch = await inboundIterator.collectNextBatch(
          allowCloseBeforeBatch: !once,
        );
        if (batch == null) {
          if (once) {
            yield OfflineSyncClose();
          }
          sessionCompleted = true;
          return;
        }

        await _applyCycleBatch(
          session,
          spaces,
          batch,
          outboundSpaces,
          onMergeSuccess,
          localNodeId: localNodeId,
        );

        if (once) {
          if (spaces.hasIncompleteActiveHandshake) {
            continue;
          }
          if (!hadSendableCheckpoints && spaces.sendableCheckpoints.isNotEmpty) {
            continue;
          }
          // Fork (unibook#14251): both peers read both flags, so both run the
          // extra round or neither does. A peer built before the flag sends
          // none and closes here, so this peer closes too.
          final peerHasMore = batch.peerHasMore;
          if (peerHasMore != null && (outbound.hasMore || peerHasMore)) {
            continue;
          }
          yield OfflineSyncClose();
          await inboundIterator.moveAndThrowIfNot<OfflineSyncClose>();
          sessionCompleted = true;
          // Keep reading until the peer closes its side so the underlying
          // transport subscription reaches "done" instead of being left paused.
          // A paused inbound controller stalls the peer's stream teardown for
          // several seconds (the transport's close timeout), which lands on the
          // critical path of the next sync round over a shared connection.
          //
          // The drain runs detached: awaiting it here would deadlock the
          // symmetric close handshake, since the peer only closes its side once
          // our own outbound stream closes, which happens after this generator
          // returns.
          unawaited(_drainUntilDone(inboundIterator));
          if (!spaces.isAuthoritative) {
            await _recordConfirmedLocalCheckpoints(session, spaces, localNodeId);
          }
          // Fork (unibook#14251): the peer merged every batch before it
          // closed. Only a session that sent everything it collected confirms:
          // closing with more to send (an old peer) may have left a released
          // row half sent.
          if (!outbound.hasMore && released.rows.isNotEmpty) {
            await _rowIsolation?.onReleasedRowsConfirmed(
              Set.unmodifiable(released.rows),
            );
            // The sets changed after the commits the unsent row count watch
            // triggers on, and a count those commits started may have read
            // them before. Only now: the confirmed checkpoint is recorded
            // first, so a failure to record it leaves the sets as they were.
            _databaseContext.notifyUnsentRowCountInputsChanged();
          }
          return;
        }

        // Wait for the session's interval before checking for local changes again.
        await Future<void>.delayed(roundInterval);
      }
    } on OfflineSyncStreamClosedException {
      // A continuous session ending is normal: the peer closed its outbound
      // (typically a cancel). Whether the stream closed between batches or
      // mid-batch, nothing is left to do — complete gracefully so the `finally`
      // skips the force-cancel that races WebSocket teardown and surfaces
      // spurious "connection closed" errors on the peer. A `once` session has a
      // completion contract (full handshake plus the symmetric Close), so a
      // close before that is a real truncation and must propagate.
      if (once) rethrow;
      sessionCompleted = true;
      return;
    } finally {
      // Cancelling inbound on normal completion races with WebSocket stream
      // teardown and produces "connection closed" errors on the peer. On normal
      // completion the inbound is instead drained to "done" (see above). Keep
      // forced cancellation for abnormal exits so listener cancellation can
      // unblock.
      if (!sessionCompleted) {
        // Best-effort cleanup, since the transport will close the socket anyway.
        const waitTimeout = Duration(milliseconds: 200);
        await inboundIterator.cancel().timeout(waitTimeout, onTimeout: () {});
      }
    }
  }

  Future<void> _applyCycleBatch(
    DatabaseSession session,
    OfflineSyncSpaceState spaces,
    OfflineSyncCycleBatch batch,
    Set<UuidValue> outboundSpaces,
    OfflineSyncOnMergeSuccess? onMergeSuccess, {
    required UuidValue localNodeId,
  }) async {
    if (batch.spaceSet != null) {
      await spaces.adoptPeerGrants(batch.spaceSet!.spaces);
    }
    for (final entry in batch.sinceHlcs.entries) {
      if (spaces.accepts(entry.key)) {
        spaces.recordPeerHandshake(entry.key, entry.value);
        if (!spaces.isAuthoritative) {
          // Fork (unibook#14183): the server's handshake says how far it has
          // this device's changes. Keep that as the confirmed checkpoint the
          // unsent row count starts from, replacing the recorded one even when
          // it is lower (the server lost data), since this is the checkpoint
          // this session sends from.
          await _replaceOwnCheckpoint(
            session,
            spaceId: entry.key,
            nodeId: localNodeId,
            hlc: spaces.checkpointOf(entry.key, localNodeId),
          );
        }
      }
    }

    final mergedSpaces = <UuidValue>{};
    final changesBySpace = <UuidValue, List<CrdtMergeChange>>{};
    for (final change in batch.changes) {
      changesBySpace.putIfAbsent(change.uuidSpaceId, () => []).add(change);
    }
    for (final entry in changesBySpace.entries) {
      final spaceId = entry.key;
      if (!spaces.accepts(spaceId)) continue;
      mergedSpaces.add(spaceId);
      if (spaces.isAuthoritative) {
        await _assertCanMergeInboundSpace(
          session,
          spaceId: spaceId,
          userId: spaces.userId,
          changes: entry.value,
        );
      }
      final receivedHlc = await _mergeInboundBatch(
        session,
        spaceId: spaceId,
        otherNodeId: spaces.peerNodeId,
        mergeSet: entry.value,
      );
      await _reportMerge(onMergeSuccess, spaces, spaceId, receivedHlc);
    }
    for (final spaceId in outboundSpaces.difference(mergedSpaces)) {
      await _reportMerge(onMergeSuccess, spaces, spaceId, null);
    }
  }

  Future<void> _assertCanMergeInboundSpace(
    DatabaseSession session, {
    required UuidValue spaceId,
    required UuidValue userId,
    required List<CrdtMergeChange> changes,
  }) async {
    if (changes.isEmpty || userId == spaceId) return;

    final role = await OfflineSyncSpaceMembership.roleOf(
      session,
      userUuid: userId,
      spaceUuid: spaceId,
    );
    if (role.canWrite) return;

    final firstChange = changes.first;
    final now = clock.now().toUtc();
    final violation = OfflineSyncIntegrityViolation(
      type: OfflineSyncViolationType.unauthorizedWrite,
      domainTableName: firstChange.tableName,
      uuidRowId: firstChange.uuidRowId,
      ownerSpaceUuid: null,
      incomingSpaceUuid: spaceId,
      operation: _operationForInboundChange(firstChange),
      uuidNodeId: firstChange.uuidNodeId,
      crdtDataRowId: null,
      hlcDatetime: firstChange.hlcDatetime,
      hlcCounter: firstChange.hlcCounter,
      firstSeenAt: now,
      lastSeenAt: now,
      occurrences: 1,
    );
    final persisted = await recordOfflineSyncIntegrityViolation(
      session,
      violation: violation,
    );
    throw OfflineSyncIntegrityViolationException(persisted);
  }

  OfflineSyncViolationOperation _operationForInboundChange(CrdtMergeChange change) {
    return switch (change) {
      CrdtMergeInsert() => OfflineSyncViolationOperation.mergeInsert,
      CrdtMergeUpdate() => OfflineSyncViolationOperation.mergeUpdate,
      CrdtMergeDelete() => OfflineSyncViolationOperation.mergeDelete,
    };
  }

  /// Records, per handshaken space, this node's checkpoint as confirmed by the
  /// peer: everything this node sent in the session.
  ///
  /// Fork (unibook#14183): only valid once the peer's [OfflineSyncClose] has
  /// arrived. The peer merges each batch before it moves on and closes only
  /// after merging the last one, so by then it holds every change sent. A
  /// failed session never gets here, so its changes stay unsent.
  Future<void> _recordConfirmedLocalCheckpoints(
    DatabaseSession session,
    OfflineSyncSpaceState spaces,
    UuidValue localNodeId,
  ) async {
    for (final spaceId in spaces.handshakenSpaceIds.toList()) {
      final confirmed = spaces.checkpointOf(spaceId, localNodeId);
      if (confirmed == null) continue;
      await _recordOwnCheckpoint(
        session,
        spaceId: spaceId,
        nodeId: localNodeId,
        hlc: confirmed,
      );
    }
  }

  /// Advances this device's own checkpoint in [spaceId] to [hlc], see
  /// [CrdtMutationRecorder.recordSyncCheckpoint].
  Future<void> _recordOwnCheckpoint(
    DatabaseSession session, {
    required UuidValue spaceId,
    required UuidValue nodeId,
    required Hlc hlc,
  }) async {
    final db = session.db;
    if (db is OfflineSyncDatabase) {
      await db.recordSyncCheckpoint(nodeId, hlc, userId: spaceId);
    } else {
      await _checkpointRecorder(db).recordSyncCheckpoint(spaceId, nodeId, hlc);
    }
  }

  /// Sets this device's own checkpoint in [spaceId] to what the peer reported,
  /// see [CrdtMutationRecorder.replaceSyncCheckpoint].
  Future<void> _replaceOwnCheckpoint(
    DatabaseSession session, {
    required UuidValue spaceId,
    required UuidValue nodeId,
    required Hlc? hlc,
  }) async {
    final db = session.db;
    if (db is OfflineSyncDatabase) {
      await db.replaceSyncCheckpoint(nodeId, hlc, userId: spaceId);
    } else {
      await _checkpointRecorder(db).replaceSyncCheckpoint(spaceId, nodeId, hlc);
    }
  }

  /// A recorder over the plain [db] for the device's own checkpoint writes.
  ///
  /// Fork (unibook#14183): unlike [_openOfflineSyncDatabase], this opens no
  /// [OfflineSyncDatabase] wrapper, so it skips the recorder initialization a
  /// new wrapper runs on its first operation. That initialization re-projects
  /// every space while the schema registry changed in this process (a fresh
  /// install, an app update that changed the synchronized schema). The
  /// checkpoint writes run on every round and touch only
  /// `offline_sync_space_nodes`; through a wrapper they made each idle round
  /// pay that pass over the data once per handshaken space plus one. They need
  /// no initialization: the sync that makes them already initialized the
  /// shared context.
  CrdtMutationRecorder _checkpointRecorder(Database db) => CrdtMutationRecorder(
    db,
    context: _databaseContext,
    persistentUserId: null,
  );

  /// Counts the rows of the synchronized tables holding a change authored by
  /// [localNodeId] after the checkpoint recorded for it in the row's space, see
  /// [OfflineSyncDatabase.unsentRowCount].
  ///
  /// Uses the same per-space checkpoint filters as the pending-change
  /// collection, restricted to [localNodeId], so it counts the rows whose
  /// changes a sync from the recorded checkpoints would send. A space without a
  /// recorded checkpoint counts all of the node's rows in it.
  ///
  /// Fork (unibook#14251): every row of [rowIsolation]'s sets that exists
  /// locally counts too, whoever wrote it. The checkpoints pass an isolated
  /// row, so without this a sign-out check would read 0 and drop it.
  Future<int> countUnsentRows(
    DatabaseSession session, {
    required UuidValue localNodeId,
  }) async {
    final tableNames = _syncTablesByName.keys.toSet();
    if (tableNames.isEmpty) return 0;
    final heldRowIds = await _heldRowIds(session);

    // Read the checkpoints before the rows and again after them. One that
    // advanced meanwhile leaves the count high. One that went back (the
    // handshake of a server that lost data replaces it) would leave it low, so
    // the count runs again from the checkpoints read after.
    var confirmed = await _ownCheckpoints(session, localNodeId);
    for (var attempt = 1; ; attempt++) {
      await debugOnUnsentRowCheckpointsRead?.call();
      final count = await _countOwnRowsAfter(
        session,
        localNodeId: localNodeId,
        tableNames: tableNames,
        confirmedBySpaceId: confirmed,
        heldRowIds: heldRowIds,
      );
      final current = await _ownCheckpoints(session, localNodeId);
      if (!_anyCheckpointWentBack(confirmed, current)) return count;
      if (attempt == _unsentRowCountAttempts) {
        // They keep going back: every row of this node is an upper bound.
        return _countOwnRowsAfter(
          session,
          localNodeId: localNodeId,
          tableNames: tableNames,
          confirmedBySpaceId: const {},
          heldRowIds: heldRowIds,
        );
      }
      confirmed = current;
    }
  }

  /// How many times [countUnsentRows] counts before it falls back to counting
  /// every row of the node.
  static const _unsentRowCountAttempts = 3;

  /// Called by [countUnsentRows] after it reads the checkpoints and before it
  /// reads the rows, in every attempt.
  ///
  /// Fork (unibook#14183): lets a test commit a checkpoint change in between.
  @visibleForTesting
  static Future<void> Function()? debugOnUnsentRowCheckpointsRead;

  /// The checkpoint recorded for [localNodeId] per space id, with the node id
  /// normalized to [localNodeId]. A space without one is absent.
  Future<Map<int, Hlc>> _ownCheckpoints(
    DatabaseSession session,
    UuidValue localNodeId,
  ) async {
    final ownSpaceNodes = await OfflineSyncSpaceNode.db.find(
      session,
      where: (t) => t.node.uuidNodeId.equals(localNodeId),
    );
    return {
      for (final spaceNode in ownSpaceNodes)
        if (spaceNode.lastReceivedHlc case final confirmed?)
          spaceNode.spaceId: Hlc(
            confirmed.datetime,
            confirmed.counter,
            localNodeId,
          ),
    };
  }

  /// Whether a checkpoint in [before] is lower or missing in [after].
  static bool _anyCheckpointWentBack(
    Map<int, Hlc> before,
    Map<int, Hlc> after,
  ) {
    for (final MapEntry(key: spaceId, value: checkpoint) in before.entries) {
      final now = after[spaceId];
      if (now == null || now < checkpoint) return true;
    }
    return false;
  }

  /// The CRDT row ids of the rows [rowIsolation] holds back or releases, of the
  /// synchronized tables, that exist locally (fork, unibook#14251).
  Future<Set<int>> _heldRowIds(DatabaseSession session) async {
    final isolation = _rowIsolation;
    if (isolation == null) return const {};
    final idsByTable = <String, Set<UuidValue>>{};
    for (final row in {...isolation.isolatedRows, ...isolation.releasedRows}) {
      if (!_syncTablesByName.containsKey(row.tableName)) continue;
      idsByTable.putIfAbsent(row.tableName, () => {}).add(row.rowId);
    }
    if (idsByTable.isEmpty) return const {};
    final rows = await CrdtDataRow.db.find(
      session,
      where: (t) {
        Expression? any;
        for (final MapEntry(key: table, value: ids) in idsByTable.entries) {
          final expression = t.tbl.name.equals(table) & t.uuidRowId.inSet(ids);
          any = any == null ? expression : any | expression;
        }
        return any!;
      },
    );
    return {for (final row in rows) row.id!};
  }

  /// Counts the rows holding a change of [localNodeId] after its checkpoint in
  /// [confirmedBySpaceId], every row of the node in a space without one, and
  /// the rows of [heldRowIds].
  Future<int> _countOwnRowsAfter(
    DatabaseSession session, {
    required UuidValue localNodeId,
    required Set<String> tableNames,
    required Map<int, Hlc> confirmedBySpaceId,
    Set<int> heldRowIds = const {},
  }) async {
    final spaces = await OfflineSyncSpace.db.find(session);
    final checkpointsBySpaceId = {
      for (final space in spaces) space.id!: [?confirmedBySpaceId[space.id!]],
    };
    if (checkpointsBySpaceId.isEmpty) return heldRowIds.length;

    final rows = await CrdtDataRow.db.find(
      session,
      where: (t) =>
          _rowHlcAfterFilter(t, checkpointsBySpaceId) &
          t.node.uuidNodeId.equals(localNodeId) &
          t.tbl.name.inSet(tableNames),
    );
    final fields = await CrdtDataField.db.find(
      session,
      where: (t) =>
          _fieldHlcAfterFilter(t, checkpointsBySpaceId) &
          t.node.uuidNodeId.equals(localNodeId) &
          t.row.tbl.name.inSet(tableNames),
    );
    final tombstones = await CrdtDataDeleted.db.find(
      session,
      where: (t) =>
          _tombstoneHlcAfterFilter(t, checkpointsBySpaceId) &
          t.node.uuidNodeId.equals(localNodeId) &
          t.row.tbl.name.inSet(tableNames) &
          t.reason.inSet(_syncedDeletedReasons),
    );

    return {
      for (final row in rows) row.id!,
      for (final field in fields) field.rowId,
      for (final tombstone in tombstones) tombstone.rowId,
      ...heldRowIds,
    }.length;
  }

  /// The tombstone reasons the pending-change collection sends.
  static final Set<CrdtDataDeletedReason> _syncedDeletedReasons = {
    for (final reason in CrdtDataDeletedReason.values)
      if (reason.isSynced) reason,
  };

  /// Reports a successful merge for [spaceId] to [onMergeSuccess], combining the
  /// space's checkpoint high-water mark with the [receivedHlc] just merged.
  Future<void> _reportMerge(
    OfflineSyncOnMergeSuccess? onMergeSuccess,
    OfflineSyncSpaceState spaces,
    UuidValue spaceId,
    Hlc? receivedHlc,
  ) async {
    final checkpointMax = spaces.checkpointMaxOf(spaceId);
    if (checkpointMax == null) return;
    await onMergeSuccess?.call(spaceId, checkpointMax.maxBetween(receivedHlc));
  }

  /// Drains [iterator] until the peer closes the stream.
  ///
  /// Used to settle the inbound transport after the `once` close handshake so
  /// its controller reaches "done" with an active listener instead of being
  /// torn down while paused. Trailing events (idle timeouts, late frames) are
  /// discarded; errors are swallowed since the transport is closing anyway.
  static Future<void> _drainUntilDone(
    StreamIterator<OfflineSyncStreamEvent> iterator,
  ) async {
    try {
      while (await iterator.moveNext()) {
        // Discard whatever the peer sends before it closes its side.
      }
    } on Object catch (_) {
      // Best-effort: the transport is shutting down.
    }
  }

  void _validateSyncTablesHash(String syncTablesHash) {
    if (syncTablesHash != currentSyncTablesHash) {
      throw OfflineSyncTablesHashMismatchException(
        received: syncTablesHash,
        expected: currentSyncTablesHash,
      );
    }
  }

  OfflineSyncDatabase _openOfflineSyncDatabase(DatabaseSession session) {
    final db = session.db;
    // The wrapper is ephemeral and every operation performed on it lazily
    // ensures initialization, so there is nothing to eagerly initialize here.
    // Calling `initialize()` would re-run the per-session setup.
    return db is OfflineSyncDatabase ? db : wrapDatabase(db);
  }

  Stream<CrdtMergeChange> _streamPendingChanges(
    DatabaseSession session,
    Map<int, UuidValue> spaceUuidById,
    Map<int, List<Hlc>> checkpointsBySpaceId,
  ) async* {
    final pending = await _readPendingChanges(session, checkpointsBySpaceId);
    // Domain ownership is immutable while a collection runs, so read each
    // row's owner at most once across all three streams.
    final ownerCache = DomainRowOwnerCache();
    yield* _streamInserts(session, spaceUuidById, pending.rows, ownerCache);
    yield* _streamUpdates(session, spaceUuidById, pending.fields, ownerCache);
    yield* _streamDeletes(session, spaceUuidById, pending.tombstones, ownerCache);
  }

  /// Reads the pending inserts, updates and deletes after
  /// [checkpointsBySpaceId] from one snapshot of the database.
  ///
  /// Fork (unibook#14183): upstream ran each kind's query when its stream
  /// started, so a write committed between two of them was seen by the later
  /// one only. An update read after a missed insert then advanced the node's
  /// checkpoint past the insert, and no later session sent it. A node's writes
  /// commit in HLC order (each locks the node before stamping), so what one
  /// snapshot holds of a node is everything up to some HLC: advancing past the
  /// highest change sent skips none. A write committed after the snapshot is
  /// above it and waits for the next collection.
  ///
  /// A transaction takes the snapshot: repeatable read on PostgreSQL, the
  /// write lock on SQLite. It holds only these three queries; domain values
  /// are read afterwards, as each change is yielded.
  ///
  /// Fork (unibook#14251): with [releasedRows], the same snapshot also reads
  /// every change of those rows in the spaces of [checkpointsBySpaceId],
  /// whatever the checkpoints (`released*`). Without them, no query is added.
  Future<
    ({
      List<CrdtDataRow> rows,
      List<CrdtDataField> fields,
      List<CrdtDataDeleted> tombstones,
      List<CrdtDataRow> releasedRows,
      List<CrdtDataField> releasedFields,
      List<CrdtDataDeleted> releasedTombstones,
    })
  >
  _readPendingChanges(
    DatabaseSession session,
    Map<int, List<Hlc>> checkpointsBySpaceId, {
    Set<OfflineSyncRowKey> releasedRows = const {},
  }) => session.db.transaction(
    (transaction) async {
      final rows = await CrdtDataRow.db.find(
        session,
        where: (t) => _rowHlcAfterFilter(t, checkpointsBySpaceId),
        include: CrdtDataRow.include(
          tbl: CrdtSchemaTable.include(),
          node: CrdtNode.include(),
        ),
        transaction: transaction,
      );
      await debugOnPendingRowsRead?.call(session);
      final fields = await CrdtDataField.db.find(
        session,
        where: (t) => _fieldHlcAfterFilter(t, checkpointsBySpaceId),
        include: CrdtDataField.include(
          row: CrdtDataRow.include(tbl: CrdtSchemaTable.include()),
          column: CrdtSchemaColumn.include(),
          node: CrdtNode.include(),
          attemptedValue: CrdtDataAttemptedValue.include(),
        ),
        transaction: transaction,
      );
      final tombstones = await CrdtDataDeleted.db.find(
        session,
        where: (t) => _tombstoneHlcAfterFilter(t, checkpointsBySpaceId),
        include: CrdtDataDeleted.include(
          row: CrdtDataRow.include(tbl: CrdtSchemaTable.include()),
          node: CrdtNode.include(),
        ),
        transaction: transaction,
      );
      final releasedIdsByTable = <String, Set<UuidValue>>{
        for (final row in releasedRows)
          if (_syncTablesByName.containsKey(row.tableName)) row.tableName: {},
      };
      for (final row in releasedRows) {
        releasedIdsByTable[row.tableName]?.add(row.rowId);
      }
      if (releasedIdsByTable.isEmpty) {
        return (
          rows: rows,
          fields: fields,
          tombstones: tombstones,
          releasedRows: const <CrdtDataRow>[],
          releasedFields: const <CrdtDataField>[],
          releasedTombstones: const <CrdtDataDeleted>[],
        );
      }
      final spaceIds = checkpointsBySpaceId.keys.toSet();
      Expression releasedFilter(
        ColumnString tableName,
        ColumnUuid rowId,
        ColumnInt spaceId,
      ) {
        Expression? any;
        for (final MapEntry(key: table, value: ids) in releasedIdsByTable.entries) {
          final expression = tableName.equals(table) & rowId.inSet(ids);
          any = any == null ? expression : any | expression;
        }
        return spaceId.inSet(spaceIds) & any!;
      }

      return (
        rows: rows,
        fields: fields,
        tombstones: tombstones,
        releasedRows: await CrdtDataRow.db.find(
          session,
          where: (t) => releasedFilter(t.tbl.name, t.uuidRowId, t.spaceId),
          include: CrdtDataRow.include(
            tbl: CrdtSchemaTable.include(),
            node: CrdtNode.include(),
          ),
          transaction: transaction,
        ),
        releasedFields: await CrdtDataField.db.find(
          session,
          where: (t) => releasedFilter(t.row.tbl.name, t.row.uuidRowId, t.row.spaceId),
          include: CrdtDataField.include(
            row: CrdtDataRow.include(tbl: CrdtSchemaTable.include()),
            column: CrdtSchemaColumn.include(),
            node: CrdtNode.include(),
            attemptedValue: CrdtDataAttemptedValue.include(),
          ),
          transaction: transaction,
        ),
        releasedTombstones: await CrdtDataDeleted.db.find(
          session,
          where: (t) => releasedFilter(t.row.tbl.name, t.row.uuidRowId, t.row.spaceId),
          include: CrdtDataDeleted.include(
            row: CrdtDataRow.include(tbl: CrdtSchemaTable.include()),
            node: CrdtNode.include(),
          ),
          transaction: transaction,
        ),
      );
    },
    settings: const TransactionSettings(
      isolationLevel: IsolationLevel.repeatableRead,
    ),
  );

  /// Called by the pending-change collection with its session, inside its
  /// snapshot, after it reads the pending inserts and before it reads the
  /// updates.
  ///
  /// Fork (unibook#14183): lets a test commit a write in between, which the
  /// snapshot must keep out of the collection.
  @visibleForTesting
  static Future<void> Function(DatabaseSession session)? debugOnPendingRowsRead;

  Stream<CrdtMergeInsert> _streamInserts(
    DatabaseSession session,
    Map<int, UuidValue> spaceUuidById,
    List<CrdtDataRow> rows,
    DomainRowOwnerCache ownerCache,
  ) async* {
    final attemptedValueFieldsByRowId = await _loadAttemptedValueFields(
      session,
      rows,
    );

    for (final row in rows) {
      if (!_sendsInsert(row)) continue;
      yield await _resolveInsert(
        session,
        spaceUuidById,
        row,
        attemptedValueFieldsByRowId[row.id!],
        ownerCache,
      );
    }
  }

  /// Whether the pending [row] is sent as an insert.
  bool _sendsInsert(CrdtDataRow row) {
    final tableName = row.tbl!.name;
    return _syncTablesByName.containsKey(tableName) &&
        _classNamesByTableName[tableName] != null;
  }

  /// The insert for the pending [row], which [_sendsInsert] accepted.
  Future<CrdtMergeInsert> _resolveInsert(
    DatabaseSession session,
    Map<int, UuidValue> spaceUuidById,
    CrdtDataRow row,
    List<CrdtDataField>? attemptedValueFields,
    DomainRowOwnerCache ownerCache,
  ) async {
    final tableName = row.tbl!.name;
    final table = _syncTablesByName[tableName]!;
    final dartName = _classNamesByTableName[tableName]!;

    final spaceId = row.spaceId;
    final spaceUuid = spaceUuidById[spaceId]!;

    final domainRow = await _fetchDomainRow(
      session,
      tableName,
      row.uuidRowId,
      table,
      dartName,
      attemptedValueFields,
      spaceId,
      ownerCache,
    );
    if (!domainRow.exists) {
      _throwPendingIntegrityViolation(
        crdtDataRowId: row.id,
        type: OfflineSyncViolationType.missingDomainRow,
        operation: OfflineSyncViolationOperation.outboundInsert,
        tableName: tableName,
        rowId: row.uuidRowId,
        ownerSpaceId: null,
        incomingSpaceUuid: spaceUuid,
        uuidNodeId: row.node!.uuidNodeId,
        hlc: row.hlc,
      );
    }
    if (domainRow.ownerSpaceId != spaceId) {
      _throwPendingIntegrityViolation(
        crdtDataRowId: row.id,
        type: OfflineSyncViolationType.ownershipCollision,
        operation: OfflineSyncViolationOperation.outboundInsert,
        tableName: tableName,
        rowId: row.uuidRowId,
        ownerSpaceId: domainRow.ownerSpaceId,
        incomingSpaceUuid: spaceUuid,
        uuidNodeId: row.node!.uuidNodeId,
        hlc: row.hlc,
      );
    }

    return CrdtMergeInsert(
      uuidSpaceId: spaceUuid,
      hlcDatetime: row.hlcDatetime,
      hlcCounter: row.hlcCounter,
      tableName: tableName,
      uuidRowId: row.uuidRowId,
      uuidNodeId: row.node!.uuidNodeId,
      data: domainRow.row,
    );
  }

  Stream<CrdtMergeUpdate> _streamUpdates(
    DatabaseSession session,
    Map<int, UuidValue> spaceUuidById,
    List<CrdtDataField> fields,
    DomainRowOwnerCache ownerCache,
  ) async* {
    for (final field in fields) {
      if (!_sendsUpdate(field)) continue;
      yield await _resolveUpdate(session, spaceUuidById, field, ownerCache);
    }
  }

  /// Whether the pending [field] is sent as an update: not when it was written
  /// with its row's insert, which carries it.
  bool _sendsUpdate(CrdtDataField field) {
    final tableName = field.row!.tbl!.name;
    if (!_syncTablesByName.containsKey(tableName)) return false;
    return !(field.hlcDatetime == field.row!.hlcDatetime &&
        field.hlcCounter == field.row!.hlcCounter &&
        field.nodeId == field.row!.nodeId);
  }

  /// The update for the pending [field], which [_sendsUpdate] accepted.
  Future<CrdtMergeUpdate> _resolveUpdate(
    DatabaseSession session,
    Map<int, UuidValue> spaceUuidById,
    CrdtDataField field,
    DomainRowOwnerCache ownerCache,
  ) async {
    final tableName = field.row!.tbl!.name;
    final spaceId = field.row!.spaceId;
    final spaceUuid = spaceUuidById[spaceId]!;
    final columnName = field.column!.name;
    final columnValue = await _fetchOwnedColumnValue(
      session,
      tableName,
      field.row!.uuidRowId,
      columnName,
      field.attemptedValue,
      spaceId,
      ownerCache,
    );
    if (!columnValue.exists) {
      _throwPendingIntegrityViolation(
        crdtDataRowId: field.row!.id,
        type: OfflineSyncViolationType.missingDomainRow,
        operation: OfflineSyncViolationOperation.outboundUpdate,
        tableName: tableName,
        rowId: field.row!.uuidRowId,
        ownerSpaceId: null,
        incomingSpaceUuid: spaceUuid,
        uuidNodeId: field.node!.uuidNodeId,
        hlc: field.hlc,
      );
    }
    if (columnValue.ownerSpaceId != spaceId) {
      _throwPendingIntegrityViolation(
        crdtDataRowId: field.row!.id,
        type: OfflineSyncViolationType.ownershipCollision,
        operation: OfflineSyncViolationOperation.outboundUpdate,
        tableName: tableName,
        rowId: field.row!.uuidRowId,
        ownerSpaceId: columnValue.ownerSpaceId,
        incomingSpaceUuid: spaceUuid,
        uuidNodeId: field.node!.uuidNodeId,
        hlc: field.hlc,
      );
    }

    return CrdtMergeUpdate(
      uuidSpaceId: spaceUuid,
      hlcDatetime: field.hlcDatetime,
      hlcCounter: field.hlcCounter,
      tableName: tableName,
      uuidRowId: field.row!.uuidRowId,
      uuidNodeId: field.node!.uuidNodeId,
      columnName: columnName,
      value: columnValue.value,
    );
  }

  Stream<CrdtMergeDelete> _streamDeletes(
    DatabaseSession session,
    Map<int, UuidValue> spaceUuidById,
    List<CrdtDataDeleted> tombstones,
    DomainRowOwnerCache ownerCache,
  ) async* {
    for (final tombstone in tombstones) {
      if (!_sendsDelete(tombstone)) continue;
      yield await _resolveDelete(session, spaceUuidById, tombstone, ownerCache);
    }
  }

  /// Whether the pending [tombstone] is sent as a delete.
  bool _sendsDelete(CrdtDataDeleted tombstone) =>
      tombstone.reason.isSynced &&
      _syncTablesByName.containsKey(tombstone.row!.tbl!.name);

  /// The delete for the pending [tombstone], which [_sendsDelete] accepted.
  Future<CrdtMergeDelete> _resolveDelete(
    DatabaseSession session,
    Map<int, UuidValue> spaceUuidById,
    CrdtDataDeleted tombstone,
    DomainRowOwnerCache ownerCache,
  ) async {
    final tableName = tombstone.row!.tbl!.name;
    final spaceId = tombstone.row!.spaceId;
    final spaceUuid = spaceUuidById[spaceId]!;
    final owner = await _readDomainRowOwner(
      session,
      tableName,
      tombstone.row!.uuidRowId,
      ownerCache,
    );
    if (owner.exists && owner.spaceId != spaceId) {
      _throwPendingIntegrityViolation(
        crdtDataRowId: tombstone.row!.id,
        type: OfflineSyncViolationType.ownershipCollision,
        operation: OfflineSyncViolationOperation.outboundDelete,
        tableName: tableName,
        rowId: tombstone.row!.uuidRowId,
        ownerSpaceId: owner.spaceId,
        incomingSpaceUuid: spaceUuid,
        uuidNodeId: tombstone.node!.uuidNodeId,
        hlc: tombstone.hlc,
      );
    }

    return CrdtMergeDelete(
      uuidSpaceId: spaceUuid,
      hlcDatetime: tombstone.hlcDatetime,
      hlcCounter: tombstone.hlcCounter,
      tableName: tableName,
      uuidRowId: tombstone.row!.uuidRowId,
      uuidNodeId: tombstone.node!.uuidNodeId,
      clFlag: tombstone.clFlag,
      reason: tombstone.reason,
    );
  }

  Expression _rowHlcAfterFilter(
    CrdtDataRowTable t,
    Map<int, List<Hlc>> checkpointsBySpaceId,
  ) =>
      t.spaceId.inSet(checkpointsBySpaceId.keys.toSet()) &
      _afterAnySpaceCheckpointFilter(
        t.spaceId,
        t.node.uuidNodeId,
        t.hlcDatetime,
        t.hlcCounter,
        checkpointsBySpaceId,
      );

  Expression _fieldHlcAfterFilter(
    CrdtDataFieldTable t,
    Map<int, List<Hlc>> checkpointsBySpaceId,
  ) =>
      t.row.spaceId.inSet(checkpointsBySpaceId.keys.toSet()) &
      _afterAnySpaceCheckpointFilter(
        t.row.spaceId,
        t.node.uuidNodeId,
        t.hlcDatetime,
        t.hlcCounter,
        checkpointsBySpaceId,
      );

  Expression _tombstoneHlcAfterFilter(
    CrdtDataDeletedTable t,
    Map<int, List<Hlc>> checkpointsBySpaceId,
  ) =>
      t.row.spaceId.inSet(checkpointsBySpaceId.keys.toSet()) &
      _afterAnySpaceCheckpointFilter(
        t.row.spaceId,
        t.node.uuidNodeId,
        t.hlcDatetime,
        t.hlcCounter,
        checkpointsBySpaceId,
      );

  /// Loads a domain row for outbound insert sync.
  ///
  /// Reads the materialized row from the domain table, then swaps any columns
  /// with an active [CrdtDataAttemptedValue] back to the authored value before
  /// deserializing. The domain table and projected columns are only known at
  /// runtime, so a generated repository cannot express this query. Keeping one
  /// targeted SQL projection also avoids fetching and serializing unrelated
  /// columns. This is the inverse of inbound FK materialization: the wire payload
  /// carries attempted facts, not locally projected visible values.
  Future<({bool exists, int? ownerSpaceId, dynamic row})> _fetchDomainRow(
    DatabaseSession session,
    String tableName,
    UuidValue rowId,
    Table table,
    String dartName,
    List<CrdtDataField>? attemptedValueFields,
    int spaceId,
    DomainRowOwnerCache ownerCache,
  ) async {
    final cols = table.columns
        .map(
          (column) =>
              '${_outboundColumnExpression(session, column)} AS "${column.columnName.escapeIdentifier()}"',
        )
        .join(', ');
    final encodedRowId = rowId.sqlLiteral();
    final encodedSpaceId = spaceId.sqlLiteral();
    final escapedTableName = tableName.escapeIdentifier();
    final result = await session.db.unsafeQuery(
      'SELECT $cols FROM "$escapedTableName" '
      'WHERE "id" = $encodedRowId AND "spaceId" = $encodedSpaceId '
      'LIMIT 1',
    );
    if (result.isEmpty) {
      final owner = await _readDomainRowOwner(session, tableName, rowId, ownerCache);
      return (exists: owner.exists, ownerSpaceId: owner.spaceId, row: null);
    }
    ownerCache[(tableName, rowId)] = (exists: true, spaceId: spaceId);

    final rawColumns = result.first.toColumnMap();
    final columnMap =
        <String, dynamic>{
            for (final column in table.columns)
              column.columnName: _decodeStructuredValue(
                session,
                column,
                rawColumns[column.columnName],
              ),
          }
          // Domain columns hold visible/materialized FK values; restore attempted
          // values for override columns before building the outbound merge payload.
          ..applyAuthoredAttemptedValues(attemptedValueFields)
          // spaceId is local ownership metadata; it is never emitted on the wire.
          ..remove('spaceId');

    // A table definition names its class the way its own package spells it, so
    // a model owned by a shared package reports the unprefixed name while the
    // host protocol answers only to the package-prefixed one. Carrying the name
    // in the payload lets the host fall through to the protocol that owns the
    // model rather than failing on a name it does not know.
    // `Object` rather than `dynamic`: a dynamic target is read as a wrapped
    // dynamic field instead of a model payload.
    final row = session.db.serializationManager.deserialize<Object>({
      ...columnMap,
      '__className__': dartName,
    });
    return (exists: true, ownerSpaceId: spaceId, row: row);
  }

  /// Resolves a column value for outbound update sync.
  ///
  /// When [attempted] is present, returns its authored value instead of the
  /// materialized domain column value. Columns without an attempted row are
  /// read directly from the domain table. Both the table and column are
  /// runtime schema values, so this cannot use a statically typed repository.
  Future<({bool exists, int? ownerSpaceId, dynamic value})> _fetchOwnedColumnValue(
    DatabaseSession session,
    String tableName,
    UuidValue rowId,
    String columnName,
    CrdtDataAttemptedValue? attempted,
    int spaceId,
    DomainRowOwnerCache ownerCache,
  ) async {
    if (attempted != null) {
      final owner = await _readDomainRowOwner(session, tableName, rowId, ownerCache);
      if (!owner.exists || owner.spaceId != spaceId) {
        return (exists: owner.exists, ownerSpaceId: owner.spaceId, value: null);
      }
      return (
        exists: true,
        ownerSpaceId: spaceId,
        value: attempted.value,
      );
    }

    final encodedRowId = rowId.sqlLiteral();
    final encodedSpaceId = spaceId.sqlLiteral();
    final escapedTableName = tableName.escapeIdentifier();
    final column = _syncTablesByName[tableName]!.columns.singleWhere(
      (c) => c.columnName == columnName,
    );
    final result = await session.db.unsafeQuery(
      'SELECT ${_outboundColumnExpression(session, column)} '
      'FROM "$escapedTableName" '
      'WHERE "id" = $encodedRowId AND "spaceId" = $encodedSpaceId '
      'LIMIT 1',
    );
    if (result.isNotEmpty) {
      ownerCache[(tableName, rowId)] = (exists: true, spaceId: spaceId);
      return (
        exists: true,
        ownerSpaceId: spaceId,
        value: _decodeColumnValue(
          tableName,
          columnName,
          _decodeStructuredValue(session, column, result.first[0]),
        ),
      );
    }

    final owner = await _readDomainRowOwner(session, tableName, rowId, ownerCache);
    return (exists: owner.exists, ownerSpaceId: owner.spaceId, value: null);
  }

  Future<DomainRowOwner> _readDomainRowOwner(
    DatabaseSession session,
    String tableName,
    UuidValue rowId,
    DomainRowOwnerCache ownerCache,
  ) async {
    final cached = ownerCache[(tableName, rowId)];
    if (cached != null) return cached;

    final encodedRowId = rowId.sqlLiteral();
    final escapedTableName = tableName.escapeIdentifier();
    final result = await session.db.unsafeQuery(
      'SELECT "spaceId" FROM "$escapedTableName" '
      'WHERE "id" = $encodedRowId '
      'LIMIT 1',
    );
    final owner = result.isEmpty
        ? (exists: false, spaceId: null)
        : (exists: true, spaceId: result.first[0] as int?);
    ownerCache[(tableName, rowId)] = owner;
    return owner;
  }

  Never _throwPendingIntegrityViolation({
    required int? crdtDataRowId,
    required OfflineSyncViolationType type,
    required OfflineSyncViolationOperation operation,
    required String tableName,
    required UuidValue rowId,
    required int? ownerSpaceId,
    required UuidValue incomingSpaceUuid,
    required UuidValue uuidNodeId,
    Hlc? hlc,
  }) {
    throw PendingOutboundIntegrityViolation(
      crdtDataRowId: crdtDataRowId,
      type: type,
      operation: operation,
      tableName: tableName,
      rowId: rowId,
      ownerSpaceId: ownerSpaceId,
      incomingSpaceUuid: incomingSpaceUuid,
      uuidNodeId: uuidNodeId,
      hlc: hlc,
    );
  }

  Future<Never> _recordAndThrowIntegrityViolation(
    DatabaseSession session,
    PendingOutboundIntegrityViolation pending,
  ) async {
    final ownerSpaceUuid = await _spaceUuidForNormalizedId(
      session,
      pending.ownerSpaceId,
    );
    final now = clock.now().toUtc();
    final violation = OfflineSyncIntegrityViolation(
      type: pending.type,
      domainTableName: pending.tableName,
      uuidRowId: pending.rowId,
      ownerSpaceUuid: ownerSpaceUuid,
      incomingSpaceUuid: pending.incomingSpaceUuid,
      operation: pending.operation,
      uuidNodeId: pending.uuidNodeId,
      crdtDataRowId: pending.crdtDataRowId,
      hlcDatetime: pending.hlc?.datetime,
      hlcCounter: pending.hlc?.counter,
      firstSeenAt: now,
      lastSeenAt: now,
      occurrences: 1,
    );
    final persisted = await recordOfflineSyncIntegrityViolation(
      session,
      violation: violation,
    );
    throw OfflineSyncIntegrityViolationException(persisted);
  }

  Future<UuidValue?> _spaceUuidForNormalizedId(
    DatabaseSession session,
    int? spaceId,
  ) async {
    if (spaceId == null) return null;

    final space = await OfflineSyncSpace.db.findById(session, spaceId);
    return space?.uuidSpaceId;
  }

  /// Loads attempted-value metadata for outbound insert sync.
  ///
  /// Returns fields that currently have a [CrdtDataAttemptedValue] row, keyed
  /// by CRDT row id. These are the columns whose domain-table value differs
  /// from the durable authored fact.
  Future<Map<int, List<CrdtDataField>>> _loadAttemptedValueFields(
    DatabaseSession session,
    List<CrdtDataRow> rows,
  ) async {
    final rowIds = {for (final row in rows) ?row.id};
    if (rowIds.isEmpty) return {};

    final fields = await CrdtDataField.db.find(
      session,
      where: (t) => t.rowId.inSet(rowIds) & t.attemptedValue.id.notEquals(null),
      include: CrdtDataField.include(
        column: CrdtSchemaColumn.include(),
        attemptedValue: CrdtDataAttemptedValue.include(),
      ),
    );

    final fieldsByRowId = <int, List<CrdtDataField>>{};
    for (final field in fields) {
      fieldsByRowId.putIfAbsent(field.rowId, () => []).add(field);
    }

    return fieldsByRowId;
  }

  String _outboundColumnExpression(DatabaseSession session, Column column) {
    final identifier = '"${column.columnName.escapeIdentifier()}"';
    if (session.db.dialect == DatabaseDialect.sqlite && column is ColumnStructured) {
      return 'json($identifier)';
    }
    return identifier;
  }

  /// Temporary workaround for raw queries bypassing Serverpod's column-aware
  /// result normalization. [_outboundColumnExpression] converts SQLite JSONB to
  /// JSON text so this method can decode both JSON and JSONB before deserialization.
  ///
  /// TODO: Serverpod needs a public API for adapter-specific, column-aware decoding
  /// of raw query results across supported types and databases. Replace this helper
  /// and [_outboundColumnExpression] with that upstream API when it is available.
  dynamic _decodeStructuredValue(
    DatabaseSession session,
    Column column,
    Object? value,
  ) {
    if (session.db.dialect == DatabaseDialect.sqlite &&
        (column is ColumnStructured || column is ColumnSerializable) &&
        value is String) {
      return jsonDecode(value);
    }
    return value;
  }

  dynamic _decodeColumnValue(
    String tableName,
    String columnName,
    Object? value,
  ) {
    if (value == null) return null;

    final column = _syncTablesByName[tableName]!.columns.singleWhere(
      (column) => column.columnName == columnName,
    );
    return _serializationManager.deserialize<dynamic>(value, column.type);
  }

  static String _computeCanonicalSyncTablesSignature(
    List<Table> syncTables, {
    required List<TableDefinition> tableDefinitions,
  }) {
    final tableDefinitionsByName = {
      for (final definition in tableDefinitions) definition.name: definition,
    };

    final sortedTables = syncTables.toList()
      ..sort((left, right) => left.tableName.compareTo(right.tableName));

    return sortedTables
        .map((table) {
          final definition = tableDefinitionsByName[table.tableName];
          final columns = [
            if (definition != null)
              for (final column in definition.columns)
                if (column.name != 'spaceId')
                  _canonicalColumnIdentity(definition, column)
                else
                  for (final column in table.columns)
                    if (column.columnName != 'spaceId') column.columnName,
          ]..sort();
          final foreignKeys = _canonicalForeignKeys(definition);
          final uniqueIndexes = _canonicalUniqueIndexes(definition);
          return '${table.tableName}:'
              '${columns.join(',')}|'
              'fk[${foreignKeys.join(';')}]|'
              'uq[${uniqueIndexes.join(';')}]';
        })
        .join(';');
  }

  static String _canonicalColumnIdentity(
    TableDefinition table,
    ColumnDefinition column,
  ) {
    final releaseKind = crdtUniqueConflictReleaseKindForColumn(table, column);
    return '${column.name}:${column.columnType.name}:${column.dartType}:'
        '${column.isNullable}:${releaseKind?.name ?? '-'}';
  }

  static List<String> _canonicalForeignKeys(TableDefinition? definition) {
    if (definition == null) return const [];
    final entries = <String>[
      for (final fk in definition.foreignKeys)
        // Each foreign key must map all parameters.
        // ignore: no_adjacent_strings_in_list
        '${(fk.columns.toList()..sort()).join(',')}->'
            '${fk.referenceTableSchema}.${fk.referenceTable}'
            '(${(fk.referenceColumns.toList()..sort()).join(',')})'
            '|u:${fk.onUpdate?.toString() ?? '-'}'
            '|d:${fk.onDelete?.toString() ?? '-'}'
            '|m:${fk.matchType?.toString() ?? '-'}',
    ]..sort();

    return entries;
  }

  static List<String> _canonicalUniqueIndexes(TableDefinition? definition) {
    if (definition == null) return const [];

    final entries = <String>[
      for (final index in definition.indexes)
        if (index.isUnique && !index.isPrimary)
          () {
            final sortedElements = [
              for (final element in index.elements)
                '${element.type}:${element.definition}',
            ]..sort();
            return sortedElements.join(',');
          }(),
    ]..sort();

    return entries;
  }
}

/// What one outbound batch left for later rounds (fork, unibook#14251).
final class _OutboundBatch {
  /// Whether the batch stopped before every pending change was sent.
  bool hasMore = false;
}

/// What a session sent of the released rows (fork, unibook#14251).
final class _ReleasedRowsSent {
  /// The changes of released rows sent so far, by kind, source row id and
  /// HLC: each goes once per session, whether it was pending or read only as
  /// released. A change written again since has a new HLC and goes again.
  final Set<(OutboundChangeKind, int, Hlc)> entries = {};

  /// The released rows with at least one change sent, confirmed when the
  /// session ends with the peer's close.
  final Set<OfflineSyncRowKey> rows = {};
}

/// A pending change the planned collection may send (fork, unibook#14251).
final class _PlannedChange {
  _PlannedChange._(
    this.ref,
    this.sourceId, {
    required this.forced,
    this.row,
    this.field,
    this.tombstone,
  });

  factory _PlannedChange.insert(CrdtDataRow row, {required bool forced}) =>
      _PlannedChange._(
        (
          hlc: row.hlc,
          kind: OutboundChangeKind.insert,
          tableName: row.tbl!.name,
          rowId: row.uuidRowId,
          columnName: null,
          deleteReason: null,
        ),
        row.id!,
        forced: forced,
        row: row,
      );

  factory _PlannedChange.update(CrdtDataField field, {required bool forced}) =>
      _PlannedChange._(
        (
          hlc: field.hlc,
          kind: OutboundChangeKind.update,
          tableName: field.row!.tbl!.name,
          rowId: field.row!.uuidRowId,
          columnName: field.column!.name,
          deleteReason: null,
        ),
        field.id!,
        forced: forced,
        field: field,
      );

  factory _PlannedChange.delete(
    CrdtDataDeleted tombstone, {
    required bool forced,
  }) => _PlannedChange._(
    (
      hlc: tombstone.hlc,
      kind: OutboundChangeKind.delete,
      tableName: tombstone.row!.tbl!.name,
      rowId: tombstone.row!.uuidRowId,
      columnName: null,
      deleteReason: tombstone.reason,
    ),
    tombstone.id!,
    forced: forced,
    tombstone: tombstone,
  );

  /// What the planner orders and cuts by.
  final OutboundChangeRef ref;

  /// The id of the CRDT metadata row the change comes from.
  final int sourceId;

  /// Whether it was read only because its row is released: the checkpoints
  /// are past it.
  final bool forced;

  final CrdtDataRow? row;
  final CrdtDataField? field;
  final CrdtDataDeleted? tombstone;

  OfflineSyncRowKey get rowKey => (tableName: ref.tableName, rowId: ref.rowId);

  (OutboundChangeKind, int, Hlc) get sentKey => (ref.kind, sourceId, ref.hlc);
}

Expression _afterAnySpaceCheckpointFilter(
  ColumnInt spaceId,
  ColumnUuid uuidNodeId,
  ColumnDateTime hlcDatetime,
  ColumnInt hlcCounter,
  Map<int, List<Hlc>> checkpointsBySpaceId,
) {
  final caseExpression = Case();
  var hasCheckpoint = false;
  for (final MapEntry(key: normalizedSpaceId, value: checkpoints)
      in checkpointsBySpaceId.entries) {
    for (final checkpoint in checkpoints) {
      hasCheckpoint = true;
      caseExpression.when(
        spaceId.equals(normalizedSpaceId) & uuidNodeId.equals(checkpoint.nodeId),
        then:
            (hlcDatetime > checkpoint.datetime) |
            (hlcDatetime.equals(checkpoint.datetime) &
                (hlcCounter > checkpoint.counter)),
      );
    }
  }
  return hasCheckpoint
      ? caseExpression.orElse(Constant.bool(true))
      : Constant.bool(true);
}

extension on Map<String, dynamic> {
  /// Replaces materialized column values with authored values for sync.
  ///
  /// After local projection, the domain table stores the safe visible value
  /// while [CrdtDataAttemptedValue.value] preserves what was actually tried.
  /// Outbound sync must send the attempted value so peers can apply their own
  /// projection from the same fact.
  void applyAuthoredAttemptedValues(List<CrdtDataField>? attemptedValueFields) {
    if (attemptedValueFields == null) return;
    for (final field in attemptedValueFields) {
      final attempted = field.attemptedValue;
      if (attempted == null) continue;
      this[field.column!.name] = attempted.value;
    }
  }
}
