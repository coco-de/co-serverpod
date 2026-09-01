import 'dart:async';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:test/test.dart';

const _schema = {
  'bookmark': ['title', 'page'],
};

/// 서버 1 + 클라이언트 N 의 결정적 테스트 하네스.
class Harness {
  Harness() {
    serverStore = InMemoryServerSyncStore();
    server = CoSyncServer(
      store: serverStore,
      clock: HlcClock(nodeId: 'server', wallClock: () => wall),
      syncSchema: _schema,
    );
    transport = InProcessTransport(server);
  }

  /// 모든 노드가 공유하는 가짜 벽시계 (테스트가 직접 전진시킨다).
  int wall = 1000;

  late final InMemoryServerSyncStore serverStore;
  late final CoSyncServer server;
  late final InProcessTransport transport;

  final Map<String, InMemoryClientSyncStore> stores = {};

  /// [nodeId] 의 클라이언트를 만든다.
  CoSyncClient client(
    String nodeId, {
    TombstonePolicy policy = TombstonePolicy.deleteWins,
    SyncTransport? transportOverride,
  }) {
    final store = stores.putIfAbsent(nodeId, InMemoryClientSyncStore.new);
    return CoSyncClient(
      store: store,
      transport: transportOverride ?? transport,
      clock: HlcClock(nodeId: nodeId, wallClock: () => wall),
      syncSchema: _schema,
      tombstonePolicy: policy,
    );
  }
}

void main() {
  group('기본 왕복', () {
    test('A 의 오프라인 쓰기가 sync 두 번으로 B 에 도달한다', () async {
      final h = Harness();
      final a = h.client('A');
      final b = h.client('B');

      await a.upsert('bookmark', 'r1', {'title': '1장', 'page': 10});
      h.wall = 2000;
      final pushReport = await a.sync();
      expect(pushReport.pushedRows, 1);

      final pullReport = await b.sync();
      expect(pullReport.pulledChanges, 1);
      final view = await b.read('bookmark', 'r1');
      expect(view!.isDeleted, isFalse);
      expect(view.values, {'title': '1장', 'page': 10});
    });

    test('자기 push 의 echo 는 재적용되지 않는다 (변경 통지 0)', () async {
      final h = Harness();
      final a = h.client('A');
      await a.upsert('bookmark', 'r1', {'title': '1장'});
      await a.sync();

      final events = <TableChange>[];
      final sub = a.changes.listen(events.add);
      final report = await a.sync(); // pull 에 자기 행이 내려오지만 no-op
      await sub.cancel();
      expect(report.pulledChanges, 0);
      expect(events, isEmpty);
    });
  });

  group('삭제 (D-1 하드 게이트)', () {
    test('오프라인 삭제가 동기화로 전파되고 되살아나지 않는다', () async {
      final h = Harness();
      final a = h.client('A');
      final b = h.client('B');

      await a.upsert('bookmark', 'r1', {'title': '1장'});
      await a.sync();
      await b.sync();
      expect((await b.read('bookmark', 'r1'))!.isDeleted, isFalse);

      h.wall = 3000;
      await a.delete('bookmark', 'r1'); // 오프라인 삭제
      await a.sync();
      await b.sync();
      expect((await b.read('bookmark', 'r1'))!.isDeleted, isTrue);

      // 어느 쪽도 추가 편집하지 않았다 — 몇 번을 더 동기화해도 삭제 유지.
      await a.sync();
      await b.sync();
      expect((await a.read('bookmark', 'r1'))!.isDeleted, isTrue);
      expect((await b.read('bookmark', 'r1'))!.isDeleted, isTrue);
    });

    test('동시 편집 vs 삭제 — 정책별 뷰가 갈리고 저장 상태는 같다', () async {
      final h = Harness();
      final a = h.client('A');
      final bDeleteWins = h.client('B');
      final bEditWins = h.client('B2', policy: TombstonePolicy.editWins);

      await a.upsert('bookmark', 'r1', {'title': '1장'});
      await a.sync();
      await bDeleteWins.sync();
      await bEditWins.sync();

      // A 가 t=3000 에 삭제, B 들이 t=4000 에 (오프라인) 편집.
      h.wall = 3000;
      await a.delete('bookmark', 'r1');
      h.wall = 4000;
      await bDeleteWins.upsert('bookmark', 'r1', {'title': '수정'});
      await bEditWins.upsert('bookmark', 'r1', {'title': '수정'});

      await a.sync();
      await bDeleteWins.sync();
      await bEditWins.sync();
      await a.sync(); // A 도 B 의 편집을 수신

      final deleteWinsView = await bDeleteWins.read('bookmark', 'r1');
      final editWinsView = await bEditWins.read('bookmark', 'r1');
      expect(deleteWinsView!.isDeleted, isTrue);
      expect(editWinsView!.isDeleted, isFalse);
      // 두 정책 모두 편집된 값 자체는 보존한다.
      expect(deleteWinsView.values['title'], '수정');
      expect(editWinsView.values['title'], '수정');
    });

    test('명시적 restore 가 삭제를 이긴다', () async {
      final h = Harness();
      final a = h.client('A');
      await a.upsert('bookmark', 'r1', {'title': '1장'});
      h.wall = 2000;
      await a.delete('bookmark', 'r1');
      h.wall = 3000;
      await a.restore('bookmark', 'r1');
      await a.sync();

      final b = h.client('B');
      await b.sync();
      expect((await b.read('bookmark', 'r1'))!.isDeleted, isFalse);
    });
  });

  group('멱등·재시도', () {
    test('같은 push 를 두 번 보내도 두 번째는 applied 0', () async {
      final h = Harness();
      final a = h.client('A');
      await a.upsert('bookmark', 'r1', {'title': '1장'});
      final state = (await h.stores['A']!.getRow('bookmark', 'r1'))!;
      final request = SyncPushRequest(
        nodeId: 'A',
        schemaSignature: computeSchemaSignature(_schema),
        changes: [RowChange(table: 'bookmark', state: state)],
      );
      final first = await h.transport.push(request);
      final second = await h.transport.push(request);
      expect(first.appliedCount, 1);
      expect(second.appliedCount, 0);
    });

    test('pull 을 반복해도 상태·커서가 안정적이다', () async {
      final h = Harness();
      final a = h.client('A');
      await a.upsert('bookmark', 'r1', {'title': '1장'});
      await a.sync();

      final b = h.client('B');
      await b.sync();
      final firstCursor = await h.stores['B']!.loadCursor();
      final report = await b.sync();
      expect(report.pulledChanges, 0);
      expect(await h.stores['B']!.loadCursor(), firstCursor);
    });
  });

  group('커서 페이지네이션', () {
    test('limit 보다 많은 변경도 전부 도달한다', () async {
      final h = Harness();
      final a = h.client('A');
      for (var i = 0; i < 7; i++) {
        h.wall = 1000 + i;
        await a.upsert('bookmark', 'r$i', {'title': '항목 $i', 'page': i});
      }
      await a.sync();

      final b = h.client('B');
      final report = await b.sync(pullLimit: 2); // 4페이지
      expect(report.pulledChanges, 7);
      for (var i = 0; i < 7; i++) {
        expect((await b.read('bookmark', 'r$i'))!.values['page'], i);
      }
    });
  });

  group('스키마 서명', () {
    test('서명이 다르면 동기화가 거부된다', () async {
      final h = Harness();
      final store = InMemoryClientSyncStore();
      final stale = CoSyncClient(
        store: store,
        transport: h.transport,
        clock: HlcClock(nodeId: 'C', wallClock: () => h.wall),
        // page 컬럼을 모르는 구버전 스키마
        syncSchema: const {
          'bookmark': ['title'],
        },
      );
      await stale.upsert('bookmark', 'r1', {'title': 'x'});
      expect(stale.sync, throwsA(isA<SchemaMismatchException>()));
    });
  });

  group('전송 중 로컬 편집 (pending 안전성)', () {
    test('push 비행 중의 편집은 pending 으로 남아 다음 push 에 실린다', () async {
      final h = Harness();
      late final CoSyncClient a;
      var interfered = false;
      final interfering = _HookedTransport(
        h.transport,
        beforePushResponse: () async {
          if (!interfered) {
            interfered = true;
            h.wall = 5000;
            await a.upsert('bookmark', 'r1', {'title': '비행 중 수정'});
          }
        },
      );
      a = h.client('A', transportOverride: interfering);

      await a.upsert('bookmark', 'r1', {'title': '원본'});
      await a.sync(); // push 응답 직전에 로컬 편집이 끼어든다

      // 편집이 pending 으로 남아 있어야 한다.
      final pending = await h.stores['A']!.pendingRows();
      expect(pending, hasLength(1));

      await a.sync(); // 두 번째 push 가 새 값을 올린다
      expect(await h.stores['A']!.pendingRows(), isEmpty);
      final b = h.client('B');
      await b.sync();
      expect((await b.read('bookmark', 'r1'))!.values['title'], '비행 중 수정');
    });
  });

  group('변경 통지 (R2 반응형 계약)', () {
    test('로컬 쓰기는 local, pull 병합은 remote 로 통지된다', () async {
      final h = Harness();
      final a = h.client('A');
      final b = h.client('B');

      final aEvents = <TableChange>[];
      final bEvents = <TableChange>[];
      final aSub = a.changes.listen(aEvents.add);
      final bSub = b.changes.listen(bEvents.add);

      await a.upsert('bookmark', 'r1', {'title': '1장'});
      await a.sync();
      await b.sync();
      await aSub.cancel();
      await bSub.cancel();

      expect(aEvents, hasLength(1));
      expect(aEvents.single.origin, ChangeOrigin.local);
      expect(aEvents.single.table, 'bookmark');
      expect(bEvents, hasLength(1));
      expect(bEvents.single.origin, ChangeOrigin.remote);
      expect(bEvents.single.rowId, 'r1');
    });
  });

  group('리뷰 발견 회귀 (2026-09-01 적대적 리뷰)', () {
    test('[발견1] pullLimit < 1 은 클라이언트에서 ArgumentError', () {
      final h = Harness();
      final a = h.client('A');
      expect(() => a.sync(pullLimit: 0), throwsArgumentError);
      expect(() => a.sync(pullLimit: -1), throwsArgumentError);
    });

    test('[발견1] 서버는 limit < 1 pull 을 SyncProtocolException 으로 거부', () {
      final h = Harness();
      final request = SyncPullRequest(
        nodeId: 'X',
        schemaSignature: computeSchemaSignature(_schema),
        cursor: null,
        limit: 0,
      );
      expect(
        () => h.server.handlePull(request),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test('[발견1] 진행 없는 pull 응답은 무한 루프 대신 실패한다', () async {
      final h = Harness();
      final stuck = _StuckTransport();
      final a = CoSyncClient(
        store: InMemoryClientSyncStore(),
        transport: stuck,
        clock: HlcClock(nodeId: 'A', wallClock: () => h.wall),
        syncSchema: _schema,
      );
      await expectLater(a.sync(), throwsA(isA<SyncProtocolException>()));
      expect(stuck.pullCount, lessThan(3));
    });

    test('[발견2] 재시작(새 시계) 후의 로컬 편집이 빠른 원격 시계에 지지 않는다', () async {
      final h = Harness();
      // B 의 벽시계가 30분 빠르다 — 드리프트 허용(1h) 이내라 정상 수용된다.
      final fast = CoSyncClient(
        store: InMemoryClientSyncStore(),
        transport: h.transport,
        clock: HlcClock(nodeId: 'B', wallClock: () => h.wall + 30 * 60 * 1000),
        syncSchema: _schema,
      );
      await fast.upsert('bookmark', 'r1', {'title': 'fast-value'});
      await fast.sync();

      final before = h.client('A');
      await before.sync(); // fast 값 수신

      // '앱 재시작' — 같은 스토어, 새 HlcClock (h.client 가 스토어를 재사용)
      final restarted = h.client('A');
      await restarted.upsert('bookmark', 'r1', {'title': 'my-edit'});
      expect(
        (await restarted.read('bookmark', 'r1'))!.values['title'],
        'my-edit',
        reason: '시드 없이는 새 시계가 과거 스탬프를 찍어 LWW 에서 패배한다',
      );
    });

    test('[발견3] 구분자 주입 — 다른 스키마가 같은 서명을 얻지 않는다', () {
      expect(
        computeSchemaSignature({
          'a:b': ['c'],
        }),
        isNot(
          computeSchemaSignature({
            'a': ['b:c'],
          }),
        ),
      );
      expect(
        computeSchemaSignature({
          't': ['a,b'],
        }),
        isNot(
          computeSchemaSignature({
            't': ['a', 'b'],
          }),
        ),
      );
    });

    test('[발견4] 서버가 예약 필드·미지 테이블·미지 컬럼 push 를 거부한다', () async {
      final h = Harness();
      final sig = computeSchemaSignature(_schema);
      SyncPushRequest evil(String table, String field) => SyncPushRequest(
        nodeId: 'X',
        schemaSignature: sig,
        changes: [
          RowChange(
            table: table,
            state: RowState(
              rowId: 'r1',
              fields: const {
                'dummy': FieldValue('x', Hlc(100, 0, 'X')),
              }.map((_, v) => MapEntry(field, v)),
            ),
          ),
        ],
      );
      expect(
        () => h.server.handlePush(evil('bookmark', r'$evil')),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        () => h.server.handlePush(evil('not_in_schema', 'title')),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        () => h.server.handlePush(evil('bookmark', 'zzz')),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test(r'[발견4] valuesView 는 $ 접두 필드를 전부 숨긴다', () {
      final state = RowState(
        rowId: 'r1',
        fields: const {
          kDeletedField: FieldValue(false, Hlc(1, 0, 'A')),
          r'$evil': FieldValue('x', Hlc(1, 0, 'A')),
          'title': FieldValue('t', Hlc(1, 0, 'A')),
        },
      );
      expect(state.valuesView().keys.toList(), ['title']);
    });

    test(r'[발견4] 클라이언트 upsert 는 $ 접두·미지 컬럼을 릴리스에서도 거부', () {
      final h = Harness();
      final a = h.client('A');
      expect(
        () => a.upsert('bookmark', 'r1', {r'$deleted': true}),
        throwsArgumentError,
      );
      expect(() => a.upsert('bookmark', 'r1', {'zzz': 1}), throwsArgumentError);
      expect(
        () => a.upsert('not_in_schema', 'r1', {'title': 'x'}),
        throwsArgumentError,
      );
    });

    test('[발견8] 동시 sync 호출은 직렬화된다', () async {
      final h = Harness();
      final a = h.client('A');
      await a.upsert('bookmark', 'r1', {'title': 'x'});
      final results = await Future.wait([a.sync(), a.sync()]);
      expect(results[0].pushedRows + results[1].pushedRows, 1);

      final b = h.client('B');
      await b.sync();
      expect((await b.read('bookmark', 'r1'))!.values['title'], 'x');
    });
  });
}

/// 커서를 전진시키지 않으면서 hasMore 를 유지하는 악성/버그 서버 흉내.
class _StuckTransport implements SyncTransport {
  int pullCount = 0;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async =>
      SyncPushResponse(
        appliedCount: request.changes.length,
        serverHlcPacked: const Hlc(1, 0, 'server').pack(),
      );

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    pullCount++;
    return SyncPullResponse(
      changes: const [],
      nextCursor: request.cursor ?? '0',
      hasMore: true,
    );
  }
}

/// push 응답을 돌려주기 직전에 훅을 실행하는 테스트용 전송 래퍼.
class _HookedTransport implements SyncTransport {
  _HookedTransport(this._inner, {required this.beforePushResponse});

  final SyncTransport _inner;
  final Future<void> Function() beforePushResponse;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    final response = await _inner.push(request);
    await beforePushResponse();
    return response;
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      _inner.pull(request);
}
