import 'dart:io';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_offline_sync_client/co_offline_sync_client.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

Hlc _hlc(int millis, [String node = 'A']) => Hlc(millis, 0, node);

RowState _state(String rowId, Map<String, (Object?, Hlc)> fields) => RowState(
  rowId: rowId,
  fields: {
    for (final e in fields.entries) e.key: FieldValue(e.value.$1, e.value.$2),
  },
);

RowState _tombstone(String rowId, int millis) =>
    _state(rowId, {kDeletedField: (true, _hlc(millis))});

/// S7-2 (#12753) — 논리 테이블 단위 소비 API 계약.
///
/// - `deleted` 물질화: putRow 가 저장 시점에 tombstone 판정을 컬럼으로 동기
/// - watch: 구독 즉시 스냅샷 + putRow 재emit + **clearAll(wipe) 자연 발화**
///   — `changes` 스트림의 세 공백(구독 전 유실·무스냅샷·wipe 무통지) 부재
/// - COUNT: JSON 디코드 없이 활성 행만 (S7-3 파생 집계의 원천)
/// - v2→v3 마이그레이션: 기존 tombstone 행 백필
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('논리 테이블 소비 API', () {
    late CoSyncDatabase db;
    late DriftClientSyncStore store;

    setUp(() {
      db = CoSyncDatabase(NativeDatabase.memory());
      store = DriftClientSyncStore(db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> put(RowState state) => store.putRow(
      'bookmark',
      state,
      origin: ChangeOrigin.local,
      pending: false,
    );

    test('watch — 구독 즉시 스냅샷, putRow 재emit, tombstone 제외', () async {
      final emissions = <List<RowState>>[];
      final sub = store
          .watchLogicalTable('bookmark', coalesceWindow: Duration.zero)
          .listen(emissions.add);

      // 구독 즉시 빈 스냅샷 — `changes` 와 달리 초기 상태가 온다.
      await pumpEventQueue();
      expect(emissions, hasLength(1));
      expect(emissions.single, isEmpty);

      await put(_state('r1', {'page': (3, _hlc(1))}));
      await put(_tombstone('r2', 2));
      await pumpEventQueue();

      expect(emissions.last.map((s) => s.rowId), [
        'r1',
      ], reason: 'tombstone(r2)은 활성 목록에서 걸러져야 한다');

      await sub.cancel();
    });

    test('clearAll(로그아웃 wipe)이 빈 목록 emit 으로 자연 전달된다', () async {
      await put(_state('r1', {'page': (3, _hlc(1))}));

      final emissions = <List<RowState>>[];
      final sub = store
          .watchLogicalTable('bookmark', coalesceWindow: Duration.zero)
          .listen(emissions.add);
      await pumpEventQueue();
      expect(emissions.last, hasLength(1));

      await store.clearAll();
      await pumpEventQueue();

      expect(
        emissions.last,
        isEmpty,
        reason: 'changes 스트림은 wipe 를 통지하지 않는다 — drift watch 가 정본',
      );
      await sub.cancel();
    });

    test('삭제 mutation(putRow tombstone 갱신)이 watch·COUNT 에 반영된다', () async {
      await put(_state('r1', {'page': (3, _hlc(1))}));
      await put(_state('r2', {'page': (5, _hlc(2))}));
      expect(await store.countLogicalTable('bookmark'), 2);

      final counts = <int>[];
      final sub = store
          .watchLogicalTableCount('bookmark', coalesceWindow: Duration.zero)
          .listen(counts.add);
      await pumpEventQueue();
      expect(counts.last, 2);

      // r2 삭제 — 같은 rowId 에 tombstone 상태 upsert.
      await put(_tombstone('r2', 3));
      await pumpEventQueue();

      expect(counts.last, 1, reason: '파생 집계(S7-3)가 구독할 값');
      expect(await store.countLogicalTable('bookmark'), 1);
      expect((await store.getLogicalTable('bookmark')).map((s) => s.rowId), [
        'r1',
      ]);
      await sub.cancel();
    });

    test('논리 테이블이 다르면 서로의 watch·COUNT 에 나타나지 않는다', () async {
      await put(_state('r1', {'page': (3, _hlc(1))}));
      await store.putRow(
        'highlight',
        _state('h1', {'color': ('red', _hlc(1))}),
        origin: ChangeOrigin.local,
        pending: false,
      );

      expect(await store.countLogicalTable('bookmark'), 1);
      expect(await store.countLogicalTable('highlight'), 1);
      expect((await store.getLogicalTable('highlight')).single.rowId, 'h1');
    });
  });

  group('버스트 코얼레싱 (coalesceWindow)', () {
    test('50행 연속 putRow 가 소수의 emit 으로 접히고 최종값은 정확하다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final store = DriftClientSyncStore(db);
      addTearDown(db.close);

      final emissions = <List<RowState>>[];
      final sub = store
          .watchLogicalTable(
            'bookmark',
            coalesceWindow: const Duration(milliseconds: 500),
          )
          .listen(emissions.add);
      await pumpEventQueue();
      final baseline = emissions.length;

      for (var i = 0; i < 50; i++) {
        await store.putRow(
          'bookmark',
          _state('r$i', {'page': (i, _hlc(i + 1))}),
          origin: ChangeOrigin.remote,
          pending: false,
        );
      }
      // trailing 창(500ms)이 최신값을 흘려보낼 때까지 실시간 대기.
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(
        emissions.length - baseline,
        lessThan(10),
        reason: '코얼레싱 없이는 50회다 (실측) — 창 안의 버스트는 접혀야 한다',
      );
      expect(
        emissions.last,
        hasLength(50),
        reason: '접히더라도 최종 상태는 유실 없이 도착해야 한다',
      );
      await sub.cancel();
    });
  });

  group('v2 → v3 마이그레이션 — deleted 백필', () {
    test('기존 tombstone 행이 재판정되어 물질화된다', () async {
      final file = File(
        '${Directory.systemTemp.createTempSync('co_sync_mig').path}/mig.db',
      );
      addTearDown(() {
        final dir = file.parent;
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      // v3 스키마로 만들고 행을 심은 뒤, deleted 컬럼을 지우고 버전을 2 로
      // 되돌려 "v2 에서 저장된 DB" 를 재현한다 (SQLite 3.35+ DROP COLUMN).
      var db = CoSyncDatabase(NativeDatabase(file));
      var store = DriftClientSyncStore(db);
      await store.putRow(
        'bookmark',
        _state('alive', {'page': (3, _hlc(1))}),
        origin: ChangeOrigin.local,
        pending: false,
      );
      await store.putRow(
        'bookmark',
        _tombstone('gone', 2),
        origin: ChangeOrigin.local,
        pending: false,
      );
      await db.customStatement('ALTER TABLE co_sync_rows DROP COLUMN deleted');
      await db.customStatement('PRAGMA user_version = 2');
      await db.close();

      // 재오픈 → onUpgrade(2→3) 가 컬럼 추가 + stateJson 재판정 백필.
      db = CoSyncDatabase(NativeDatabase(file));
      store = DriftClientSyncStore(db);

      expect(
        await store.countLogicalTable('bookmark'),
        1,
        reason: '백필 없이 기본값 false 로만 두면 tombstone 이 활성으로 오분류된다',
      );
      expect((await store.getLogicalTable('bookmark')).single.rowId, 'alive');
      await db.close();
    });
  });
}
