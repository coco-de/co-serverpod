import 'dart:async';
import 'dart:io';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

import 'support/sync_harness.dart';

/// The wait between continuous sync rounds reaches the engine of a wrapped
/// database (unibook#14183). The server module test covers
/// `initializeOfflineSync`; this covers `OfflineSyncDatabaseSession.wraps`.
void main() {
  late Directory tempDir;
  final client = Client('http://localhost:1/');

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_interval_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  Future<OfflineSyncDatabaseSession> openReplica(
    String name,
    UuidValue userId, {
    Duration? continuousSyncInterval,
  }) async {
    final path = p.join(tempDir.path, '$name.db');
    final session = continuousSyncInterval == null
        ? OfflineSyncDatabaseSession.wraps(
            await client.createSession(path),
            syncTables: syncTables,
            persistentUserId: userId,
          )
        : OfflineSyncDatabaseSession.wraps(
            await client.createSession(path),
            syncTables: syncTables,
            persistentUserId: userId,
            continuousSyncInterval: continuousSyncInterval,
          );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  test(
    'should_wait_the_interval_each_replica_was_wrapped_with_between_continuous_rounds',
    () async {
      const serverInterval = Duration(milliseconds: 1234);
      final userId = const Uuid().v7obj();
      final server = await openReplica(
        'server',
        userId,
        continuousSyncInterval: serverInterval,
      );
      final device = await openReplica('device', userId);
      final recorded = <Duration>[];
      late OfflineSyncSubscription live;

      // Both generators run in the zone that starts the session, so the zone
      // sees each replica's wait as a timer.
      runZoned(
        () => live = peerOf(server).syncContinuously(device),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            recorded.add(duration);
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
      addTearDown(() => live.cancel());

      await eventually(
        () async =>
            recorded.contains(serverInterval) &&
            recorded.contains(OfflineSyncEngine.defaultContinuousSyncInterval),
      );
    },
  );
}
