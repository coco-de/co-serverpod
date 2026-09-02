import 'dart:async';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:test/test.dart';

const _schema = {
  'note': ['title', 'body'],
};

/// push 호출을 세고, 지정한 회차에서 실패시키는 전송 래퍼.
class _CountingTransport implements SyncTransport {
  _CountingTransport(this._inner);

  final SyncTransport _inner;
  final List<int> pushSizes = [];
  int? failOnCall;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    pushSizes.add(request.changes.length);
    if (failOnCall != null && pushSizes.length == failOnCall) {
      throw StateError('simulated transport failure');
    }
    return _inner.push(request);
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      _inner.pull(request);
}

/// 특정 행의 `getRow` 를 테스트가 풀어 줄 때까지 붙잡는 스토어 — 같은 행의
/// 로컬 쓰기와 pull 병합의 교차를 결정적으로 만든다.
class _GateStore implements ClientSyncStore {
  _GateStore(this._inner);

  final InMemoryClientSyncStore _inner;
  Completer<void>? gate;
  final List<String> getRowOrder = [];

  @override
  Stream<TableChange> get changes => _inner.changes;

  @override
  Future<RowState?> getRow(String table, String rowId) async {
    getRowOrder.add(rowId);
    final g = gate;
    if (g != null) await g.future;
    return _inner.getRow(table, rowId);
  }

  @override
  Future<void> putRow(
    String table,
    RowState state, {
    required ChangeOrigin origin,
    required bool pending,
  }) => _inner.putRow(table, state, origin: origin, pending: pending);

  @override
  Future<List<PendingRow>> pendingRows() => _inner.pendingRows();

  @override
  Future<void> clearPending(String table, String rowId, Hlc upTo) =>
      _inner.clearPending(table, rowId, upTo);

  @override
  Future<String?> loadCursor() => _inner.loadCursor();

  @override
  Future<void> saveCursor(String cursor) => _inner.saveCursor(cursor);

  @override
  Future<Hlc?> maxHlc() => _inner.maxHlc();
}

void main() {
  late InMemoryServerSyncStore serverStore;
  late CoSyncServer server;
  late InProcessTransport transport;
  var wall = 1000;

  setUp(() {
    wall = 1000;
    serverStore = InMemoryServerSyncStore();
    server = CoSyncServer(
      store: serverStore,
      clock: HlcClock(nodeId: 'server', wallClock: () => wall),
      syncSchema: _schema,
    );
    transport = InProcessTransport(server);
  });

  CoSyncClient client(
    String nodeId, {
    ClientSyncStore? store,
    SyncTransport? transportOverride,
    int maxChangesPerPush = 400,
    int maxBytesPerPush = 6 * 1024 * 1024,
  }) => CoSyncClient(
    store: store ?? InMemoryClientSyncStore(),
    transport: transportOverride ?? transport,
    clock: HlcClock(nodeId: nodeId, wallClock: () => wall),
    syncSchema: _schema,
    maxChangesPerPush: maxChangesPerPush,
    maxBytesPerPush: maxBytesPerPush,
  );

  group('청크 push (unibook#12839)', () {
    test('pending 이 상한을 넘으면 여러 요청으로 나눠 보내고 전부 서버에 도달한다', () async {
      final counting = _CountingTransport(transport);
      final a = client('A', transportOverride: counting, maxChangesPerPush: 2);
      for (var i = 0; i < 5; i++) {
        await a.upsert('note', 'r$i', {'title': 't$i'});
      }
      final report = await a.sync();
      expect(report.pushedRows, 5);
      expect(counting.pushSizes, [2, 2, 1]);

      final b = client('B');
      final pulled = await b.sync();
      expect(pulled.pulledChanges, 5);
    });

    test('바이트 상한으로도 나뉜다 — 단일 행이 상한보다 커도 단독으로 나간다', () async {
      final counting = _CountingTransport(transport);
      // 행 하나의 JSON 이 ~200자 → 상한 300 이면 행마다 요청.
      final a = client('A', transportOverride: counting, maxBytesPerPush: 300);
      await a.upsert('note', 'r1', {'body': 'x' * 150});
      await a.upsert('note', 'r2', {'body': 'y' * 150});
      await a.upsert('note', 'r3', {'body': 'z' * 500}); // 단독으로 상한 초과
      final report = await a.sync();
      expect(report.pushedRows, 3);
      expect(counting.pushSizes, [1, 1, 1]);
    });

    test('⭐ 뒤 청크가 실패해도 앞 청크의 pending 은 해제된다 (부분 진행)', () async {
      final counting = _CountingTransport(transport)..failOnCall = 2;
      final store = InMemoryClientSyncStore();
      final a = client(
        'A',
        store: store,
        transportOverride: counting,
        maxChangesPerPush: 2,
      );
      for (var i = 0; i < 4; i++) {
        await a.upsert('note', 'r$i', {'title': 't$i'});
      }
      await expectLater(a.sync(), throwsStateError);
      final stillPending = (await store.pendingRows()).map((p) => p.rowId);
      expect(stillPending, unorderedEquals(['r2', 'r3']));
      expect(
        (await serverStore.changesSince(0, limit: 10)).changes,
        hasLength(2),
      );

      // 다음 sync 가 나머지를 잇는다.
      counting.failOnCall = null;
      final report = await a.sync();
      expect(report.pushedRows, 2);
      expect(await store.pendingRows(), isEmpty);
    });

    test('상한 인자 검증', () {
      expect(() => client('A', maxChangesPerPush: 0), throwsArgumentError);
      expect(() => client('A', maxBytesPerPush: 0), throwsArgumentError);
    });
  });

  group('행 단위 직렬화 (로컬 쓰기 ↔ pull 병합)', () {
    test('⭐ 같은 행의 로컬 쓰기와 pull 병합이 겹쳐도 로컬 쓰기가 유실되지 않는다', () async {
      // 서버에 B 가 body 를 써 둔다.
      final b = client('B');
      await b.upsert('note', 'r1', {'body': '원격'});
      wall = 2000;
      await b.sync();

      // A 는 같은 행에 title 을 쓰는데, 그 getRow 를 게이트로 붙잡는 사이
      // pull 이 같은 행을 병합하려 한다.
      final gate = _GateStore(InMemoryClientSyncStore());
      final a = client('A', store: gate);
      wall = 3000;
      gate.gate = Completer<void>();
      final localWrite = a.upsert('note', 'r1', {'title': '로컬'});
      // upsert 가 getRow 에서 멈출 때까지 양보한다.
      await Future<void>.delayed(Duration.zero);
      expect(gate.getRowOrder, ['r1']);
      final syncing = a.sync(); // pull 이 r1 을 병합하려 한다 — 직렬화되어 대기
      await Future<void>.delayed(Duration.zero);
      // 직렬화가 없으면 pull 의 getRow 도 이미 호출됐을 것이다.
      expect(gate.getRowOrder, ['r1'], reason: 'pull 은 로컬 쓰기 뒤에 줄을 선다');

      gate.gate!.complete();
      gate.gate = null;
      await localWrite;
      await syncing;

      final view = await a.read('note', 'r1');
      expect(view!.values, {
        'title': '로컬',
        'body': '원격',
      }, reason: '두 필드가 모두 살아남는다 — lost update 없음');
      final pending = await gate.pendingRows();
      expect(pending.map((p) => p.rowId), contains('r1'));
    });

    test('다른 행끼리는 서로 막지 않는다', () async {
      final gate = _GateStore(InMemoryClientSyncStore());
      final a = client('A', store: gate);
      final r1Gate = Completer<void>();
      gate.gate = r1Gate;
      final w1 = a.upsert('note', 'r1', {'title': 'a'});
      await Future<void>.delayed(Duration.zero);
      expect(gate.getRowOrder, ['r1']);
      gate.gate = null; // 이후 getRow 는 즉시 통과
      // r1 이 게이트에 막혀 있어도 r2 쓰기는 완료된다.
      await a
          .upsert('note', 'r2', {'title': 'b'})
          .timeout(const Duration(seconds: 1));
      expect((await a.read('note', 'r2'))!.values, {'title': 'b'});
      expect(w1, isA<Future<void>>()); // 아직 대기 중
      r1Gate.complete();
      await w1;
      expect((await a.read('note', 'r1'))!.values, {'title': 'a'});
    });
  });
}
