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
///
/// A session can ask for a longer wait (unibook#14207): the device in its
/// connect frame, the app endpoint through `session.offlineSync.sync`. The
/// server waits the slower request, never below its configured interval and
/// never above its maximum. Every value differs from the others (and from the
/// 1 s idle timeout) so no case passes because two waits happen to match, and
/// each case also checks the wait it would take if a bound were missing.
void main() {
  withServerpod('[Offline sync continuous interval]', (sessionBuilder, _) {
    late Session session;

    setUp(() {
      session = sessionBuilder.build();
    });

    /// The connect frame the server sent in the last [timersUntil] session.
    OfflineSyncConnect? serverConnect;

    /// Runs a continuous session until [expected] is scheduled, then closes the
    /// device side and returns every timer duration scheduled before that.
    ///
    /// [deviceRequest] goes in the device's connect frame; without it the frame
    /// is the one a device built before the request sends. [serverRequest] is
    /// what the app endpoint asks for through the facade.
    Future<List<Duration>> timersUntil(
      Duration expected, {
      Duration? deviceRequest,
      Duration? serverRequest,
    }) async {
      final device = StreamController<OfflineSyncStreamEvent>();
      final done = Completer<void>();
      final recorded = <Duration>[];
      serverConnect = null;
      runZoned(
        () {
          session.offlineSync
              .sync(
                userId: const Uuid().v7obj(),
                inbound: device.stream,
                mode: OfflineSyncPeerMode.authoritative,
                continuousSyncInterval: serverRequest,
              )
              .listen(
                (event) {
                  if (event is! OfflineSyncConnect) return;
                  serverConnect = event;
                  device
                    ..add(
                      deviceRequest == null
                          ? OfflineSyncConnect(
                              localNodeId: const Uuid().v7obj(),
                              syncTablesHash: event.syncTablesHash,
                            )
                          : OfflineSyncConnect(
                              localNodeId: const Uuid().v7obj(),
                              syncTablesHash: event.syncTablesHash,
                              continuousSyncInterval: deviceRequest,
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

    group('Given a session that asks for its own interval (unibook#14207),', () {
      const ms = Duration(milliseconds: 1);

      test(
        'when the device asks for a longer wait, '
        'then the server waits that instead of its configured interval.',
        () async {
          session.serverpod.initializeOfflineSync(syncTables: []);

          final timers = await timersUntil(ms * 1500, deviceRequest: ms * 1500);

          expect(timers, contains(ms * 1500));
          expect(
            timers,
            isNot(contains(OfflineSyncEngine.defaultContinuousSyncInterval)),
          );
          expect(serverConnect?.continuousSyncInterval, isNull);
        },
      );

      test(
        'when the device asks for a shorter wait than configured, '
        'then the server keeps its configured interval.',
        () async {
          session.serverpod.initializeOfflineSync(
            syncTables: [],
            continuousSyncInterval: ms * 400,
          );

          final timers = await timersUntil(ms * 400, deviceRequest: ms * 50);

          expect(timers, contains(ms * 400));
          expect(timers, isNot(contains(ms * 50)));
        },
      );

      test(
        'when the device and the app endpoint both ask for a shorter wait, '
        'then the server keeps its configured interval.',
        () async {
          session.serverpod.initializeOfflineSync(
            syncTables: [],
            continuousSyncInterval: ms * 400,
          );

          final timers = await timersUntil(
            ms * 400,
            deviceRequest: ms * 50,
            serverRequest: ms * 150,
          );

          expect(timers, contains(ms * 400));
          expect(timers, isNot(contains(ms * 150)));
          expect(timers, isNot(contains(ms * 50)));
        },
      );

      test(
        'when the device asks for more than the configured maximum, '
        'then the server waits the maximum.',
        () async {
          const tenMinutes = Duration(minutes: 10);
          session.serverpod.initializeOfflineSync(
            syncTables: [],
            maxContinuousSyncInterval: ms * 2000,
          );

          final timers = await timersUntil(ms * 2000, deviceRequest: tenMinutes);

          expect(timers, contains(ms * 2000));
          expect(timers, isNot(contains(tenMinutes)));
          expect(
            timers,
            isNot(contains(OfflineSyncEngine.defaultContinuousSyncInterval)),
          );
        },
      );

      test(
        'when the app endpoint asks for a longer wait than the device, '
        'then the server waits the slower one and tells the device.',
        () async {
          session.serverpod.initializeOfflineSync(syncTables: []);

          final timers = await timersUntil(
            ms * 3000,
            deviceRequest: ms * 1500,
            serverRequest: ms * 3000,
          );

          expect(timers, contains(ms * 3000));
          expect(timers, isNot(contains(ms * 1500)));
          expect(
            timers,
            isNot(contains(OfflineSyncEngine.defaultContinuousSyncInterval)),
          );
          expect(serverConnect?.continuousSyncInterval, ms * 3000);
        },
      );

      test(
        'when a once session asks for an interval, '
        'then the server sends no request in its connect frame.',
        () async {
          session.serverpod.initializeOfflineSync(syncTables: []);
          // Never listened to: the session stops at its connect frame, so
          // awaiting the close would wait for a listener forever.
          final device = StreamController<OfflineSyncStreamEvent>();
          addTearDown(() => unawaited(device.close()));

          final first = await session.offlineSync
              .sync(
                userId: const Uuid().v7obj(),
                inbound: device.stream,
                mode: OfflineSyncPeerMode.authoritative,
                once: true,
                continuousSyncInterval: ms * 1500,
              )
              .first;

          expect(first, isA<OfflineSyncConnect>());
          expect((first as OfflineSyncConnect).continuousSyncInterval, isNull);
        },
      );

      test(
        'when initializeOfflineSync sets a maximum below the interval, '
        'then it throws ArgumentError instead of raising the maximum.',
        () {
          expect(
            () => session.serverpod.initializeOfflineSync(
              syncTables: [],
              continuousSyncInterval: ms * 5000,
              maxContinuousSyncInterval: ms * 1000,
            ),
            throwsArgumentError,
          );
        },
      );
    });
  });
}
