import 'dart:async';

import 'package:co_sync/co_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// 세대 토큰 — 계정 전환 wipe 뒤 도착한 이전 계정 페이지를 쓰기 직전에 끊는다.
///
/// ⭐ 이 파일의 핵심은 **"왕복 후 검사 통과 → applyPage 직전 reset"** 구간이다.
/// 소비 앱이 `fetch` 를 감싸 세대를 대조해도 그 검사와 `applyPage` 사이에는
/// 창이 남고, 그 창은 이 클래스 안에서만 닫힌다. 그래서 단언 대상은 내부
/// 상태가 아니라 **저장소에 행이 앉았는가** 다.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late CoSyncDatabase db;
  late ReplicaStore store;

  setUp(() {
    db = CoSyncDatabase(NativeDatabase.memory());
    store = ReplicaStore(db);
  });

  tearDown(() => db.close());

  ReplicaRowChange row(String id) =>
      ReplicaRowChange(rowId: id, dataJson: '{}', serverUpdatedAtMillis: 1000);

  ReplicaPage page(String id, {bool hasMore = false, String cursor = 'c1'}) =>
      ReplicaPage(rows: [row(id)], nextCursor: cursor, hasMore: hasMore);

  Future<int> rowCount(String domain) async =>
      (await store.getDomain(domain)).length;

  test('⭐ 왕복 후 reset 이 나면 applyPage 에 도달하지 않는다', () async {
    // fetch 가 응답을 **돌려준 뒤** 세대가 전진하는 상황을 정확히 만든다.
    late final ReplicaPuller puller;
    final gate = Completer<void>();
    puller = ReplicaPuller(
      store: store,
      domains: {
        'orders': (_) async {
          // 서버 왕복을 흉내 낸다 — 이 await 동안 호출측이 reset 을 건다.
          await gate.future;
          return page('1');
        },
      },
    );

    final pulling = puller.pullAll();
    await Future<void>.delayed(Duration.zero);
    await puller.reset(); // 계정 전환 wipe 직전
    gate.complete(); // 그 뒤에야 서버 응답이 도착한다
    await pulling;

    expect(
      await rowCount('orders'),
      0,
      reason: '이전 계정의 행이 새 계정 DB 에 앉으면 남의 주문·찜이 화면에 뜬다',
    );
    expect(
      puller.lastErrors['orders'],
      isA<ReplicaPullAborted>(),
      reason: '중단은 조용히 삼키지 않고 드러낸다 — 시드 게이트가 이 값을 본다',
    );
  });

  test('reset 이 없으면 그대로 반영된다 (대조군)', () async {
    final puller = ReplicaPuller(
      store: store,
      domains: {'orders': (_) async => page('1')},
    );

    await puller.pullAll();

    expect(await rowCount('orders'), 1);
    expect(puller.lastErrors, isEmpty);
  });

  test('reset 뒤 **새로** 시작한 pull 은 정상 동작한다', () async {
    final puller = ReplicaPuller(
      store: store,
      domains: {'orders': (_) async => page('1')},
    );

    await puller.reset();
    await puller.pullAll();

    expect(
      await rowCount('orders'),
      1,
      reason: '세대 전진이 이후 모든 pull 을 막으면 로그아웃 후 재로그인이 영영 시드되지 않는다',
    );
    expect(puller.lastErrors, isEmpty);
  });

  test('세대는 reset 마다 1씩 오른다', () async {
    final puller = ReplicaPuller(
      store: store,
      domains: {'orders': (_) async => page('1')},
    );

    expect(puller.generation, 0);
    await puller.reset();
    expect(puller.generation, 1);
    await puller.reset();
    expect(puller.generation, 2);
  });

  test('커서 조회와 첫 요청 사이의 reset 도 잡는다 — 요청 0건', () async {
    var fetches = 0;
    late final ReplicaPuller puller;
    // `loadCursor` 가 await 라 그 사이에도 창이 있다. 저장소를 감싸 그 지점에
    // reset 을 끼워 넣는다.
    final delayedStore = _DelayingStore(
      store,
      onLoadCursor: () async {
        await puller.reset();
      },
    );
    puller = ReplicaPuller(
      store: delayedStore,
      domains: {
        'orders': (_) async {
          fetches++;
          return page('1');
        },
      },
    );

    await puller.pullAll();

    expect(fetches, 0, reason: '이미 지나간 세대의 pull 은 서버를 치지도 않는다');
    expect(puller.lastErrors['orders'], isA<ReplicaPullAborted>());
  });

  test('중단은 도메인 단위다 — 다른 도메인의 성공을 무효화하지 않는다', () async {
    late final ReplicaPuller puller;
    final gate = Completer<void>();
    puller = ReplicaPuller(
      store: store,
      domains: {
        'orders': (_) async {
          await gate.future;
          return page('1');
        },
        'likes': (_) async => page('9'),
      },
    );

    final pulling = puller.pullAll();
    await Future<void>.delayed(Duration.zero);
    await puller.reset();
    gate.complete();
    await pulling;

    expect(await rowCount('orders'), 0, reason: '왕복 중이던 도메인은 끊긴다');
    expect(puller.lastErrors.keys, [
      'orders',
    ], reason: 'likes 는 reset 전에 끝났다 — 그 성공까지 무효로 만들면 안 된다');
  });
}

/// [ReplicaStore] 를 감싸 `loadCursor` 직후에 훅을 끼우는 테스트 대역.
///
/// `noSuchMethod` 위임을 쓰지 않는다 — 그러면 오타 하나가 조용히 통과해
/// 대역이 실물과 다른 것을 테스트가 못 본다. 전 멤버를 명시적으로 위임한다.
class _DelayingStore implements ReplicaStore {
  _DelayingStore(this._inner, {required this.onLoadCursor});

  final ReplicaStore _inner;
  final Future<void> Function() onLoadCursor;

  @override
  Future<String?> loadCursor(String domain) async {
    final cursor = await _inner.loadCursor(domain);
    await onLoadCursor();
    return cursor;
  }

  @override
  Future<void> applyPage({
    required String domain,
    required List<ReplicaRowChange> rows,
    required String nextCursor,
  }) => _inner.applyPage(domain: domain, rows: rows, nextCursor: nextCursor);

  @override
  Stream<List<CoReplicaRowData>> watchDomain(String domain) =>
      _inner.watchDomain(domain);

  @override
  Future<List<CoReplicaRowData>> getDomain(String domain) =>
      _inner.getDomain(domain);

  @override
  Stream<CoReplicaRowData?> watchRow(String domain, String rowId) =>
      _inner.watchRow(domain, rowId);

  @override
  Future<CoReplicaRowData?> getRow(String domain, String rowId) =>
      _inner.getRow(domain, rowId);

  @override
  Stream<int> watchDomainCount(String domain) =>
      _inner.watchDomainCount(domain);

  @override
  Stream<List<ReplicaJoinedRow>> watchDomainJoin({
    required String left,
    required String right,
  }) => _inner.watchDomainJoin(left: left, right: right);

  @override
  Future<void> clearDomain(String domain) => _inner.clearDomain(domain);
}
