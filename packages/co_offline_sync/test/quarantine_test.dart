import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:test/test.dart';

const _schema = {
  'note': ['title', 'body'],
};

/// 서버가 돌려주는 영구 거부를 흉내 내는 앱 계층 예외 (코어는 모르는 타입).
class _RemoteRejection implements Exception {
  const _RemoteRejection(this.code);

  final String code;

  @override
  String toString() => '_RemoteRejection($code)';
}

/// `payload_too_large` 만 행 귀속 영구 실패로 본다 — `schema_outdated` 는
/// 요청 단위라 분류하지 않는다(그러면 pending 전량이 격리된다).
QuarantineReason? _classify(Object error) {
  if (error is! _RemoteRejection) return null;
  if (error.code != 'payload_too_large') return null;
  return QuarantineReason(code: error.code, message: 'row rejected');
}

/// 요청 안에 상한 초과 행이 하나라도 있으면 **요청 전체**를 거부하는 전송 —
/// 서버 하드 게이트의 실제 동작(ACK 단위가 청크 전체)이다.
class _GatingTransport implements SyncTransport {
  _GatingTransport(this._inner, {required this.maxBodyChars});

  final SyncTransport _inner;
  final int maxBodyChars;
  final List<List<String>> pushedRowIds = [];
  String? rejectCodeOverride;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    pushedRowIds.add([for (final c in request.changes) c.state.rowId]);
    final override = rejectCodeOverride;
    if (override != null) throw _RemoteRejection(override);
    for (final change in request.changes) {
      final body = change.state.fields['body']?.value;
      if (body is String && body.length > maxBodyChars) {
        throw const _RemoteRejection('payload_too_large');
      }
    }
    return _inner.push(request);
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      _inner.pull(request);
}

/// 격리 계약을 **위임하지 않는** 래퍼 — 지원하지 않는 스토어의 재현.
class _PlainStoreWrapper implements ClientSyncStore {
  _PlainStoreWrapper(this._inner);

  final ClientSyncStore _inner;

  @override
  Stream<TableChange> get changes => _inner.changes;

  @override
  Future<RowState?> getRow(String table, String rowId) =>
      _inner.getRow(table, rowId);

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
  late InMemoryClientSyncStore clientStore;
  late _GatingTransport transport;
  var wall = 1000;

  CoSyncClient buildClient({
    ClientSyncStore? store,
    PushFailureClassifier? classifier = _classify,
    int maxChangesPerPush = 400,
    int maxQuarantineProbesPerPush = 24,
    void Function(QuarantinedRow)? onRowQuarantined,
    Map<String, List<String>> schema = _schema,
  }) => CoSyncClient(
    store: store ?? clientStore,
    transport: transport,
    clock: HlcClock(nodeId: 'A', wallClock: () => wall),
    syncSchema: schema,
    maxChangesPerPush: maxChangesPerPush,
    maxQuarantineProbesPerPush: maxQuarantineProbesPerPush,
    classifyPushFailure: classifier,
    onRowQuarantined: onRowQuarantined,
  );

  setUp(() {
    wall = 1000;
    serverStore = InMemoryServerSyncStore();
    server = CoSyncServer(
      store: serverStore,
      clock: HlcClock(nodeId: 'server', wallClock: () => wall),
      syncSchema: _schema,
    );
    clientStore = InMemoryClientSyncStore();
    transport = _GatingTransport(InProcessTransport(server), maxBodyChars: 20);
  });

  Future<void> seed(CoSyncClient client, {required int badIndex}) async {
    for (var i = 0; i < 8; i++) {
      wall += 1;
      await client.upsert('note', 'r$i', {
        'title': 'n$i',
        'body': i == badIndex ? 'x' * 100 : 'ok',
      });
    }
  }

  group('영구 실패 행 격리 (H3·H4)', () {
    test('상한 초과 행 1건이 있어도 나머지 pending 이 같은 회차에 전송된다', () async {
      final client = buildClient();
      final events = <QuarantinedRow>[];
      final observed = buildClient(onRowQuarantined: events.add);
      await seed(client, badIndex: 3);

      final report = await observed.sync();

      expect(report.pushedRows, 7, reason: '불량 1건만 빠지고 나머지는 같은 회차에 나간다');
      expect(report.quarantinedRows, 1);
      expect(events.map((e) => e.rowId), ['r3']);
      expect(events.single.reason.code, 'payload_too_large');
      for (var i = 0; i < 8; i++) {
        final onServer = await serverStore.getRow('note', 'r$i');
        expect(onServer, i == 3 ? isNull : isNotNull, reason: 'r$i 의 서버 반영 여부');
      }
      expect(await clientStore.pendingRows(), isEmpty);
      expect((await clientStore.quarantinedRows()).map((r) => r.rowId), ['r3']);
      // ⚠️ 격리분도 여전히 **서버에 없다** — 미전송 여부를 묻는 자리
      // (로그아웃 wipe 앞 보존 등)는 pendingRows 가 아니라 이쪽을 봐야 한다.
      expect((await clientStore.unsentRows()).map((r) => r.rowId), ['r3']);
    });

    test('⛔ 대조군 — 분류기가 없으면 청크 전체가 실패하고 아무것도 나가지 않는다', () async {
      final client = buildClient(classifier: null);
      await seed(client, badIndex: 3);

      await expectLater(client.sync(), throwsA(isA<_RemoteRejection>()));

      final page = await serverStore.changesSince(0, limit: 100);
      expect(
        page.changes,
        isEmpty,
        reason: '종전 동작 — 한 행이 그 단말의 push 를 통째로 막는다',
      );
      expect((await clientStore.pendingRows()).length, 8);
      expect(await clientStore.quarantinedRows(), isEmpty);
    });

    test('격리된 행은 다음 회차의 pending 에서 빠진다', () async {
      final client = buildClient();
      await seed(client, badIndex: 0);
      await client.sync();
      transport.pushedRowIds.clear();

      wall += 1;
      await client.upsert('note', 'fresh', {'title': 'f', 'body': 'ok'});
      final second = await client.sync();

      expect(second.pushedRows, 1);
      expect(second.quarantinedRows, 0);
      expect(transport.pushedRowIds, [
        ['fresh'],
      ], reason: '격리된 r0 가 다시 실리면 매 회차가 같은 자리에서 멈춘다');
    });

    test('requeue 후 재전송 — 값을 줄이면 서버에 닿는다', () async {
      final client = buildClient();
      await seed(client, badIndex: 2);
      await client.sync();
      expect(await serverStore.getRow('note', 'r2'), isNull);

      // 요소 축소: 로컬 쓰기가 격리를 자동으로 푼다.
      wall += 1;
      await client.upsert('note', 'r2', {'body': 'small'});
      expect(await clientStore.quarantinedRows(), isEmpty);

      final report = await client.sync();
      expect(report.pushedRows, 1);
      expect(await serverStore.getRow('note', 'r2'), isNotNull);
    });

    test('명시적 requeueAllQuarantined 는 서버 게이트 완화 후 회수 경로다', () async {
      final client = buildClient();
      await seed(client, badIndex: 5);
      await client.sync();
      expect(await clientStore.quarantinedRowCount(), 1);

      // 앱/서버 업데이트로 상한이 올라간 상황.
      transport = _GatingTransport(
        InProcessTransport(server),
        maxBodyChars: 1000,
      );
      expect(await clientStore.requeueAllQuarantined(), 1);
      expect(await clientStore.quarantinedRowCount(), 0);

      final report = await buildClient().sync();
      expect(report.pushedRows, 1);
      expect(await serverStore.getRow('note', 'r5'), isNotNull);
    });

    test('요청 단위 영구 실패는 격리하지 않고 던진다 — pending 전량 격리 방지', () async {
      final client = buildClient();
      await seed(client, badIndex: 99);
      transport.rejectCodeOverride = 'schema_outdated';

      await expectLater(client.sync(), throwsA(isA<_RemoteRejection>()));

      expect(await clientStore.quarantinedRows(), isEmpty);
      expect((await clientStore.pendingRows()).length, 8);
    });

    test('격리를 기록하지 못하는 스토어에서는 좁히기를 켜지 않는다', () async {
      final wrapped = _PlainStoreWrapper(clientStore);
      final client = buildClient(store: wrapped);
      await seed(client, badIndex: 1);

      await expectLater(client.sync(), throwsA(isA<_RemoteRejection>()));

      expect(
        transport.pushedRowIds.length,
        1,
        reason: '기록 못 하는 스토어에서 격리한 척하면 그 행이 pending 에 남아 무한 재시도가 된다',
      );
    });

    test('예산이 바닥나면 좁히기를 멈추고 던진다 — 이미 격리한 몫은 보존', () async {
      final client = buildClient(maxQuarantineProbesPerPush: 2);
      // 8행 전부 불량 — 좁히기가 O(n) 이 되는 최악 케이스.
      for (var i = 0; i < 8; i++) {
        wall += 1;
        await client.upsert('note', 'b$i', {'body': 'x' * 100});
      }

      await expectLater(client.sync(), throwsA(isA<_RemoteRejection>()));

      expect(
        transport.pushedRowIds.length,
        lessThanOrEqualTo(3),
        reason: '첫 요청 1회 + 예산 2회를 넘지 않는다',
      );
    });

    test('여러 청크에 걸친 불량 행을 각각 격리하고 나머지는 전부 보낸다', () async {
      final client = buildClient(maxChangesPerPush: 3);
      await seed(client, badIndex: 1);
      wall += 1;
      await client.upsert('note', 'r8', {'title': 'n8', 'body': 'y' * 100});

      final report = await client.sync();

      expect(report.quarantinedRows, 2);
      expect(report.pushedRows, 7);
      expect(
        (await clientStore.quarantinedRows()).map((r) => r.rowId).toSet(),
        {'r1', 'r8'},
      );
    });
  });

  group('H8 — 스키마가 줄어든 배포에서 pending 해제', () {
    test('투영이 최대 스탬프 컬럼을 떨어뜨려도 ack 가 성립한다', () async {
      // 두 버전을 함께 받는 창 서버 — 좁은 클라이언트의 서명도 통과한다.
      transport = _GatingTransport(
        InProcessTransport(
          CoSyncServer.withRegistry(
            store: serverStore,
            clock: HlcClock(nodeId: 'server', wallClock: () => wall),
            registry: SchemaRegistry([
              SchemaVersion(
                version: 1,
                tables: const {
                  'note': ['title'],
                },
              ),
              SchemaVersion(version: 2, tables: _schema),
            ]),
          ),
        ),
        maxBodyChars: 20,
      );
      // 넓은 스키마로 title(작은 스탬프) → body(큰 스탬프) 순서로 쓴다.
      final wide = buildClient();
      wall += 1;
      await wide.upsert('note', 'r1', {'title': 't'});
      wall += 1;
      await wide.upsert('note', 'r1', {'body': 'b'});

      // 창이 좁아진 배포: 이 클라이언트는 body 를 모른다.
      final narrow = buildClient(
        schema: const {
          'note': ['title'],
        },
      );
      final report = await narrow.sync();

      expect(report.pushedRows, 1);
      expect(
        await clientStore.pendingRows(),
        isEmpty,
        reason: '투영된 maxHlc 로 해제하면 저장 maxHlc 가 더 커서 영구 pending 이 된다',
      );
    });

    test('전송 중 로컬 편집은 여전히 pending 으로 남는다 (가드 회귀)', () async {
      final client = buildClient();
      wall += 1;
      await client.upsert('note', 'r1', {'title': 't1'});
      final snapshot = (await clientStore.getRow('note', 'r1'))!.maxHlc;
      wall += 1;
      await client.upsert('note', 'r1', {'title': 't2'});

      await clientStore.clearPending('note', 'r1', snapshot);

      expect((await clientStore.pendingRows()).map((p) => p.rowId), [
        'r1',
      ], reason: '스냅샷 이후의 편집은 다음 push 에 다시 실려야 한다');
    });
  });

  group('H9 — pendingRows 정렬', () {
    test('로컬 쓰기 순서(스냅샷 HLC)로 결정적으로 정렬된다', () async {
      final client = buildClient();
      wall += 1;
      await client.upsert('note', 'element', {'title': 'e'});
      wall += 1;
      await client.upsert('note', 'page', {'title': 'p'});
      wall += 1;
      // element 를 다시 써 스탬프만 최신으로 만든다 — 삽입 순서와 어긋난다.
      await client.upsert('note', 'element', {'title': 'e2'});

      expect((await clientStore.pendingRows()).map((p) => p.rowId), [
        'page',
        'element',
      ], reason: '정렬이 없으면 저장 엔진의 물리 순서가 전송 순서가 된다');
    });
  });
}
