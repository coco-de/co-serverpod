import 'dart:async';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:test/test.dart';

import 'test_tools/serverpod_test_tools.dart';

/// The server's outbound batch budget (fork, unibook#14251).
///
/// `initializeOfflineSync(batchBudget:)` bounds what the server sends a device
/// in one batch. The splitting itself runs in the shared engine and is tested
/// between real replicas in
/// `test/offline_sync_watch_test_client/test/batch_budget_test.dart`; this
/// pins that the budget reaches the engine every sync session of the pod uses
/// and the databases the interceptor wraps, and that a server always tells
/// the device whether it has more (`OfflineSyncEndOfBatch.hasMore`), so a new
/// device can tell it from a server built before the flag.
void main() {
  withServerpod('[Offline sync batch budget]', (sessionBuilder, _) {
    /// The database the interceptor gives a new session of the pod.
    OfflineSyncDatabase interceptedDatabase() {
      final session = sessionBuilder.build();
      final database = offlineSyncDatabaseInterceptor(session, session.db);
      expect(database, isA<OfflineSyncDatabase>());
      return database as OfflineSyncDatabase;
    }

    test(
      'when initializeOfflineSync sets a batch budget, '
      'then the sync facade and the intercepted databases use it.',
      () {
        final session = sessionBuilder.build();
        final budget = OfflineSyncBatchBudget(maxChanges: 5);
        session.serverpod.initializeOfflineSync(
          syncTables: [],
          batchBudget: budget,
        );

        expect(session.offlineSync.batchBudget, same(budget));
        expect(interceptedDatabase().batchBudget, same(budget));
        // Row isolation is a device's: the server never holds rows back.
        expect(interceptedDatabase().rowIsolation, isNull);
      },
    );

    test(
      'when initializeOfflineSync is called without a budget, '
      'then it is unlimited, as upstream.',
      () {
        final session = sessionBuilder.build();
        session.serverpod.initializeOfflineSync(syncTables: []);

        expect(session.offlineSync.batchBudget, same(OfflineSyncBatchBudget.unlimited));
        expect(interceptedDatabase().batchBudget.isUnlimited, isTrue);
      },
    );

    test(
      'when a once session ends, '
      'then every end-of-batch frame the server sent says whether it has more.',
      () async {
        final session = sessionBuilder.build();
        session.serverpod.initializeOfflineSync(syncTables: []);
        final device = StreamController<OfflineSyncStreamEvent>();
        final deviceNode = const Uuid().v7obj();
        final serverFrames = <OfflineSyncStreamEvent>[];

        // A device with nothing to send: connect, announce no space, answer
        // each space handshake, send an empty batch per round until the
        // server closes, and close back.
        await for (final event in session.offlineSync.sync(
          userId: const Uuid().v7obj(),
          inbound: device.stream,
          mode: OfflineSyncPeerMode.authoritative,
          once: true,
        )) {
          serverFrames.add(event);
          switch (event) {
            case OfflineSyncConnect(:final syncTablesHash):
              device
                ..add(
                  OfflineSyncConnect(
                    localNodeId: deviceNode,
                    syncTablesHash: syncTablesHash,
                  ),
                )
                ..add(OfflineSyncSpaceSet(spaces: []));
            case OfflineSyncSinceHlc(:final uuidSpaceId):
              device.add(
                OfflineSyncSinceHlc(
                  uuidSpaceId: uuidSpaceId,
                  nodeCheckpoints: [Hlc.now(deviceNode)],
                ),
              );
            case OfflineSyncEndOfBatch():
              device.add(OfflineSyncEndOfBatch(hasMore: false));
            case OfflineSyncClose():
              device.add(OfflineSyncClose());
              unawaited(device.close());
            default:
              break;
          }
        }

        final ends = serverFrames.whereType<OfflineSyncEndOfBatch>().toList();
        expect(ends, isNotEmpty);
        expect(ends.map((frame) => frame.hasMore), everyElement(isFalse));
        expect(serverFrames.last, isA<OfflineSyncClose>());
      },
    );
  });
}
