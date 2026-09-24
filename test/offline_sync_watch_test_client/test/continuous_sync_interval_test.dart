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
///
/// A continuous session can ask for a longer wait (unibook#14207). The request
/// goes from the client helper through the device engine's connect frame to
/// the server engine, so both replicas wait it. The replicas are wrapped with
/// different intervals (server 300 ms, device 200 ms) so a replica that missed
/// the request shows up as a timer of its own interval.
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

  group('Given a continuous session that asks for its own interval,', () {
    const serverInterval = Duration(milliseconds: 300);
    const requested = Duration(milliseconds: 1500);

    /// Starts a session through [start] inside a zone that records every
    /// timer, waits until [requested] was scheduled twice (once per replica,
    /// each after its first idle round) and returns the timers scheduled by
    /// then. Only the waits before the session is cancelled count: cancelling
    /// schedules short timeouts of its own.
    Future<List<Duration>> timersOf(
      OfflineSyncSubscription Function(
        OfflineSyncClient peer,
        OfflineSyncDatabaseSession device,
      )
      start,
    ) async {
      final userId = const Uuid().v7obj();
      final server = await openReplica(
        'server-${const Uuid().v7()}',
        userId,
        continuousSyncInterval: serverInterval,
      );
      final device = await openReplica('device-${const Uuid().v7()}', userId);
      final recorded = <Duration>[];
      late OfflineSyncSubscription live;

      runZoned(
        () => live = start(peerOf(server), device),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            recorded.add(duration);
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
      addTearDown(() => live.cancel());

      await eventually(
        () async => recorded.where((wait) => wait == requested).length >= 2,
        timeout: const Duration(seconds: 10),
      );
      return List.of(recorded);
    }

    test(
      'should_wait_the_requested_interval_on_both_replicas_when_the_client_helper_asks',
      () async {
        final timers = await timersOf(
          (peer, device) =>
              peer.syncContinuously(device, continuousSyncInterval: requested),
        );

        expect(timers, isNot(contains(serverInterval)));
        expect(
          timers,
          isNot(contains(OfflineSyncEngine.defaultContinuousSyncInterval)),
        );
      },
    );

    test(
      'should_wait_the_requested_interval_on_both_replicas_when_the_status_tracker_asks',
      () async {
        final timers = await timersOf((peer, device) {
          final tracker = OfflineSyncStatusTracker(
            peer,
            device,
            watchUnsentRows: false,
          );
          addTearDown(tracker.dispose);
          return tracker.syncContinuously(continuousSyncInterval: requested);
        });

        expect(timers, isNot(contains(serverInterval)));
        expect(
          timers,
          isNot(contains(OfflineSyncEngine.defaultContinuousSyncInterval)),
        );
      },
    );
  });
}
