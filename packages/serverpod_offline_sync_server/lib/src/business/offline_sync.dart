import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';

import 'offline_sync_spaces.dart';

/// The CRDT sync configured per [Serverpod] instance.
///
/// Keyed by the [Serverpod] instance so each pod owns its own [OfflineSyncEngine] (and
/// the [OfflineSyncDatabaseContext] it carries) instead of sharing a single
/// process-wide singleton.
final _offlineSyncByServerpod = Expando<OfflineSyncEngine>('offlineSync');

/// Intercepts each Serverpod session database with a CRDT-aware database once
/// [OfflineSyncInitialize.initializeOfflineSync] has configured sync.
///
/// When sync has not been configured for the session's [Serverpod], the
/// original [inner] database is returned unchanged.
Database offlineSyncDatabaseInterceptor(Session session, Database inner) {
  final offlineSync = _offlineSyncByServerpod[session.server.serverpod];
  return offlineSync?.wrapDatabase(inner) ?? inner;
}

/// Extension methods for [Serverpod] to configure the CRDT sync on the server.
extension OfflineSyncInitialize on Serverpod {
  /// Configures the CRDT sync with the given sync tables.
  ///
  /// Must be called during server startup before any sync requests are made.
  /// Will override any previous initialization for this [Serverpod] instance.
  ///
  /// The `Serverpod` class that `serverpod generate` writes for a project with
  /// sync tables already calls this with the defaults. To change a setting,
  /// call it again after constructing the pod and pass every setting at once:
  /// each call replaces the engine, so a setting left out goes back to its
  /// default.
  ///
  /// The [Serverpod] instance must be constructed with [offlineSyncDatabaseInterceptor]
  /// as its `databaseInterceptor`. Otherwise each session's [Session.db] stays a
  /// plain database and server-side ORM mutations on synced tables are not
  /// CRDT-tracked.
  ///
  /// [syncBatchSize] controls the maximum number of merge changes carried by
  /// each sync stream chunk.
  ///
  /// [continuousSyncInterval] controls how long a continuous sync session waits
  /// after completing one sync round before checking for local changes again.
  /// It is also the shortest wait a session can ask for: a device or
  /// [OfflineSyncSession.sync] can ask a session to wait longer, never shorter
  /// (unibook#14207). A session that asks for nothing waits exactly this, so
  /// it is the rate every such session runs at.
  ///
  /// [maxContinuousSyncInterval] is the longest wait a session can ask for; a
  /// longer request waits this. While it waits, the server does not read the
  /// device, so a session whose device left ends up to this long later.
  /// Defaults to [OfflineSyncEngine.defaultMaxContinuousSyncInterval], or to
  /// [continuousSyncInterval] when that is longer. A value below
  /// [continuousSyncInterval] throws [ArgumentError].
  ///
  /// [maxClockDrift] is the largest clock drift the server accepts, see
  /// [OfflineSyncDatabaseContext.maxClockDrift]. A device timestamp further
  /// ahead of the server clock is rejected and reaches the device as an
  /// [OfflineSyncRemoteException] with [OfflineSyncFailureCode.clockDrift]. It
  /// also bounds how far one device can pull the server node of its space
  /// ahead of the server clock. Each space has its own node (unibook#14218), so
  /// that reaches only the devices of the same space. Those should use a value
  /// larger than this by at least how far a device clock may lag the server
  /// clock.
  ///
  /// Lowering it while a space's node is ahead of the server wall clock by more
  /// than the new value makes every CRDT write the server issues in that space
  /// fail with [ClockDriftException] ([ClockDriftKind.localAhead]) until the
  /// wall clock catches up; a sync that needs a server timestamp there reaches
  /// the device as [OfflineSyncFailureCode.serverClockDrift]. See
  /// [OfflineSyncDatabaseContext.maxClockDrift].
  void initializeOfflineSync({
    required List<Table> syncTables,
    int syncBatchSize = OfflineSyncEngine.defaultSyncBatchSize,
    Duration continuousSyncInterval = OfflineSyncEngine.defaultContinuousSyncInterval,
    Duration? maxContinuousSyncInterval,
    Duration maxClockDrift = Hlc.defaultMaxDrift,
  }) {
    _offlineSyncByServerpod[this] = OfflineSyncEngine(
      syncTables: syncTables,
      serializationManager: serializationManager,
      syncBatchSize: syncBatchSize,
      continuousSyncInterval: continuousSyncInterval,
      maxContinuousSyncInterval: maxContinuousSyncInterval,
      maxClockDrift: maxClockDrift,
    );
  }
}

/// Session-bound CRDT services configured for a [Serverpod] instance.
///
/// This facade is ephemeral: each `Session.offlineSync` access creates a small wrapper
/// around the shared [OfflineSyncEngine] instance and the current [Session].
class OfflineSyncSession {
  /// Creates CRDT services bound to a session.
  OfflineSyncSession(this._session, this._sync);

  final Session _session;
  final OfflineSyncEngine _sync;

  /// Returns the server-side space management service.
  OfflineSyncSpaces get spaces => OfflineSyncSpaces(_session);

  /// The maximum clock drift configured by
  /// [OfflineSyncInitialize.initializeOfflineSync].
  Duration get maxClockDrift => _sync.maxClockDrift;

  /// Runs a CRDT sync session with this [OfflineSyncSession]'s [Session] bound.
  ///
  /// Sync failures whose type Serverpod would drop on the wire (clock drift,
  /// counter overflow, duplicate node, integrity violation) are replaced with an
  /// [OfflineSyncRemoteException] through [offlineSyncWireErrors], so the device
  /// can tell them from a network failure. The original failure is logged to
  /// this session at [LogLevel.error], because the device, and the error
  /// Serverpod logs when the stream ends, get only the replacement. An app
  /// endpoint should call this method rather than the engine directly to keep
  /// that mapping.
  ///
  /// [continuousSyncInterval] asks this continuous session to wait longer
  /// between rounds, on top of what the device asks for: the slower request
  /// wins, bounded by
  /// [OfflineSyncInitialize.initializeOfflineSync]'s interval and maximum
  /// (unibook#14207). It can slow a session down, never speed it up.
  Stream<OfflineSyncStreamEvent> sync({
    required UuidValue userId,
    required Stream<OfflineSyncStreamEvent> inbound,
    required OfflineSyncPeerMode mode,
    bool once = false,
    OfflineSyncOnMergeSuccess? onMergeSuccess,
    Duration? continuousSyncInterval,
  }) {
    return _sync
        .sync(
          _session,
          userId: userId,
          inbound: inbound,
          once: once,
          mode: mode,
          onMergeSuccess: onMergeSuccess,
          continuousSyncInterval: continuousSyncInterval,
        )
        .transform(offlineSyncWireErrors(onMapped: _logMappedFailure));
  }

  void _logMappedFailure(Object error, StackTrace stackTrace) {
    _session.log(
      'Offline sync failed; the device receives an OfflineSyncRemoteException.',
      level: LogLevel.error,
      exception: error,
      stackTrace: stackTrace,
    );
  }
}

/// Extension to access CRDT services for [Session] from the [Serverpod] instance.
extension OfflineSyncSessionExtension on Session {
  /// Returns the CRDT services configured for this session.
  OfflineSyncSession get offlineSync {
    final sync = _offlineSyncByServerpod[server.serverpod];
    if (sync == null) {
      throw StateError(
        'The OfflineSyncEngine has not been initialized for this Serverpod instance. '
        'Call pod.initializeOfflineSync(...) during server startup to configure '
        'the CRDT sync.',
      );
    }
    return OfflineSyncSession(this, sync);
  }
}
