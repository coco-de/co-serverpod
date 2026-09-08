import 'dart:async';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_sync/co_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

const _testSchemaVersion = 3;
const _testSchema = {
  'co_sync_probe': ['value', 'note'],
};

/// 호출 횟수를 세는 전송 데코레이터 — 연결성 트리거 검증용.
class _CountingTransport implements SyncTransport {
  _CountingTransport(this._inner);

  final SyncTransport _inner;
  int pushCalls = 0;
  int pullCalls = 0;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) {
    pushCalls++;
    return _inner.push(request);
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) {
    pullCalls++;
    return _inner.pull(request);
  }
}

class _FailingTransport implements SyncTransport {
  @override
  Future<SyncPushResponse> push(SyncPushRequest request) =>
      throw const CoSyncRemoteException(code: 'protocol', message: '테스트 실패');

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      throw const CoSyncRemoteException(code: 'protocol', message: '테스트 실패');
}

/// 서버 스키마 창을 고정값으로 돌려주는 가짜 프로브 (실패 주입 가능).
class _FakeProbe implements SchemaWindowProbe {
  _FakeProbe(this.window);

  SchemaWindowInfo window;
  Object? error;
  int calls = 0;

  @override
  Future<SchemaWindowInfo> fetchSchemaWindow() async {
    calls++;
    final pending = error;
    if (pending != null) throw pending;
    return window;
  }
}

void main() {
  // 2노드 수렴 테스트가 의도적으로 DB 2개를 연다 — 경고 억제.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  var wall = 1000;
  late InMemoryServerSyncStore serverStore;
  late CoSyncServer server;
  late InProcessTransport serverTransport;

  CoSyncRuntime runtimeWith(
    CoSyncDatabase db, {
    SyncTransport? transport,
    void Function(Object, StackTrace)? onSyncError,
    SchemaWindowProbe? schemaProbe,
    void Function(CoSyncSchemaStatus, SchemaWindowInfo?)? onSchemaStatus,
    bool Function()? isAuthenticated,
    bool Function()? isLifecycleSyncEnabled,
    HlcClock Function(String nodeId)? clockFactory,
    Duration periodicSyncInterval = const Duration(seconds: 60),
    int maxFieldValueChars = 384 * 1024,
    Duration writeSyncDebounce = const Duration(seconds: 2),
  }) => CoSyncRuntime(
    database: db,
    syncSchema: _testSchema,
    schemaVersion: _testSchemaVersion,
    transport: transport ?? serverTransport,
    maxFieldValueChars: maxFieldValueChars,
    isAuthenticated: isAuthenticated,
    isLifecycleSyncEnabled: isLifecycleSyncEnabled,
    periodicSyncInterval: periodicSyncInterval,
    writeSyncDebounce: writeSyncDebounce,
    onSyncError: onSyncError,
    schemaProbe: schemaProbe,
    onSchemaStatus: onSchemaStatus,
    clockFactory:
        clockFactory ??
        (nodeId) => HlcClock(nodeId: nodeId, wallClock: () => wall),
  );

  setUp(() {
    wall = 1000;
    serverStore = InMemoryServerSyncStore();
    server = CoSyncServer(
      store: serverStore,
      clock: HlcClock(nodeId: 'server', wallClock: () => wall),
      syncSchema: _testSchema,
    );
    serverTransport = InProcessTransport(server);
  });

  group('nodeId 영속', () {
    test('같은 DB 에서 재조립해도 nodeId 가 유지되고, clearAll 후 재발급된다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final store = DriftClientSyncStore(db);
      addTearDown(store.dispose);

      final first = await store.ensureNodeId();
      final second = await store.ensureNodeId();
      expect(second, first, reason: '설치 단위로 영속돼야 한다');

      final restarted = DriftClientSyncStore(db);
      expect(await restarted.ensureNodeId(), first);

      await store.clearAll();
      final regenerated = await store.ensureNodeId();
      expect(
        regenerated,
        isNot(first),
        reason: '로그아웃 wipe 후에는 새 nodeId — 계정 간 상관 차단',
      );
    });
  });

  test(
    'should_invalidate_local_operation_generation_when_reset_or_disposed',
    () async {
      final runtime = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(runtime.dispose);
      final tokens = [runtime.operationGeneration];
      final snapshots = <List<bool>>[];
      void snapshot() =>
          snapshots.add(tokens.map(runtime.isGenerationCurrent).toList());
      snapshot();
      final reset = runtime.reset();
      tokens.add(runtime.operationGeneration);
      snapshot();
      await reset;
      snapshot();
      final dispose = runtime.dispose();
      tokens.add(runtime.operationGeneration);
      snapshot();
      await dispose;
      expect(tokens.toSet(), hasLength(3));
      expect(snapshots, [
        [true],
        [false, false],
        [false, true],
        [false, false, false],
      ]);
    },
  );

  group('연결성 트리거 (S3-3 AC)', () {
    test('오프라인→온라인 전이마다 sync 가 1회씩 실행된다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      final runtime = runtimeWith(db, transport: counting);
      addTearDown(runtime.dispose);

      await runtime.upsert('co_sync_probe', 'r1', {'value': '오프라인 작성'});

      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);

      online.add(false); // 오프라인 — 트리거 없음
      await Future<void>.delayed(Duration.zero);
      expect(counting.pullCalls, 0);

      online.add(true); // 첫 온라인 — 트리거 1회
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 1);
      expect(counting.pushCalls, 1, reason: 'pending 1건이 push 돼야 한다');

      online.add(true); // 전이 아님 — 추가 트리거 없음
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 1);

      online
        ..add(false)
        ..add(true); // 재전이 — 트리거 1회 추가
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 2);
      await online.close();

      // push 가 실제 서버 상태에 반영됐는지 (트리거가 no-op 이 아니다)
      final page = await serverStore.changesSince(0, limit: 10);
      expect(page.changes, hasLength(1));
      expect(page.changes.single.state.valuesView()['value'], '오프라인 작성');
    });
  });

  group('실패 처리 — 침묵 금지', () {
    test('syncNow 실패는 null + lastError + onSyncError, 성공 시 해제된다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      Object? notified;
      final runtime = runtimeWith(
        db,
        transport: _FailingTransport(),
        onSyncError: (error, _) => notified = error,
      );
      addTearDown(runtime.dispose);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'x'});
      final report = await runtime.syncNow();
      expect(report, isNull);
      expect(runtime.lastError, isA<CoSyncRemoteException>());
      expect(notified, isNotNull);
      // pending 은 보존 — 다음 성공 sync 에 재전송된다.
      expect(await runtime.store.pendingRows(), hasLength(1));
    });

    test('영구 실패 코드 판정 (isPermanent)', () {
      expect(
        const CoSyncRemoteException(
          code: 'schema_mismatch',
          message: '',
        ).isPermanent,
        isTrue,
      );
      expect(
        const CoSyncRemoteException(
          code: 'schema_outdated',
          message: '',
        ).isPermanent,
        isTrue,
      );
      expect(
        const CoSyncRemoteException(
          code: 'schema_server_behind',
          message: '',
        ).isPermanent,
        isFalse,
        reason: '롤링 배포 중간 상태 — 재시도 대상',
      );
      expect(
        const CoSyncRemoteException(
          code: 'clock_drift',
          message: '',
        ).isPermanent,
        isFalse,
      );
    });
  });

  group('스키마 창 사전 대조 (S5 게이트 3 · #12794)', () {
    final clientSignature = computeSchemaSignature(_testSchema);
    SchemaWindowInfo windowOf({
      int current = _testSchemaVersion,
      int min = _testSchemaVersion,
      String? signature,
    }) => (
      currentVersion: current,
      minSupportedVersion: min,
      currentSignature: signature ?? clientSignature,
    );

    test('UI 상태는 중복 대조를 합치고 복구·계정 reset 을 알린다', () async {
      final probe = _FakeProbe(
        windowOf(
          current: _testSchemaVersion + 1,
          min: _testSchemaVersion + 1,
          signature: 'newer',
        ),
      );
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        schemaProbe: probe,
      );
      addTearDown(runtime.dispose);
      final states = <CoSyncSchemaStatus>[];
      void onStatusChanged() => states.add(runtime.schemaStatus.value);
      runtime.schemaStatus.addListener(onStatusChanged);
      addTearDown(() => runtime.schemaStatus.removeListener(onStatusChanged));
      expect(runtime.schemaStatus.value, CoSyncSchemaStatus.unknown);
      await runtime.upsert('co_sync_probe', 'pending-ui', {'value': 'unsent'});

      await runtime.verifySchemaWindow();
      await runtime.verifySchemaWindow();
      expect(states, [CoSyncSchemaStatus.appOutdated]);
      expect(await runtime.store.pendingRows(), hasLength(1));

      probe.window = windowOf();
      await runtime.verifySchemaWindow();
      expect(states.last, CoSyncSchemaStatus.compatible);
      expect(await runtime.store.pendingRows(), hasLength(1));

      probe.window = windowOf(
        current: _testSchemaVersion + 1,
        min: _testSchemaVersion + 1,
        signature: 'newer',
      );
      await runtime.verifySchemaWindow();
      await runtime.reset();
      expect(states, [
        CoSyncSchemaStatus.appOutdated,
        CoSyncSchemaStatus.compatible,
        CoSyncSchemaStatus.appOutdated,
        CoSyncSchemaStatus.unknown,
      ]);
      expect(await runtime.store.pendingRows(), hasLength(1));
    });

    test('classifySchemaWindow — 서명 일치가 정본, 그다음 버전으로 아래/위/충돌', () {
      const v = _testSchemaVersion;
      CoSyncSchemaStatus classify(SchemaWindowInfo w) =>
          CoSyncRuntime.classifySchemaWindow(
            w,
            clientVersion: v,
            clientSignature: clientSignature,
          );
      expect(classify(windowOf()), CoSyncSchemaStatus.compatible);
      // 창 안의 구 버전 — 현행 서명과 다른 것이 정상
      expect(
        classify(windowOf(current: v + 1, min: v, signature: 'newer')),
        CoSyncSchemaStatus.compatible,
      );
      expect(
        classify(windowOf(current: v + 2, min: v + 1, signature: 'newer')),
        CoSyncSchemaStatus.appOutdated,
      );
      expect(
        classify(windowOf(current: v - 1, min: v - 1, signature: 'older')),
        CoSyncSchemaStatus.serverBehind,
      );
      expect(
        classify(windowOf(signature: 'same-version-different-schema')),
        CoSyncSchemaStatus.signatureConflict,
      );
    });

    test('온라인 전이 시 사전 대조 → sync 순서로 실행되고 상태가 통지된다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      final probe = _FakeProbe(windowOf());
      final notified = <CoSyncSchemaStatus>[];
      final runtime = runtimeWith(
        db,
        transport: counting,
        schemaProbe: probe,
        onSchemaStatus: (status, _) => notified.add(status),
      );
      addTearDown(runtime.dispose);

      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);
      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await online.close();

      expect(probe.calls, 1);
      expect(counting.pullCalls, 1);
      expect(runtime.lastSchemaStatus, CoSyncSchemaStatus.compatible);
      expect(notified, [CoSyncSchemaStatus.compatible]);
    });

    test('appOutdated 면 그 회차 sync 를 건너뛰고 pending 을 보존한다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      final probe = _FakeProbe(
        windowOf(
          current: _testSchemaVersion + 2,
          min: _testSchemaVersion + 1,
          signature: 'newer',
        ),
      );
      final runtime = runtimeWith(db, transport: counting, schemaProbe: probe);
      addTearDown(runtime.dispose);
      await runtime.upsert('co_sync_probe', 'r1', {'value': 'x'});

      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);
      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await online.close();

      expect(runtime.lastSchemaStatus, CoSyncSchemaStatus.appOutdated);
      expect(counting.pushCalls, 0, reason: '어차피 schema_outdated 로 거부된다');
      expect(
        await runtime.store.pendingRows(),
        hasLength(1),
        reason: '앱 업데이트 후 회수돼야 한다',
      );
    });

    test('프로브 실패는 unknown 이고 sync 는 그대로 진행된다 (UX 용, 안전장치 아님)', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      final probe = _FakeProbe(windowOf())..error = StateError('offline');
      Object? syncError;
      final runtime = runtimeWith(
        db,
        transport: counting,
        schemaProbe: probe,
        onSyncError: (error, _) => syncError = error,
      );
      addTearDown(runtime.dispose);

      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);
      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await online.close();

      expect(runtime.lastSchemaStatus, CoSyncSchemaStatus.unknown);
      expect(syncError, isA<StateError>(), reason: '침묵하지 않는다');
      expect(counting.pullCalls, 1);
    });

    test('프로브가 없으면 대조를 건너뛰고 unknown 을 유지한다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final runtime = runtimeWith(db);
      addTearDown(runtime.dispose);
      expect(await runtime.verifySchemaWindow(), CoSyncSchemaStatus.unknown);
    });
  });

  group('런타임 왕복 (2노드 수렴)', () {
    test('A 런타임 오프라인 쓰기 → sync → B 런타임이 수신·수렴한다', () async {
      final a = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      final b = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      await a.upsert('co_sync_probe', 'r1', {'value': 'A작성', 'note': null});
      expect(await a.syncNow(), isNotNull);
      expect(await b.syncNow(), isNotNull);
      expect((await b.read('co_sync_probe', 'r1'))!.values['value'], 'A작성');

      // D-1: A 삭제 → B 수렴, 재동기화에도 부활하지 않는다.
      wall = 3000;
      await a.delete('co_sync_probe', 'r1');
      await a.syncNow();
      await b.syncNow();
      expect((await b.read('co_sync_probe', 'r1'))!.isDeleted, isTrue);
      await a.syncNow();
      await b.syncNow();
      expect((await a.read('co_sync_probe', 'r1'))!.isDeleted, isTrue);
    });

    test('restore 는 tombstone 을 되살리고 상대 노드에 전파된다', () async {
      final a = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      final b = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      await a.upsert('co_sync_probe', 'r1', {'value': 'v'});
      await a.delete('co_sync_probe', 'r1');
      wall = 2000;
      await a.restore('co_sync_probe', 'r1');
      expect((await a.read('co_sync_probe', 'r1'))!.isDeleted, isFalse);
      await a.syncNow();
      await b.syncNow();
      final view = await b.read('co_sync_probe', 'r1');
      expect(view!.isDeleted, isFalse);
      expect(view.values['value'], 'v');
    });
  });

  group('인증 게이트 (S3-5 #12839)', () {
    test('미인증이면 온라인 신호·syncNow 모두 서버를 치지 않고, 로그인 트리거가 회수한다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      final probe = _FakeProbe((
        currentVersion: _testSchemaVersion,
        minSupportedVersion: _testSchemaVersion,
        currentSignature: computeSchemaSignature(_testSchema),
      ));
      var authenticated = false;
      final runtime = runtimeWith(
        db,
        transport: counting,
        schemaProbe: probe,
        isAuthenticated: () => authenticated,
      );
      addTearDown(runtime.dispose);
      await runtime.upsert('co_sync_probe', 'r1', {'value': '오프라인 작성'});

      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);
      online.add(true); // 부팅 직후 — 아직 인증 복원 전
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 0, reason: '401 pull 을 만들지 않는다');
      expect(probe.calls, 0, reason: '스키마 창 조회도 인증 엔드포인트다 — 401 금지');
      expect(await runtime.syncNow(), isNull);
      expect(counting.pushCalls, 0);
      expect(runtime.lastError, isNull, reason: '에러가 아니라 게이트다');

      // 로그인 — AuthBloc Authenticated emit 직후 호출된다.
      authenticated = true;
      await runtime.onAuthenticated();
      expect(probe.calls, 1);
      expect(counting.pushCalls, 1);
      expect(counting.pullCalls, 1);

      // 같은 온라인 값이 다시 와도 전이가 아니다 (onAuthenticated 가 전이를 소비했다).
      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 1);

      // 이후 오프라인→온라인 전이는 정상 동작.
      online
        ..add(false)
        ..add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 2);
      await online.close();
    });

    test('미인증 구간의 온라인 신호는 전이를 소비하지 않는다 — 로그인 뒤 같은 값이 다시 오면 전이다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      var authenticated = false;
      final runtime = runtimeWith(
        db,
        transport: counting,
        isAuthenticated: () => authenticated,
      );
      addTearDown(runtime.dispose);
      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);
      online.add(true); // 미인증 — 게이트가 막고 _wasOnline 도 갱신하지 않는다
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 0);

      // onAuthenticated 를 부르지 못한 경로라도, 연결성 스트림의 재발행이
      // 로그인 뒤 첫 온라인 전이로 잡혀 잔여 pending 을 회수한다.
      authenticated = true;
      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 1, reason: '미인증 때 본 true 는 전이 소비가 아니다');
      await online.close();
    });

    test('오프라인에서의 onAuthenticated 는 no-op — 온라인 전이가 처리한다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      final runtime = runtimeWith(db, transport: counting);
      addTearDown(runtime.dispose);
      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);
      online.add(false);
      await Future<void>.delayed(Duration.zero);

      await runtime.onAuthenticated();
      expect(counting.pullCalls, 0);

      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 1);
      await online.close();
    });
  });

  group('쓰기 후 디바운스 push (S3-5 #12839)', () {
    test('연속 쓰기는 디바운스 창 뒤 한 번의 sync 로 합쳐진다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      final runtime = runtimeWith(
        db,
        transport: counting,
        writeSyncDebounce: const Duration(milliseconds: 30),
      );
      addTearDown(runtime.dispose);
      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);
      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(counting.pullCalls, 1, reason: '첫 온라인 트리거');
      final baselinePush = counting.pushCalls; // pending 0 이면 push 요청 없음
      final baselinePull = counting.pullCalls;

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      await runtime.upsert('co_sync_probe', 'r2', {'value': 'b'});
      await runtime.delete('co_sync_probe', 'r1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(counting.pushCalls, baselinePush, reason: '창 안에서는 아직 안 나간다');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(counting.pushCalls, baselinePush + 1, reason: '한 번으로 합쳐진다');
      expect(counting.pullCalls, baselinePull + 1);
      expect(await runtime.store.pendingRows(), isEmpty);
      final page = await serverStore.changesSince(0, limit: 10);
      expect(page.changes, hasLength(2));
      await online.close();
    });

    test('오프라인이면 디바운스 발화가 no-op 이고 pending 은 보존된다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      final runtime = runtimeWith(
        db,
        transport: counting,
        writeSyncDebounce: const Duration(milliseconds: 20),
      );
      addTearDown(runtime.dispose);
      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);
      online.add(false);
      await Future<void>.delayed(Duration.zero);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(counting.pushCalls, 0);
      expect(await runtime.store.pendingRows(), hasLength(1));
      await online.close();
    });
  });

  group('필드 크기 사전검증 (S3-5 #12839)', () {
    test('상한 초과 필드는 CoSyncFieldTooLargeError 이고 pending 에 들어가지 않는다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final runtime = runtimeWith(db, maxFieldValueChars: 10);
      addTearDown(runtime.dispose);

      await expectLater(
        runtime.upsert('co_sync_probe', 'r1', {'value': 'x' * 11}),
        throwsA(
          isA<CoSyncFieldTooLargeError>()
              .having((e) => e.field, 'field', 'value')
              .having((e) => e.length, 'length', 11)
              .having((e) => e.max, 'max', 10),
        ),
      );
      expect(
        await runtime.store.pendingRows(),
        isEmpty,
        reason: '포이즌 행을 만들지 않는다',
      );

      // 경계값과 비문자열은 직렬화 길이로 잰다.
      await runtime.upsert('co_sync_probe', 'r1', {'value': 'x' * 10});
      await expectLater(
        runtime.upsert('co_sync_probe', 'r2', {'note': 12345678901}),
        throwsA(isA<CoSyncFieldTooLargeError>()),
      );
      expect(await runtime.store.pendingRows(), hasLength(1));
    });

    test('상한 인자 검증', () {
      expect(
        () => runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          maxFieldValueChars: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('reset — 로그아웃 wipe 앞 (S3-5 #12839)', () {
    test('진행 중 sync 결과는 버려지고, wipe 뒤 새 nodeId 로 재조립된다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final gate = Completer<void>();
      final gated = _GatedTransport(serverTransport, gate);
      final runtime = runtimeWith(db, transport: gated);
      addTearDown(runtime.dispose);

      final nodeBefore = await runtime.store.ensureNodeId();
      await runtime.upsert('co_sync_probe', 'r1', {'value': '옛 계정'});
      final inFlight = runtime.syncNow(); // push 가 게이트에서 멈춘다
      await Future<void>.delayed(Duration.zero);

      // CacheRegistry.clearAll 순서: reset(훅) → wipe
      final resetDone = runtime.reset(
        inFlightTimeout: const Duration(milliseconds: 50),
      );
      await resetDone; // 상한 초과 — wipe 를 막지 않는다
      await runtime.store.clearAll();

      gate.complete();
      expect(await inFlight, isNull, reason: '세대가 바뀐 결과는 버려진다');
      expect(runtime.lastError, isNull);

      // 새 계정의 첫 조작 — 새 nodeId 로 재조립
      await runtime.upsert('co_sync_probe', 'r2', {'value': '새 계정'});
      expect(await runtime.store.ensureNodeId(), isNot(nodeBefore));
      expect(await runtime.hasSyncedOnce, isFalse);
      expect(await runtime.syncNow(), isNotNull);
      expect(await runtime.hasSyncedOnce, isTrue);
    });

    test('reset 뒤 남아 있던 디바운스 예약은 취소된다', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final counting = _CountingTransport(serverTransport);
      final runtime = runtimeWith(
        db,
        transport: counting,
        writeSyncDebounce: const Duration(milliseconds: 30),
      );
      addTearDown(runtime.dispose);
      final online = StreamController<bool>();
      runtime.bindOnlineStream(online.stream);
      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final baseline = counting.pushCalls;

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      await runtime.reset();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(counting.pushCalls, baseline, reason: '옛 계정의 pending 을 밀지 않는다');
      await online.close();
    });
  });

  group('생명주기·동시성 (#13215)', () {
    test('should_reject_nonpositive_period_when_constructed', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      expect(
        () => runtimeWith(db, periodicSyncInterval: Duration.zero),
        throwsArgumentError,
      );
    });

    test('should_share_one_client_when_first_operations_overlap', () async {
      var clients = 0;
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        clockFactory: (nodeId) {
          clients++;
          return HlcClock(nodeId: nodeId, wallClock: () => wall);
        },
      );
      addTearDown(runtime.dispose);
      await Future.wait([
        runtime.upsert('co_sync_probe', 'r1', {'value': 'first'}),
        runtime.upsert('co_sync_probe', 'r1', {'note': 'second'}),
        runtime.syncNow(),
      ]);
      expect(clients, 1);
      expect((await runtime.read('co_sync_probe', 'r1'))!.values, {
        'value': 'first',
        'note': 'second',
      });
    });

    test('should_join_one_round_trip_when_sync_requests_overlap', () async {
      final gate = Completer<void>();
      final transport = _ControlledTransport(serverTransport)
        ..beforePull = (_) => gate.future;
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        transport: transport,
      );
      addTearDown(runtime.dispose);
      final first = runtime.syncNow();
      final second = runtime.syncNow();
      await _waitUntil(() => transport.pullCalls == 1);
      gate.complete();
      final reports = await Future.wait([first, second]);
      expect(reports.every((report) => report != null), isTrue);
      expect(transport.pullCalls, 1);
      expect(transport.maxActive, 1);
    });

    test('should_flush_new_write_when_debounce_joins_running_push', () async {
      final transport = _ControlledTransport(serverTransport);
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        transport: transport,
        writeSyncDebounce: const Duration(milliseconds: 10),
      );
      addTearDown(runtime.dispose);
      final online = StreamController<bool>(sync: true);
      addTearDown(online.close);
      runtime.bindOnlineStream(online.stream);
      online.add(true);
      await runtime.onAuthenticated();
      final baselinePulls = transport.pullCalls;
      final gate = Completer<void>();
      transport.beforePush = (_) => gate.future;
      await runtime.upsert('co_sync_probe', 'r1', {'value': 'before'});
      final work = runtime.syncNow();
      await _waitUntil(() => transport.pushCalls == 1);
      wall++;
      await runtime.upsert('co_sync_probe', 'r1', {'value': 'after'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(transport.pushCalls, 1, reason: '디바운스는 실행 중 회차에 합류');
      gate.complete();
      final report = await work;
      expect(report!.pushedRows, 2, reason: '합류한 호출자는 후속 회차까지의 합계를 받는다');
      expect(transport.pushCalls, 2);
      expect(transport.pullCalls, baselinePulls + 2);
      expect(await runtime.store.pendingRows(), isEmpty);
      final other = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(other.dispose);
      await other.syncNow();
      expect(
        (await other.read('co_sync_probe', 'r1'))!.values['value'],
        'after',
      );
    });

    test(
      'should_receive_remote_changes_when_resuming_without_reconnect',
      () async {
        final receiver = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
        final writer = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
        addTearDown(receiver.dispose);
        addTearDown(writer.dispose);
        final online = StreamController<bool>(sync: true);
        final foreground = StreamController<bool>(sync: true);
        addTearDown(online.close);
        addTearDown(foreground.close);
        receiver.bindOnlineStream(online.stream);
        online.add(true);
        await receiver.onAuthenticated();
        receiver.bindForegroundStream(
          foreground.stream,
          initiallyForeground: true,
        );
        foreground.add(false);
        await writer.upsert('co_sync_probe', 'r1', {'value': 'other device'});
        await writer.syncNow();
        expect(await receiver.read('co_sync_probe', 'r1'), isNull);
        final received = receiver.store
            .watchLogicalTable('co_sync_probe')
            .firstWhere((rows) => rows.isNotEmpty);
        foreground.add(true);
        await received.timeout(const Duration(seconds: 3));
        expect(
          (await receiver.read('co_sync_probe', 'r1'))!.values['value'],
          'other device',
        );
        foreground.add(false);
        await writer.delete('co_sync_probe', 'r1');
        await writer.syncNow();
        final removed = receiver.store
            .watchLogicalTable('co_sync_probe')
            .firstWhere((rows) => rows.isEmpty);
        foreground.add(true);
        await removed.timeout(const Duration(seconds: 3));
        expect((await receiver.read('co_sync_probe', 'r1'))!.isDeleted, isTrue);
      },
    );

    test(
      'should_poll_remote_changes_only_when_foreground_and_enabled',
      () async {
        var enabled = false;
        final transport = _ControlledTransport(serverTransport);
        final receiver = runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          transport: transport,
          isLifecycleSyncEnabled: () => enabled,
          periodicSyncInterval: const Duration(milliseconds: 15),
        );
        final writer = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
        addTearDown(receiver.dispose);
        addTearDown(writer.dispose);
        final online = StreamController<bool>(sync: true);
        final foreground = StreamController<bool>(sync: true);
        addTearDown(online.close);
        addTearDown(foreground.close);
        receiver.bindOnlineStream(online.stream);
        online.add(true);
        await receiver.onAuthenticated();
        receiver.bindForegroundStream(
          foreground.stream,
          initiallyForeground: true,
        );
        final baseline = transport.pullCalls;
        foreground
          ..add(false)
          ..add(true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(transport.pullCalls, baseline, reason: '전부 OFF: 복귀·주기 서버 호출 없음');
        await writer.upsert('co_sync_probe', 'r1', {'value': 'periodic'});
        await writer.syncNow();
        enabled = true; // 스트림 재연결 없이 다음 tick 에 정책 반영.
        await _waitUntil(() => transport.pullCalls > baseline);
        await receiver.syncNow();
        expect(
          (await receiver.read('co_sync_probe', 'r1'))!.values['value'],
          'periodic',
        );
        enabled = false;
        await receiver.syncNow();
        final disabledBaseline = transport.pullCalls;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(transport.pullCalls, disabledBaseline);
        enabled = true;
        foreground.add(false);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(transport.pullCalls, disabledBaseline, reason: '배경은 주기 취소');
      },
    );

    test(
      'should_preserve_existing_triggers_when_lifecycle_flag_is_off',
      () async {
        final transport = _ControlledTransport(serverTransport);
        final runtime = runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          transport: transport,
          isLifecycleSyncEnabled: () => false,
          writeSyncDebounce: const Duration(milliseconds: 10),
        );
        addTearDown(runtime.dispose);
        final online = StreamController<bool>(sync: true);
        addTearDown(online.close);
        runtime.bindOnlineStream(online.stream);
        online.add(false);
        await runtime.upsert('co_sync_probe', 'r1', {'value': 'pending'});
        online.add(true);
        await runtime.onAuthenticated();
        expect(transport.pushCalls, 1);
        expect(await runtime.store.pendingRows(), isEmpty);
        await runtime.upsert('co_sync_probe', 'r2', {'value': 'debounce'});
        await _waitUntil(() => transport.pushCalls == 2);
        await runtime.syncNow();
        expect(await runtime.store.pendingRows(), isEmpty);
        final baseline = transport.pullCalls;
        await runtime.syncNow();
        expect(transport.pullCalls, baseline + 1);
      },
    );

    test(
      'should_skip_network_when_periodic_is_offline_or_unauthenticated',
      () async {
        var authenticated = false;
        final transport = _ControlledTransport(serverTransport);
        final probe = _FakeProbe((
          currentVersion: _testSchemaVersion,
          minSupportedVersion: _testSchemaVersion,
          currentSignature: computeSchemaSignature(_testSchema),
        ));
        final runtime = runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          transport: transport,
          schemaProbe: probe,
          isAuthenticated: () => authenticated,
          periodicSyncInterval: const Duration(milliseconds: 10),
        );
        addTearDown(runtime.dispose);
        final online = StreamController<bool>(sync: true);
        final foreground = StreamController<bool>(sync: true);
        addTearDown(online.close);
        addTearDown(foreground.close);
        runtime.bindOnlineStream(online.stream);
        runtime.bindForegroundStream(
          foreground.stream,
          initiallyForeground: true,
        );
        online.add(true);
        foreground
          ..add(false)
          ..add(true);
        await Future<void>.delayed(const Duration(milliseconds: 35));
        expect(probe.calls, 0);
        expect(transport.pullCalls, 0);
        online.add(false);
        authenticated = true;
        await runtime.onAuthenticated();
        await runtime.upsert('co_sync_probe', 'r1', {'value': 'offline'});
        foreground
          ..add(false)
          ..add(true);
        await Future<void>.delayed(const Duration(milliseconds: 35));
        expect(probe.calls, 0);
        expect(transport.pullCalls, 0);
        expect(await runtime.store.pendingRows(), hasLength(1));
      },
    );

    test('should_discard_old_probe_when_reset_precedes_its_response', () async {
      final gate = Completer<SchemaWindowInfo>();
      final probe = _ControlledProbe(() => gate.future);
      final transport = _ControlledTransport(serverTransport);
      final statuses = <CoSyncSchemaStatus>[];
      final errors = <Object>[];
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        transport: transport,
        schemaProbe: probe,
        onSchemaStatus: (status, _) => statuses.add(status),
        onSyncError: (error, _) => errors.add(error),
      );
      addTearDown(runtime.dispose);
      final oldLogin = runtime.onAuthenticated();
      await _waitUntil(() => probe.calls == 1);
      await runtime.reset();
      await runtime.store.clearAll();
      gate.complete((
        currentVersion: _testSchemaVersion,
        minSupportedVersion: _testSchemaVersion,
        currentSignature: computeSchemaSignature(_testSchema),
      ));
      await oldLogin;
      expect(statuses, isEmpty);
      expect(errors, isEmpty);
      expect(transport.pullCalls, 0);
      expect(runtime.lastSchemaStatus, CoSyncSchemaStatus.unknown);
      await runtime.onAuthenticated();
      expect(transport.pullCalls, 1);
      expect(statuses, [CoSyncSchemaStatus.compatible]);
    });

    test(
      'should_stop_old_engine_before_pull_when_account_changes_during_push',
      () async {
        final gate = Completer<void>();
        final transport = _ControlledTransport(serverTransport)
          ..beforePush = (_) => gate.future;
        final runtime = runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          transport: transport,
        );
        addTearDown(runtime.dispose);
        await runtime.upsert('co_sync_probe', 'old', {'value': 'old account'});
        final oldWork = runtime.syncNow();
        await _waitUntil(() => transport.pushCalls == 1);
        await runtime.reset(inFlightTimeout: Duration.zero);
        await runtime.store.clearAll();
        await runtime.upsert('co_sync_probe', 'new', {'value': 'new account'});
        gate.complete();
        expect(await oldWork, isNull);
        expect(transport.pullCalls, 0, reason: '옛 엔진은 새 인증으로 후속 pull 을 못 보낸다');
        expect(await runtime.hasSyncedOnce, isFalse);
        final pending = await runtime.store.pendingRows();
        expect(pending.single.rowId, 'new');
        expect(await runtime.read('co_sync_probe', 'old'), isNull);
        await runtime.syncNow();
        expect(await runtime.store.pendingRows(), isEmpty);
      },
    );

    test(
      'should_rollback_client_initialization_when_reset_interrupts_node_id',
      () async {
        final db = CoSyncDatabase(NativeDatabase.memory());
        var clients = 0;
        final runtime = runtimeWith(
          db,
          clockFactory: (nodeId) {
            clients++;
            return HlcClock(nodeId: nodeId, wallClock: () => wall);
          },
        );
        addTearDown(runtime.dispose);
        final oldWork = runtime.syncNow();
        await runtime.reset();
        await runtime.store.clearAll();
        expect(await oldWork, isNull);
        expect(clients, 0, reason: '옛 초기화는 엔진 등록 전에 종료');
        expect(await runtime.hasSyncedOnce, isFalse);
        await runtime.upsert('co_sync_probe', 'new', {'value': 'new session'});
        expect(clients, 1);
        expect(await runtime.syncNow(), isNotNull);
      },
    );

    test('should_ignore_response_and_cancel_timers_when_disposed', () async {
      final gate = Completer<void>();
      final transport = _ControlledTransport(serverTransport);
      final errors = <Object>[];
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        transport: transport,
        periodicSyncInterval: const Duration(milliseconds: 10),
        onSyncError: (error, _) => errors.add(error),
      );
      final online = StreamController<bool>(sync: true);
      final foreground = StreamController<bool>(sync: true);
      addTearDown(online.close);
      addTearDown(foreground.close);
      runtime.bindOnlineStream(online.stream);
      online.add(true);
      await runtime.onAuthenticated();
      runtime.bindForegroundStream(
        foreground.stream,
        initiallyForeground: true,
      );
      transport.beforePull = (_) => gate.future;
      final baseline = transport.pullCalls;
      final work = runtime.syncNow();
      await _waitUntil(() => transport.pullCalls > baseline);
      await runtime.dispose();
      gate.complete();
      expect(await work, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(transport.pullCalls, baseline + 1);
      expect(errors, isEmpty);
      expect(await runtime.syncNow(), isNull);
      await runtime.dispose();
    });

    test(
      'should_suspend_periodic_until_login_when_reset_clears_account',
      () async {
        final transport = _ControlledTransport(serverTransport);
        final runtime = runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          transport: transport,
          periodicSyncInterval: const Duration(milliseconds: 30),
        );
        addTearDown(runtime.dispose);
        final online = StreamController<bool>(sync: true);
        final foreground = StreamController<bool>(sync: true);
        addTearDown(online.close);
        addTearDown(foreground.close);
        runtime.bindOnlineStream(online.stream);
        online.add(true);
        await runtime.onAuthenticated();
        runtime.bindForegroundStream(
          foreground.stream,
          initiallyForeground: true,
        );
        await runtime.reset();
        await runtime.store.clearAll();
        final baseline = transport.pullCalls;
        online
          ..add(false)
          ..add(true);
        foreground
          ..add(false)
          ..add(true);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(transport.pullCalls, baseline, reason: 'wipe 뒤 인증 확정까지 예약 중단');
        await runtime.onAuthenticated();
        foreground.add(false);
        expect(transport.pullCalls, baseline + 1);
      },
    );

    test(
      'should_resume_pending_when_schema_window_becomes_supported',
      () async {
        final transport = _ControlledTransport(serverTransport);
        final probe = _FakeProbe((
          currentVersion: _testSchemaVersion + 1,
          minSupportedVersion: _testSchemaVersion + 1,
          currentSignature: 'new schema',
        ));
        final runtime = runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          transport: transport,
          schemaProbe: probe,
          periodicSyncInterval: const Duration(milliseconds: 15),
          writeSyncDebounce: const Duration(seconds: 5),
        );
        addTearDown(runtime.dispose);
        final online = StreamController<bool>(sync: true);
        final foreground = StreamController<bool>(sync: true);
        addTearDown(online.close);
        addTearDown(foreground.close);
        runtime.bindOnlineStream(online.stream);
        online.add(true);
        await runtime.onAuthenticated();
        runtime.bindForegroundStream(
          foreground.stream,
          initiallyForeground: true,
        );
        await runtime.upsert('co_sync_probe', 'r1', {
          'value': 'pending upgrade',
        });
        await _waitUntil(() => probe.calls >= 2);
        expect(transport.pushCalls, 0);
        expect(transport.pullCalls, 0);
        expect(await runtime.store.pendingRows(), hasLength(1));
        probe.window = (
          currentVersion: _testSchemaVersion,
          minSupportedVersion: _testSchemaVersion,
          currentSignature: computeSchemaSignature(_testSchema),
        );
        await _waitUntil(() => transport.pushCalls > 0);
        await runtime.syncNow();
        foreground.add(false);
        expect(await runtime.store.pendingRows(), isEmpty);
        expect(runtime.lastSchemaStatus, CoSyncSchemaStatus.compatible);
      },
    );

    for (final transition in ['flag_off', 'background']) {
      test(
        'should_stop_after_probe_when_lifecycle_changes_to_$transition',
        () async {
          var enabled = true;
          var hold = false;
          final gate = Completer<SchemaWindowInfo>();
          final window = (
            currentVersion: _testSchemaVersion,
            minSupportedVersion: _testSchemaVersion,
            currentSignature: computeSchemaSignature(_testSchema),
          );
          final probe = _ControlledProbe(
            () async => hold ? gate.future : window,
          );
          final transport = _ControlledTransport(serverTransport);
          final runtime = runtimeWith(
            CoSyncDatabase(NativeDatabase.memory()),
            transport: transport,
            schemaProbe: probe,
            isLifecycleSyncEnabled: () => enabled,
          );
          addTearDown(runtime.dispose);
          final online = StreamController<bool>(sync: true);
          final foreground = StreamController<bool>(sync: true);
          addTearDown(online.close);
          addTearDown(foreground.close);
          runtime.bindOnlineStream(online.stream);
          online.add(true);
          await runtime.onAuthenticated();
          runtime.bindForegroundStream(
            foreground.stream,
            initiallyForeground: true,
          );
          final baseline = transport.pullCalls;
          foreground.add(false);
          hold = true;
          foreground.add(true);
          await _waitUntil(() => probe.calls == 2);
          final probing = runtime.verifySchemaWindow(); // 실행 중 probe 에 합류만 한다.
          if (transition == 'flag_off') {
            enabled = false;
          } else {
            foreground.add(false);
          }
          gate.complete(window);
          await probing;
          await Future<void>.delayed(Duration.zero);
          expect(transport.pullCalls, baseline);
        },
      );
    }

    test(
      'should_retry_on_later_tick_when_transport_fails_temporarily',
      () async {
        final transport = _ControlledTransport(serverTransport);
        final runtime = runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          transport: transport,
          periodicSyncInterval: const Duration(milliseconds: 15),
          writeSyncDebounce: const Duration(seconds: 5),
        );
        addTearDown(runtime.dispose);
        final online = StreamController<bool>(sync: true);
        final foreground = StreamController<bool>(sync: true);
        addTearDown(online.close);
        addTearDown(foreground.close);
        runtime.bindOnlineStream(online.stream);
        online.add(true);
        await runtime.onAuthenticated();
        runtime.bindForegroundStream(
          foreground.stream,
          initiallyForeground: true,
        );
        var fail = true;
        transport.beforePush = (_) async {
          if (fail) throw StateError('temporary network failure');
        };
        await runtime.upsert('co_sync_probe', 'r1', {'value': 'retry'});
        await _waitUntil(() => runtime.lastError != null);
        expect(await runtime.store.pendingRows(), hasLength(1));
        fail = false;
        await _waitUntil(() => runtime.lastError == null);
        foreground.add(false);
        expect(await runtime.store.pendingRows(), isEmpty);
        expect(transport.pushCalls, greaterThanOrEqualTo(2));
      },
    );
  });

  group('hasSyncedOnce', () {
    test('첫 pull 완료 전 false, 뒤 true', () async {
      final db = CoSyncDatabase(NativeDatabase.memory());
      final runtime = runtimeWith(db);
      addTearDown(runtime.dispose);
      expect(await runtime.hasSyncedOnce, isFalse);
      await runtime.syncNow();
      expect(await runtime.hasSyncedOnce, isTrue);
    });
  });
}

/// push 를 게이트에서 붙잡는 전송 — reset 과 in-flight sync 의 경합 재현용.
class _GatedTransport implements SyncTransport {
  _GatedTransport(this._inner, this._gate);

  final SyncTransport _inner;
  final Completer<void> _gate;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    await _gate.future;
    return _inner.push(request);
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      _inner.pull(request);
}

/// 호출 진입·완료 사이를 통제해 실제 엔진의 전송 경합을 검증한다.
class _ControlledTransport implements SyncTransport {
  _ControlledTransport(this._inner);

  final SyncTransport _inner;
  Future<void> Function(SyncPushRequest)? beforePush;
  Future<void> Function(SyncPullRequest)? beforePull;
  int pushCalls = 0;
  int pullCalls = 0;
  int active = 0;
  int maxActive = 0;

  Future<T> _track<T>(Future<T> Function() work) async {
    active++;
    if (active > maxActive) maxActive = active;
    try {
      return await work();
    } finally {
      active--;
    }
  }

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) => _track(() async {
    pushCalls++;
    await beforePush?.call(request);
    return _inner.push(request);
  });

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) => _track(() async {
    pullCalls++;
    await beforePull?.call(request);
    return _inner.pull(request);
  });
}

class _ControlledProbe implements SchemaWindowProbe {
  _ControlledProbe(this.fetch);
  final Future<SchemaWindowInfo> Function() fetch;
  int calls = 0;

  @override
  Future<SchemaWindowInfo> fetchSchemaWindow() {
    calls++;
    return fetch();
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('동기화 관측 조건이 3초 안에 성립하지 않았다');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
