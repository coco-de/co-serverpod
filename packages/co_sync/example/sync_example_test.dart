import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_sync/co_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'json_sync_transport.dart';

void main() {
  test(
    'should_sync_custom_schema_when_two_devices_use_json_transport',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      const schema = {
        'note': ['title', 'body'],
      };
      final server = CoSyncServer(
        store: InMemoryServerSyncStore(),
        clock: HlcClock(nodeId: 'server-demo'),
        syncSchema: schema,
      );
      final transport = JsonSyncTransport(
        pushJson: (payload) async => jsonEncode(
          (await server.handlePush(
            SyncPushRequest.fromJson(
              jsonDecode(payload) as Map<String, Object?>,
            ),
          )).toJson(),
        ),
        pullJson: (payload) async => jsonEncode(
          (await server.handlePull(
            SyncPullRequest.fromJson(
              jsonDecode(payload) as Map<String, Object?>,
            ),
          )).toJson(),
        ),
      );
      CoSyncRuntime device() => CoSyncRuntime(
        database: CoSyncDatabase(NativeDatabase.memory()),
        transport: transport,
        syncSchema: schema,
        schemaVersion: 1,
        maxFieldValueChars: 64 * 1024,
      );
      final phone = device();
      final tablet = device();
      addTearDown(phone.dispose);
      addTearDown(tablet.dispose);

      await phone.upsert('note', 'note-1', {'title': '제목', 'body': '초안'});
      expect(await tablet.read('note', 'note-1'), isNull);
      expect(await phone.syncNow(), isNotNull);
      expect(await tablet.syncNow(), isNotNull);
      expect((await tablet.read('note', 'note-1'))!.values['body'], '초안');

      await phone.upsert('note', 'note-1', {'title': '수정한 제목'});
      await tablet.upsert('note', 'note-1', {'body': '태블릿에서 작성'});
      await phone.syncNow();
      await tablet.syncNow();
      await phone.syncNow();
      expect((await phone.read('note', 'note-1'))!.values, {
        'title': '수정한 제목',
        'body': '태블릿에서 작성',
      });

      await phone.delete('note', 'note-1');
      await phone.syncNow();
      await tablet.syncNow();
      expect(await tablet.store.watchLogicalTable('note').first, isEmpty);
      await phone.restore('note', 'note-1');
      await phone.syncNow();
      await tablet.syncNow();
      expect(await tablet.store.watchLogicalTableCount('note').first, 1);

      await phone.reset();
      await phone.store.clearAll();
      expect(await phone.store.pendingRows(), isEmpty);
      expect(await phone.hasSyncedOnce, isFalse);
      expect(await phone.read('note', 'note-1'), isNull);
    },
  );
}
