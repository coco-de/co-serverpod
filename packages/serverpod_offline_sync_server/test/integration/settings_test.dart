import 'dart:async';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:test/test.dart';

import 'test_tools/serverpod_test_tools.dart';

void main() {
  withServerpod('Complete offline sync settings', (sessionBuilder, _) {
    test('server preset reaches the facade and intercepted session DB', () {
      final session = sessionBuilder.build();
      session.serverpod.initializeOfflineSyncWithSettings(syncTables: []);
      final db =
          offlineSyncDatabaseInterceptor(session, session.db) as OfflineSyncDatabase;
      expect(session.offlineSync.maxClockDrift, const Duration(minutes: 30));
      expect(session.offlineSync.batchBudget.maxChanges, 5000);
      expect(
        session.offlineSync.settings.continuousSyncInterval,
        const Duration(seconds: 1),
      );
      expect(
        () => OfflineSyncSettings.boundedServer.requireMatches(db.syncSettings),
        returnsNormally,
      );
      expect(session.offlineSync.schema.hash, db.syncSchema.hash);
      expect(session.offlineSync.schema.tableNames, isEmpty);
    });

    test(
      'custom settings survive reinitialization and the stream uses the generated hash',
      () async {
        final session = sessionBuilder.build();
        final settings = OfflineSyncSettings.boundedServer.copyWith(
          syncBatchSize: 2,
          continuousSyncInterval: const Duration(seconds: 3),
          maxContinuousSyncInterval: const Duration(seconds: 9),
          maxClockDrift: const Duration(minutes: 6),
          batchBudget: OfflineSyncBatchBudget.json(
            maxChanges: 4,
            maxPayloadChars: 2048,
          ),
        );
        session.serverpod.initializeOfflineSyncWithSettings(
          syncTables: [],
          settings: settings,
        );
        expect(
          () => settings.requireMatches(session.offlineSync.settings),
          returnsNormally,
        );
        final expectedHash = session.offlineSync.schema.hash;
        final connect = await session.offlineSync
            .sync(
              userId: const Uuid().v7obj(),
              inbound: const Stream<OfflineSyncStreamEvent>.empty(),
              mode: OfflineSyncPeerMode.authoritative,
              once: true,
            )
            .first;
        expect(connect, isA<OfflineSyncConnect>());
        expect((connect as OfflineSyncConnect).syncTablesHash, expectedHash);
        session.serverpod.initializeOfflineSyncWithSettings(
          syncTables: [],
          settings: settings.copyWith(maxClockDrift: const Duration(minutes: 7)),
        );
        expect(session.offlineSync.maxClockDrift, const Duration(minutes: 7));
        expect(session.offlineSync.settings.syncBatchSize, 2);
        expect(session.offlineSync.batchBudget.maxPayloadChars, 2048);
      },
    );
  });
}
