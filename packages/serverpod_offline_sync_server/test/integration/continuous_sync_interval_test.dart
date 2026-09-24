import 'dart:async';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:test/test.dart';

import 'test_tools/serverpod_test_tools.dart';

/// The server's wait between continuous sync rounds (unibook#14183).
///
/// `initializeOfflineSync(continuousSyncInterval:)` already existed upstream
/// with no test. A continuous session runs against a device that stays idle,
/// inside a zone that records every timer, so the wait the engine schedules
/// after a round shows up as a timer of that duration.
void main() {
  withServerpod('[Offline sync continuous interval]', (sessionBuilder, _) {
    late Session session;

    setUp(() {
      session = sessionBuilder.build();
    });

    /// Runs a continuous session until [expected] is scheduled, then closes the
    /// device side and returns every timer duration scheduled before that.
    Future<List<Duration>> timersUntil(Duration expected) async {
      final device = StreamController<OfflineSyncStreamEvent>();
      final done = Completer<void>();
      final recorded = <Duration>[];
      runZoned(
        () {
          session.offlineSync
              .sync(
                userId: const Uuid().v7obj(),
                inbound: device.stream,
                mode: OfflineSyncPeerMode.authoritative,
              )
              .listen(
                (event) {
                  if (event is! OfflineSyncConnect) return;
                  device
                    ..add(
                      OfflineSyncConnect(
                        localNodeId: const Uuid().v7obj(),
                        syncTablesHash: event.syncTablesHash,
                      ),
                    )
                    ..add(OfflineSyncSpaceSet(spaces: []));
                },
                onError: done.completeError,
                onDone: done.complete,
              );
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            recorded.add(duration);
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!recorded.contains(expected)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('No $expected timer within 10 seconds: $recorded');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final beforeClose = List.of(recorded);
      // Closing the device side ends a continuous session normally; wait for
      // it so no round runs after the test's database rollback.
      await device.close();
      await done.future;
      return beforeClose;
    }

    test(
      'when initializeOfflineSync sets an interval, '
      'then the server waits that long between continuous rounds.',
      () async {
        const interval = Duration(milliseconds: 1234);
        session.serverpod.initializeOfflineSync(
          syncTables: [],
          continuousSyncInterval: interval,
        );

        final timers = await timersUntil(interval);

        expect(timers, contains(interval));
        expect(
          timers,
          isNot(contains(OfflineSyncEngine.defaultContinuousSyncInterval)),
        );
      },
    );

    test(
      'when initializeOfflineSync is called without an interval, '
      'then the server keeps the upstream 200 ms default.',
      () async {
        session.serverpod.initializeOfflineSync(syncTables: []);

        final timers = await timersUntil(
          OfflineSyncEngine.defaultContinuousSyncInterval,
        );

        expect(
          OfflineSyncEngine.defaultContinuousSyncInterval,
          const Duration(milliseconds: 200),
        );
        expect(timers, contains(const Duration(milliseconds: 200)));
      },
    );
  });
}
