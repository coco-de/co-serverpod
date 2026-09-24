import 'package:meta/meta.dart';
import 'package:serverpod_database/serverpod_database.dart';
import 'package:uuid/uuid.dart';

import '../sync/engine.dart';
import 'database.dart';
import 'recorder.dart';

/// Wraps a [DatabaseSession] to provide a [OfflineSyncDatabase] as [DatabaseSession.db].
class OfflineSyncDatabaseSession implements DatabaseSession {
  /// Creates a [OfflineSyncDatabaseSession] instance.
  OfflineSyncDatabaseSession(
    Database db, {

    /// The list of tables to sync with CRDT.
    required List<Table> syncTables,

    /// Shared CRDT database metadata.
    OfflineSyncDatabaseContext? context,

    /// Maximum number of merge changes sent in one sync stream message.
    int syncBatchSize = OfflineSyncEngine.defaultSyncBatchSize,

    /// Delay between continuous sync rounds.
    Duration continuousSyncInterval = OfflineSyncEngine.defaultContinuousSyncInterval,

    /// The longest delay between continuous sync rounds a session can ask for,
    /// see [OfflineSyncEngine.resolveMaxContinuousSyncInterval] (fork,
    /// unibook#14207): a longer request from either peer waits this. Like
    /// `continuousSyncInterval`, it is ignored when `db` is already an
    /// [OfflineSyncDatabase].
    Duration? maxContinuousSyncInterval,

    /// The user ID to use for all CRDT operations. This should only be used for
    /// databases operating on the client side, where all data is for the same user.
    /// Otherwise, the user ID must be passed through the transaction.
    ///
    /// It makes the database a device, whose spaces share one CRDT node. On a
    /// `context` that already gives every space its own node, as a server's
    /// does, it throws [StateError], see
    /// [OfflineSyncDatabaseContext.assignsNodePerSpace].
    UuidValue? persistentUserId,

    /// The maximum clock drift, see [OfflineSyncDatabaseContext.maxClockDrift].
    /// Configures the new context when `context` is null. A value that differs
    /// from the one of `context`, or of an already wrapped `db`, throws
    /// [ArgumentError].
    Duration? maxClockDrift,
  }) : _db = db is OfflineSyncDatabase
           ? _checkWrappedMaxClockDrift(db, maxClockDrift)
           : OfflineSyncDatabase(
               db,
               syncTables: syncTables,
               context: context,
               syncBatchSize: syncBatchSize,
               continuousSyncInterval: continuousSyncInterval,
               maxContinuousSyncInterval: maxContinuousSyncInterval,
               persistentUserId: persistentUserId,
               maxClockDrift: maxClockDrift,
             );

  /// Creates a [OfflineSyncDatabaseSession] instance that wraps a [DatabaseSession].
  factory OfflineSyncDatabaseSession.wraps(
    DatabaseSession session, {

    /// The list of tables to sync with CRDT.
    required List<Table> syncTables,

    /// Shared CRDT database metadata.
    OfflineSyncDatabaseContext? context,

    /// Maximum number of merge changes sent in one sync stream message.
    int syncBatchSize = OfflineSyncEngine.defaultSyncBatchSize,

    /// Delay between continuous sync rounds.
    Duration continuousSyncInterval = OfflineSyncEngine.defaultContinuousSyncInterval,

    /// The longest delay between continuous sync rounds a session can ask for,
    /// see [OfflineSyncDatabaseSession.new] (fork, unibook#14207).
    ///
    /// The generated `createSyncSession` forwards neither this nor
    /// `continuousSyncInterval`. To set them on a client, open the session
    /// with this factory instead.
    Duration? maxContinuousSyncInterval,

    /// The user ID to use for all CRDT operations. This should only be used for
    /// databases operating on the client side, where all data is for the same user.
    /// Otherwise, the user ID must be passed through the transaction.
    ///
    /// It makes the database a device, whose spaces share one CRDT node. On a
    /// `context` that already gives every space its own node, as a server's
    /// does, it throws [StateError], see
    /// [OfflineSyncDatabaseContext.assignsNodePerSpace].
    UuidValue? persistentUserId,

    /// The maximum clock drift, see [OfflineSyncDatabaseContext.maxClockDrift].
    ///
    /// The generated `createSyncSession` does not forward this argument. To
    /// change it on a client, open the session with this factory instead and
    /// call `session.db.initialize()` afterwards.
    Duration? maxClockDrift,
  }) => OfflineSyncDatabaseSession(
    session.db,
    syncTables: syncTables,
    context: context,
    syncBatchSize: syncBatchSize,
    continuousSyncInterval: continuousSyncInterval,
    maxContinuousSyncInterval: maxContinuousSyncInterval,
    persistentUserId: persistentUserId,
    maxClockDrift: maxClockDrift,
  ).._wrappedSession = session;

  static OfflineSyncDatabase _checkWrappedMaxClockDrift(
    OfflineSyncDatabase db,
    Duration? maxClockDrift,
  ) {
    OfflineSyncDatabaseContext.checkMaxClockDrift(db.maxClockDrift, maxClockDrift);
    return db;
  }

  final OfflineSyncDatabase _db;
  DatabaseSession? _wrappedSession;
  Future<void>? _closeFuture;

  /// Closes the underlying client database.
  ///
  /// Supported for sessions created by [OfflineSyncDatabaseSession.wraps] around
  /// a [ClientDatabaseSession], including nested sync-session wrappers and the
  /// sessions returned by the generated client's `createSyncSession` method.
  /// Repeated or concurrent calls share the same close operation.
  ///
  /// Throws [UnsupportedError] for sessions constructed directly from a
  /// [Database] or wrapping a non-client session. Those connections must be
  /// closed through their owner, such as the server.
  Future<void> close() => _closeFuture ??= switch (_wrappedSession) {
    final ClientDatabaseSession session => session.close(),
    final OfflineSyncDatabaseSession session => session.close(),
    _ => Future<void>.error(
      UnsupportedError(
        'Only sync sessions wrapping a ClientDatabaseSession can be closed. '
        'Close the underlying database through its owner.',
      ),
    ),
  };

  @override
  OfflineSyncDatabase get db => _db;

  @override
  LogQueryFunction? get logQuery => null;

  @override
  LogWarningFunction? get logWarning => null;

  @override
  Transaction? transaction;
}

/// Wraps a [Database] to provide a [DatabaseSession] as [DatabaseSession.db].
@internal
class BasicDatabaseSession implements DatabaseSession {
  /// Creates a [BasicDatabaseSession] instance.
  BasicDatabaseSession(this._db);

  final Database _db;

  @override
  Database get db => _db;

  @override
  LogQueryFunction? get logQuery => null;

  @override
  LogWarningFunction? get logWarning => null;

  @override
  Transaction? transaction;
}

@internal
extension DatabaseSessionExtension on Database {
  DatabaseSession get session => BasicDatabaseSession(this);
}

/// Convenience access to a CRDT-aware database from a wrapped session.
extension OfflineSyncDatabaseAccess on DatabaseSession {
  /// Returns the wrapped [OfflineSyncDatabase] for this session.
  OfflineSyncDatabase get offlineSyncDb {
    final database = db;
    if (database is OfflineSyncDatabase) return database;
    throw StateError(
      'This database session is not wrapped with OfflineSyncDatabaseSession. '
      'Use OfflineSyncDatabaseSession.wraps(...) before accessing offlineSyncDb.',
    );
  }
}
