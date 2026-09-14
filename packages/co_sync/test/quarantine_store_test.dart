import 'dart:io';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_sync/co_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

const _testSchemaVersion = 3;
const _testSchema = {
  'co_sync_probe': ['value', 'note'],
};

Hlc _hlc(int millis, [String node = 'A']) => Hlc(millis, 0, node);

RowState _state(String rowId, Map<String, (Object?, Hlc)> fields) => RowState(
  rowId: rowId,
  fields: {
    for (final e in fields.entries) e.key: FieldValue(e.value.$1, e.value.$2),
  },
);

const _reason = QuarantineReason(
  code: 'payload_too_large',
  message: 'row over limit',
);

/// 지정한 rowId 를 포함한 요청만 영구 거부하는 전송 (서버 하드 게이트 흉내).
class _RejectingTransport implements SyncTransport {
  _RejectingTransport(
    this._inner,
    this.rejectRowIds, {
    this.code = 'payload_too_large',
  });

  final SyncTransport _inner;
  final Set<String> rejectRowIds;
  final String code;
  final List<List<String>> pushedRowIds = [];

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) {
    final ids = [for (final c in request.changes) c.state.rowId];
    pushedRowIds.add(ids);
    if (ids.any(rejectRowIds.contains)) {
      throw CoSyncRemoteException(code: code, message: '게이트 위반');
    }
    return _inner.push(request);
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      _inner.pull(request);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('DriftClientSyncStore — 격리 계약 (B4 #13736)', () {
    late CoSyncDatabase db;
    late DriftClientSyncStore store;

    setUp(() {
      db = CoSyncDatabase(NativeDatabase.memory());
      store = DriftClientSyncStore(db);
    });

    tearDown(() => store.dispose());

    Future<void> put(String rowId, int millis, {bool pending = true}) =>
        store.putRow(
          'co_sync_probe',
          _state(rowId, {'value': (rowId, _hlc(millis))}),
          origin: ChangeOrigin.local,
          pending: pending,
        );

    test('격리된 행은 pendingRows 에서 빠지고 목록·건수에 드러난다', () async {
      await put('a', 100);
      await put('b', 200);
      final at = DateTime.utc(2026, 9, 14, 12);
      await store.quarantineRow('co_sync_probe', 'a', reason: _reason, at: at);

      expect((await store.pendingRows()).map((p) => p.rowId), ['b']);
      expect((await store.unsentRows()).map((p) => p.rowId), [
        'a',
        'b',
      ], reason: '격리분도 서버에 없다 — 미전송 판정은 unsentRows 가 답한다');
      expect(await store.quarantinedRowCount(), 1);
      final quarantined = await store.quarantinedRows();
      expect(quarantined.single.rowId, 'a');
      expect(quarantined.single.reason.code, 'payload_too_large');
      expect(quarantined.single.reason.message, 'row over limit');
      expect(quarantined.single.at, at);
    });

    test('격리는 행 상태와 pending 스냅샷을 보존한다 — 폐기가 아니라 보류다', () async {
      await put('a', 100);
      final snapshotBefore = (await store.pendingRows()).single.snapshotHlc;
      await store.quarantineRow(
        'co_sync_probe',
        'a',
        reason: _reason,
        at: DateTime.utc(2026),
      );

      expect(await store.getRow('co_sync_probe', 'a'), isNotNull);
      expect(await store.requeueQuarantined('co_sync_probe', 'a'), isTrue);
      expect((await store.pendingRows()).single.snapshotHlc, snapshotBefore);
    });

    test('requeue 는 격리 상태가 아니면 false, 일괄 해제는 해제 수를 돌려준다', () async {
      await put('a', 100);
      await put('b', 200);
      expect(await store.requeueQuarantined('co_sync_probe', 'a'), isFalse);
      await store.quarantineRow(
        'co_sync_probe',
        'a',
        reason: _reason,
        at: DateTime.utc(2026),
      );
      await store.quarantineRow(
        'co_sync_probe',
        'b',
        reason: _reason,
        at: DateTime.utc(2026),
      );
      expect(await store.requeueAllQuarantined(), 2);
      expect(await store.requeueAllQuarantined(), 0);
      expect((await store.pendingRows()).length, 2);
    });

    test('로컬 쓰기는 격리를 풀고, 원격 병합은 풀지 않는다', () async {
      await put('a', 100);
      await put('b', 100);
      for (final id in ['a', 'b']) {
        await store.quarantineRow(
          'co_sync_probe',
          id,
          reason: _reason,
          at: DateTime.utc(2026),
        );
      }

      await put('a', 300); // 값을 줄여 다시 쓴 로컬 편집
      await put('b', 300, pending: false); // 원격 병합

      expect((await store.pendingRows()).map((p) => p.rowId), ['a']);
      expect((await store.quarantinedRows()).map((r) => r.rowId), ['b']);
    });

    test('H9 — pendingRows 는 로컬 쓰기 순서(스냅샷 HLC)로 정렬된다', () async {
      // 삽입 순서(= SQLite 물리 순서)와 어긋나게 만든다.
      await put('element', 100);
      await put('page', 200);
      await put('element', 300);

      expect((await store.pendingRows()).map((p) => p.rowId), [
        'page',
        'element',
      ]);
      expect((await store.unsentRows()).map((p) => p.rowId), [
        'page',
        'element',
      ], reason: 'unsentRows 도 같은 정렬 계약을 따른다');
    });

    test('clearPending 은 격리 흔적도 함께 지운다 (ack 된 행은 더 이상 보류가 아니다)', () async {
      await put('a', 100);
      await store.quarantineRow(
        'co_sync_probe',
        'a',
        reason: _reason,
        at: DateTime.utc(2026),
      );
      await store.clearPending('co_sync_probe', 'a', _hlc(100));

      expect(await store.pendingRows(), isEmpty);
      expect(await store.quarantinedRows(), isEmpty);
    });
  });

  group('v3 → v4 마이그레이션 — 격리 컬럼 가산', () {
    test('v3 에 저장된 행·pending 부기가 그대로 보존된다', () async {
      final file = File(
        '${Directory.systemTemp.createTempSync('co_sync_q_mig').path}/mig.db',
      );
      addTearDown(() {
        final dir = file.parent;
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      var db = CoSyncDatabase(NativeDatabase(file));
      var store = DriftClientSyncStore(db);
      await store.putRow(
        'co_sync_probe',
        _state('kept', {'value': ('v', _hlc(100))}),
        origin: ChangeOrigin.local,
        pending: true,
      );
      await store.putRow(
        'co_sync_probe',
        _state('gone', {r'$deleted': (true, _hlc(200))}),
        origin: ChangeOrigin.local,
        pending: false,
      );
      // v4 컬럼을 지우고 버전을 3 으로 되돌려 "v3 에서 저장된 DB" 를 만든다.
      for (final column in const [
        'quarantined',
        'quarantine_code',
        'quarantine_reason',
        'quarantined_at_millis',
      ]) {
        await db.customStatement(
          'ALTER TABLE co_sync_rows DROP COLUMN $column',
        );
      }
      await db.customStatement('PRAGMA user_version = 3');
      await db.close();

      // 재오픈 → onUpgrade(3→4) 가 컬럼 4종을 가산한다.
      db = CoSyncDatabase(NativeDatabase(file));
      store = DriftClientSyncStore(db);

      expect((await store.pendingRows()).map((p) => p.rowId), [
        'kept',
      ], reason: '마이그레이션이 기존 pending 부기를 건드리면 올라가지 않은 로컬 변경이 사라진다');
      expect(
        await store.quarantinedRows(),
        isEmpty,
        reason: '격리된 적 없는 기존 행은 quarantined=false 가 옳다',
      );
      expect(await store.getRow('co_sync_probe', 'kept'), isNotNull);
      expect(
        await store.countLogicalTable('co_sync_probe'),
        1,
        reason: 'v3 의 deleted 물질화도 함께 보존된다',
      );
      await db.close();
    });
  });

  group('CoSyncRuntime — 격리 노출·해제 (B5·B9 입력)', () {
    var wall = 1000;
    late InMemoryServerSyncStore serverStore;
    late CoSyncServer server;

    setUp(() {
      wall = 1000;
      serverStore = InMemoryServerSyncStore();
      server = CoSyncServer(
        store: serverStore,
        clock: HlcClock(nodeId: 'server', wallClock: () => wall),
        syncSchema: _testSchema,
      );
    });

    CoSyncRuntime runtimeWith(CoSyncDatabase db, SyncTransport transport) =>
        CoSyncRuntime(
          database: db,
          syncSchema: _testSchema,
          schemaVersion: _testSchemaVersion,
          transport: transport,
          maxFieldValueChars: 384 * 1024,
          clockFactory: (nodeId) =>
              HlcClock(nodeId: nodeId, wallClock: () => wall),
        );

    test('격리 이벤트·건수를 노출하고 나머지 행은 같은 회차에 전송된다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final transport = _RejectingTransport(InProcessTransport(server), {
        'bad',
      });
      final runtime = runtimeWith(db, transport);
      addTearDown(runtime.dispose);
      final events = <QuarantinedRow>[];
      final sub = runtime.quarantineEvents.listen(events.add);
      addTearDown(sub.cancel);

      for (final id in ['ok1', 'bad', 'ok2']) {
        wall += 1;
        await runtime.upsert('co_sync_probe', id, {'value': id});
      }
      final report = await runtime.syncNow();

      expect(report, isNotNull);
      expect(report!.pushedRows, 2);
      expect(report.quarantinedRows, 1);
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => e.rowId), ['bad']);
      expect(runtime.quarantinedRowCount.value, 1);
      expect(await serverStore.getRow('co_sync_probe', 'ok2'), isNotNull);
      expect(await serverStore.getRow('co_sync_probe', 'bad'), isNull);
    });

    test('requeue 로 해제하면 건수가 줄고 게이트 완화 후 서버에 닿는다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final rejecting = _RejectingTransport(InProcessTransport(server), {
        'bad',
      });
      final runtime = runtimeWith(db, rejecting);
      addTearDown(runtime.dispose);

      wall += 1;
      await runtime.upsert('co_sync_probe', 'bad', {'value': 'x'});
      await runtime.syncNow();
      expect(runtime.quarantinedRowCount.value, 1);

      rejecting.rejectRowIds.clear(); // 서버 게이트 완화
      expect(
        await runtime.requeueQuarantinedRow('co_sync_probe', 'bad'),
        isTrue,
      );
      expect(runtime.quarantinedRowCount.value, 0);

      final report = await runtime.syncNow();
      expect(report!.pushedRows, 1);
      expect(await serverStore.getRow('co_sync_probe', 'bad'), isNotNull);
      expect(await runtime.requeueAllQuarantinedRows(), 0);
    });

    test('⛔ 요청 단위 영구 실패(schema_outdated)는 격리하지 않는다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final transport = _RejectingTransport(InProcessTransport(server), {
        'bad',
      }, code: 'schema_outdated');
      final runtime = runtimeWith(db, transport);
      addTearDown(runtime.dispose);

      for (final id in ['ok1', 'bad']) {
        wall += 1;
        await runtime.upsert('co_sync_probe', id, {'value': id});
      }
      expect(await runtime.syncNow(), isNull);

      expect(runtime.lastError, isA<CoSyncRemoteException>());
      expect(runtime.quarantinedRowCount.value, 0);
      expect(
        (await runtime.store.pendingRows()).length,
        2,
        reason: '요청 단위 실패를 행 귀속으로 보면 pending 전량이 격리된다',
      );
    });

    test('reset 은 격리 건수를 0 으로 되돌린다 (이전 계정 안내 해제)', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final runtime = runtimeWith(
        db,
        _RejectingTransport(InProcessTransport(server), {'bad'}),
      );
      addTearDown(runtime.dispose);
      wall += 1;
      await runtime.upsert('co_sync_probe', 'bad', {'value': 'x'});
      await runtime.syncNow();
      expect(runtime.quarantinedRowCount.value, 1);

      await runtime.reset();
      expect(runtime.quarantinedRowCount.value, 0);
    });
  });

  group('classifyCoSyncRowRejection', () {
    test('행 귀속 영구 코드만 격리 사유로 분류한다', () {
      for (final code in kCoSyncRowAttributableCodes) {
        final reason = classifyCoSyncRowRejection(
          CoSyncRemoteException(code: code, message: 'm'),
        );
        expect(reason?.code, code);
        expect(reason?.message, 'm');
      }
      for (final code in const [
        'schema_outdated',
        'schema_mismatch',
        'schema_server_behind',
        'clock_drift',
      ]) {
        expect(
          classifyCoSyncRowRejection(
            CoSyncRemoteException(code: code, message: 'm'),
          ),
          isNull,
          reason: '$code 는 행에 귀속되지 않는다',
        );
      }
      expect(classifyCoSyncRowRejection(StateError('x')), isNull);
      expect(classifyCoSyncRowRejection(const CoSyncCancelled()), isNull);
    });

    test('isRowAttributable 은 isPermanent 의 진부분집합이다', () {
      const permanent = [
        'schema_outdated',
        'schema_mismatch',
        'protocol',
        'payload_too_large',
      ];
      for (final code in permanent) {
        expect(
          CoSyncRemoteException(code: code, message: '').isPermanent,
          isTrue,
        );
      }
      expect(
        permanent.where(
          (c) => CoSyncRemoteException(code: c, message: '').isRowAttributable,
        ),
        kCoSyncRowAttributableCodes,
      );
    });
  });
}
