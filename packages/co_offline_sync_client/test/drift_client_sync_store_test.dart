import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_offline_sync_client/co_offline_sync_client.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

const _schema = {
  'bookmark': ['title', 'page'],
};

Hlc _hlc(int millis, [String node = 'A']) => Hlc(millis, 0, node);

RowState _state(String rowId, Map<String, (Object?, Hlc)> fields) => RowState(
  rowId: rowId,
  fields: {
    for (final e in fields.entries) e.key: FieldValue(e.value.$1, e.value.$2),
  },
);

void main() {
  late CoSyncDatabase db;
  late DriftClientSyncStore store;

  setUp(() {
    db = CoSyncDatabase(NativeDatabase.memory());
    store = DriftClientSyncStore(db);
  });

  tearDown(() => store.dispose());

  test(
    'should_isolate_local_metadata_from_sync_keys_and_wipe_with_account',
    () async {
      await store.saveCursor('cursor');
      await store.writeLocalMetadata('pull_cursor', 'canvas-A');
      expect(await store.loadCursor(), 'cursor');
      expect(await store.readLocalMetadata('pull_cursor'), 'canvas-A');
      expect(await store.pendingRows(), isEmpty);
      await store.writeLocalMetadata('pull_cursor', 'canvas-B');
      expect(await store.readLocalMetadata('pull_cursor'), 'canvas-B');
      await store.clearAll();
      expect(await store.readLocalMetadata('pull_cursor'), isNull);
      expect(await store.loadCursor(), isNull);
    },
  );

  test(
    'should_query_local_namespace_when_prefix_contains_sql_wildcards',
    () async {
      await store.writeLocalMetadata('book_1%/page2', 'original');
      await store.writeLocalMetadata('bookX1Y/page2', 'other');
      await store.saveCursor('cursor');
      expect(await store.readLocalMetadataWithPrefix('book_1%/'), {
        'book_1%/page2': 'original',
      });
      expect((await store.readLocalMetadataWithPrefix('')).length, 2);
    },
  );

  group('영속 계약', () {
    test('putRow/getRow 가 RowState(값·HLC 전부)를 보존한다', () async {
      final state = _state('r1', {
        'title': ('1장', _hlc(100)),
        'page': (10, _hlc(200)),
      });
      await store.putRow(
        'bookmark',
        state,
        origin: ChangeOrigin.local,
        pending: true,
      );
      final loaded = await store.getRow('bookmark', 'r1');
      expect(rowStatesEqual(loaded!, state), isTrue);
      expect(await store.getRow('bookmark', '없는행'), isNull);
    });

    test('커서가 저장·갱신된다', () async {
      expect(await store.loadCursor(), isNull);
      await store.saveCursor('7');
      expect(await store.loadCursor(), '7');
      await store.saveCursor('9');
      expect(await store.loadCursor(), '9');
    });

    test('clearAll 이 행·pending·커서를 전부 지운다', () async {
      await store.putRow(
        'bookmark',
        _state('r1', {'title': ('x', _hlc(100))}),
        origin: ChangeOrigin.local,
        pending: true,
      );
      await store.saveCursor('3');
      await store.clearAll();
      expect(await store.getRow('bookmark', 'r1'), isNull);
      expect(await store.pendingRows(), isEmpty);
      expect(await store.loadCursor(), isNull);
    });
  });

  group('pending 부기', () {
    test('로컬 쓰기는 pending + 스냅샷을 남기고, ack 가드로 해제된다', () async {
      final state = _state('r1', {'title': ('x', _hlc(100))});
      await store.putRow(
        'bookmark',
        state,
        origin: ChangeOrigin.local,
        pending: true,
      );
      final pending = await store.pendingRows();
      expect(pending, hasLength(1));
      expect(pending.single.snapshotHlc, state.maxHlc);

      await store.clearPending('bookmark', 'r1', state.maxHlc);
      expect(await store.pendingRows(), isEmpty);
    });

    test('전송 중 편집(더 큰 maxHlc)은 낡은 upTo 로 해제되지 않는다', () async {
      await store.putRow(
        'bookmark',
        _state('r1', {'title': ('원본', _hlc(100))}),
        origin: ChangeOrigin.local,
        pending: true,
      );
      // 전송 중 새 편집 — maxHlc 가 300 으로 전진.
      await store.putRow(
        'bookmark',
        _state('r1', {'title': ('수정', _hlc(300))}),
        origin: ChangeOrigin.local,
        pending: true,
      );
      // 낡은 스냅샷(100)으로 ack — 해제되면 안 된다.
      await store.clearPending('bookmark', 'r1', _hlc(100));
      expect(await store.pendingRows(), hasLength(1));
      // 새 스냅샷(300)으로 ack — 해제된다.
      await store.clearPending('bookmark', 'r1', _hlc(300));
      expect(await store.pendingRows(), isEmpty);
    });

    test('원격 병합(putRow pending:false)은 기존 pending 부기를 보존한다', () async {
      final localState = _state('r1', {'title': ('로컬', _hlc(100))});
      await store.putRow(
        'bookmark',
        localState,
        origin: ChangeOrigin.local,
        pending: true,
      );
      // 원격 병합 결과 저장 — pending 이 유지돼야 한다.
      final merged = mergeRowStates(
        localState,
        _state('r1', {'page': (5, _hlc(50, 'B'))}),
      );
      await store.putRow(
        'bookmark',
        merged,
        origin: ChangeOrigin.remote,
        pending: false,
      );
      final pending = await store.pendingRows();
      expect(pending, hasLength(1));
      expect(pending.single.snapshotHlc, localState.maxHlc);
    });
  });

  group('변경 통지 (R2 접점)', () {
    test('로컬/원격 origin 이 구분돼 통지된다', () async {
      final events = <TableChange>[];
      final sub = store.changes.listen(events.add);
      await store.putRow(
        'bookmark',
        _state('r1', {'title': ('x', _hlc(100))}),
        origin: ChangeOrigin.local,
        pending: true,
      );
      await store.putRow(
        'bookmark',
        _state('r2', {'title': ('y', _hlc(200, 'B'))}),
        origin: ChangeOrigin.remote,
        pending: false,
      );
      await sub.cancel();
      expect(events.map((e) => e.origin), [
        ChangeOrigin.local,
        ChangeOrigin.remote,
      ]);
      expect(events.map((e) => e.rowId), ['r1', 'r2']);
    });
  });

  group('코어 계약 — 인메모리 참조 구현과 동일 거동 (엔진 왕복)', () {
    late InMemoryServerSyncStore serverStore;
    late CoSyncServer server;
    late InProcessTransport transport;
    var wall = 1000;

    CoSyncClient clientWith(ClientSyncStore clientStore, String nodeId) =>
        CoSyncClient(
          store: clientStore,
          transport: transport,
          clock: HlcClock(nodeId: nodeId, wallClock: () => wall),
          syncSchema: _schema,
        );

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

    test('drift 클라 A → 서버 → drift 클라 B 수렴 + D-1 삭제 전파', () async {
      final dbB = CoSyncDatabase(NativeDatabase.memory());
      final storeB = DriftClientSyncStore(dbB);
      addTearDown(storeB.dispose);

      final a = clientWith(store, 'A');
      final b = clientWith(storeB, 'B');

      await a.upsert('bookmark', 'r1', {'title': '1장', 'page': 10});
      await a.sync();
      await b.sync();
      expect((await b.read('bookmark', 'r1'))!.values, {
        'title': '1장',
        'page': 10,
      });

      // D-1: 오프라인 삭제가 전파되고 재동기화에도 부활하지 않는다.
      wall = 3000;
      await a.delete('bookmark', 'r1');
      await a.sync();
      await b.sync();
      await b.sync();
      expect((await b.read('bookmark', 'r1'))!.isDeleted, isTrue);
    });

    test('앱 재시작(같은 DB 새 스토어) 후에도 pending 이 push 된다', () async {
      final a = clientWith(store, 'A');
      await a.upsert('bookmark', 'r1', {'title': '오프라인 작성'});
      // sync 없이 "종료" — pending 은 DB 에 남는다. (InMemory 구현이면 유실)

      final restartedStore = DriftClientSyncStore(db);
      final restarted = clientWith(restartedStore, 'A');
      final report = await restarted.sync();
      expect(report.pushedRows, 1);

      final dbB = CoSyncDatabase(NativeDatabase.memory());
      final storeB = DriftClientSyncStore(dbB);
      addTearDown(storeB.dispose);
      final b = clientWith(storeB, 'B');
      await b.sync();
      expect((await b.read('bookmark', 'r1'))!.values['title'], '오프라인 작성');
    });
  });
}
