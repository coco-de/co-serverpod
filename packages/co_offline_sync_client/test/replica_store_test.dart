import 'package:co_offline_sync_client/co_offline_sync_client.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late CoSyncDatabase db;
  late ReplicaStore store;

  setUp(() {
    db = CoSyncDatabase(NativeDatabase.memory());
    store = ReplicaStore(db);
  });

  tearDown(() => db.close());

  ReplicaRowChange row(
    String id, {
    String data = '{}',
    int at = 1000,
    bool deleted = false,
  }) => ReplicaRowChange(
    rowId: id,
    dataJson: data,
    serverUpdatedAtMillis: at,
    deleted: deleted,
  );

  group('applyPage', () {
    test('행 upsert 와 커서 전진이 함께 반영된다', () async {
      await store.applyPage(
        domain: 'orders',
        rows: [row('1', data: '{"t":"대여"}')],
        nextCursor: 'c1',
      );

      final rows = await store.getDomain('orders');
      expect(rows.single.rowId, '1');
      expect(rows.single.dataJson, '{"t":"대여"}');
      expect(await store.loadCursor('orders'), 'c1');
    });

    test('재적용은 멱등이다 — 같은 페이지를 다시 반영해도 1행', () async {
      final page = [row('1')];
      await store.applyPage(domain: 'orders', rows: page, nextCursor: 'c1');
      await store.applyPage(domain: 'orders', rows: page, nextCursor: 'c1');

      expect(await store.getDomain('orders'), hasLength(1));
    });

    test('갱신은 최신 상태로 덮어쓴다', () async {
      await store.applyPage(
        domain: 'orders',
        rows: [row('1', data: '{"v":1}')],
        nextCursor: 'c1',
      );
      await store.applyPage(
        domain: 'orders',
        rows: [row('1', data: '{"v":2}', at: 2000)],
        nextCursor: 'c2',
      );

      final rows = await store.getDomain('orders');
      expect(rows.single.dataJson, '{"v":2}');
      expect(rows.single.serverUpdatedAtMillis, 2000);
    });

    test('삭제 전파 — deleted 행은 활성 조회·watch 에서 빠진다', () async {
      await store.applyPage(
        domain: 'orders',
        rows: [row('1'), row('2', at: 2000)],
        nextCursor: 'c1',
      );
      await store.applyPage(
        domain: 'orders',
        rows: [row('1', deleted: true, at: 3000)],
        nextCursor: 'c2',
      );

      final rows = await store.getDomain('orders');
      expect(rows.map((r) => r.rowId), ['2']);
      expect(await store.watchRow('orders', '1').first, isNull);
    });

    test('도메인 격리 — 다른 도메인 행이 섞이지 않는다', () async {
      await store.applyPage(domain: 'a', rows: [row('1')], nextCursor: 'ca');
      await store.applyPage(domain: 'b', rows: [row('1')], nextCursor: 'cb');

      expect(await store.getDomain('a'), hasLength(1));
      expect(await store.loadCursor('a'), 'ca');
      expect(await store.loadCursor('b'), 'cb');
    });
  });

  group('watch (S7 반응형 접점)', () {
    test('applyPage 반영이 watchDomain 에 자동 emit 된다', () async {
      final emissions = <List<String>>[];
      final sub = store
          .watchDomain('orders')
          .listen((rows) => emissions.add(rows.map((r) => r.rowId).toList()));
      addTearDown(sub.cancel);

      await pumpEventQueue();
      expect(emissions.last, isEmpty, reason: '구독 즉시 현재 스냅샷 emit');

      await store.applyPage(
        domain: 'orders',
        rows: [row('1')],
        nextCursor: 'c1',
      );
      await pumpEventQueue();
      expect(emissions.last, ['1']);

      // 삭제 반영도 watch 로 흐른다.
      await store.applyPage(
        domain: 'orders',
        rows: [row('1', deleted: true, at: 2000)],
        nextCursor: 'c2',
      );
      await pumpEventQueue();
      expect(emissions.last, isEmpty);
    });

    test('정렬 — serverUpdatedAtMillis 내림차순', () async {
      await store.applyPage(
        domain: 'orders',
        rows: [row('old'), row('new', at: 3000), row('mid', at: 2000)],
        nextCursor: 'c1',
      );

      final rows = await store.getDomain('orders');
      expect(rows.map((r) => r.rowId).toList(), ['new', 'mid', 'old']);
    });
  });

  group('로그아웃 wipe 상속 (배치 결정)', () {
    test('replica 테이블이 DB allTables 에 포함된다 — CacheRegistry.clearAll 대상', () {
      // CacheRegistry 는 등록 DB 의 allTables 전체를 DELETE 한다(#6520).
      // CoSyncDatabase 동거 결정의 핵심 전제 — 계정 스코프 replica 가
      // 로그아웃·계정 전환 wipe 에 자동 포함됨을 구조로 고정한다.
      final names = db.allTables.map((t) => t.actualTableName).toSet();
      expect(names, containsAll(['co_replica_rows', 'co_replica_cursors']));
    });
  });

  group('clearDomain', () {
    test('행·커서가 함께 지워지고 다른 도메인은 보존된다', () async {
      await store.applyPage(domain: 'a', rows: [row('1')], nextCursor: 'ca');
      await store.applyPage(domain: 'b', rows: [row('1')], nextCursor: 'cb');

      await store.clearDomain('a');

      expect(await store.getDomain('a'), isEmpty);
      expect(await store.loadCursor('a'), isNull);
      expect(await store.getDomain('b'), hasLength(1));
    });
  });
}
