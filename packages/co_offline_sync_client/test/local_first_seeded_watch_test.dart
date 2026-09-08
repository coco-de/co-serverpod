import 'dart:async';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_offline_sync_client/co_offline_sync_client.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// 전송을 절대 타지 않는다 — `syncNow` 를 스텁하므로 도달하지 않는다.
class _UnreachableTransport implements SyncTransport {
  @override
  Future<SyncPushResponse> push(SyncPushRequest request) =>
      throw StateError('테스트에서 전송에 도달하면 안 된다');

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      throw StateError('테스트에서 전송에 도달하면 안 된다');
}

/// `isOnline`·`hasSyncedOnce`·`syncNow` 를 손으로 제어하는 런타임.
class _ScriptedRuntime extends CoSyncRuntime {
  _ScriptedRuntime(CoSyncDatabase db, this.log)
    : super(
        database: db,
        syncSchema: const {},
        schemaVersion: 1,
        transport: _UnreachableTransport(),
        maxFieldValueChars: 4096,
      );

  final List<String> log;

  /// `syncNow` 가 끝나면 `hasSyncedOnce` 가 true 가 되게 할지.
  bool syncMakesSeeded = false;
  Completer<void>? syncGate;

  /// 연결성 스크립트 — 필드가 getter 를 덮는다.
  @override
  bool isOnline = false;

  /// 시드 스크립트 — 필드가 getter 를 덮는다.
  @override
  Future<bool> hasSyncedOnce = Future.value(false);

  @override
  Future<SyncReport?> syncNow() async {
    log.add('sync');
    await syncGate?.future;
    if (syncMakesSeeded) hasSyncedOnce = Future.value(true);
    return null;
  }
}

/// S3-9b (#12963) — co_sync ⋈ replica 소비의 2축 시드 게이트.
///
/// | co_sync `hasSyncedOnce` | replica pull 성공 | 빈 값 |
/// |---|---|---|
/// | false | false | 미수신 — 내보내지 않는다 |
/// | 그 외 | | 내보낸다 |
///
/// 그리고 **sync → pull 순서**와 **갭 키 재시동(dedupe)** 을 고정한다.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late CoSyncDatabase db;
  late ReplicaStore replicaStore;
  late List<String> log;
  late _ScriptedRuntime runtime;

  setUp(() {
    db = CoSyncDatabase(NativeDatabase.memory());
    replicaStore = ReplicaStore(db);
    log = [];
    runtime = _ScriptedRuntime(db, log);
  });

  tearDown(() async {
    await runtime.reset();
    await db.close();
  });

  const emptyPage = ReplicaPage(rows: [], nextCursor: 'c', hasMore: false);

  ReplicaPuller puller({bool succeed = true}) => ReplicaPuller(
    store: replicaStore,
    domains: {
      'book_meta': (_) async {
        log.add('pull');
        if (!succeed) throw Exception('offline');
        return emptyPage;
      },
    },
  );

  Stream<List<int>> gated(
    Stream<List<int>> Function() watch, {
    required ReplicaPuller replicaPuller,
    Set<Object> Function(List<int>)? gapKeys,
  }) => localFirstSeededWatch<List<int>>(
    watch: watch,
    runtime: runtime,
    puller: replicaPuller,
    replicaDomains: const {'book_meta'},
    isEmpty: (value) => value.isEmpty,
    gapKeys: gapKeys,
  );

  Future<List<List<int>>> collect(
    Stream<List<int>> stream, {
    Duration settle = const Duration(milliseconds: 50),
  }) async {
    final emissions = <List<int>>[];
    final sub = stream.listen(emissions.add);
    await Future<void>.delayed(settle);
    await sub.cancel();
    return emissions;
  }

  group('시드 게이트 — 2축 OR', () {
    test('비어 있지 않은 값은 두 축이 모두 false 여도 즉시 emit 된다 (오프라인 콜드스타트)', () async {
      final emissions = await collect(
        gated(
          () => Stream.value([1, 2]),
          replicaPuller: puller(succeed: false),
        ),
      );
      expect(emissions, [
        [1, 2],
      ]);
    });

    test('빈 값 + hasSyncedOnce=false + pull 실패 → 미수신, 내보내지 않는다', () async {
      final emissions = await collect(
        gated(
          () => Stream.value(<int>[]),
          replicaPuller: puller(succeed: false),
        ),
      );
      expect(emissions, isEmpty, reason: '"0 → N" 깜빡임을 막는다');
    });

    test('빈 값 + hasSyncedOnce=true → pull 이 실패해도 빈 목록을 내보낸다', () async {
      runtime.hasSyncedOnce = Future.value(true);
      final emissions = await collect(
        gated(
          () => Stream.value(<int>[]),
          replicaPuller: puller(succeed: false),
        ),
      );
      expect(emissions, [<int>[]], reason: 'co_sync 축이 시드 — 진짜 빈 목록');
    });

    test('빈 값 + hasSyncedOnce=false + pull 성공 → 빈 목록을 내보낸다', () async {
      final emissions = await collect(
        gated(() => Stream.value(<int>[]), replicaPuller: puller()),
      );
      expect(emissions, [<int>[]], reason: 'replica 축이 시드 — 진짜 빈 목록');
    });

    test('syncNow 가 끝난 뒤 hasSyncedOnce 가 true 로 바뀌면 그때 빈 값이 나온다', () async {
      runtime
        ..isOnline = true
        ..syncMakesSeeded = true;
      final emissions = await collect(
        gated(
          () => Stream.value(<int>[]),
          replicaPuller: puller(succeed: false),
        ),
      );
      expect(emissions, [<int>[]]);
    });
  });

  group('왕복 순서 — sync → pull', () {
    test('온라인이면 syncNow 가 pull 보다 먼저 완료된다', () async {
      runtime.isOnline = true;
      final gate = Completer<void>();
      runtime.syncGate = gate;

      final sub = gated(
        () => Stream.value([1]),
        replicaPuller: puller(),
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(log, ['sync'], reason: 'sync 가 끝나기 전에는 pull 이 시작되지 않는다');

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(log, ['sync', 'pull']);
    });

    test('오프라인이면 syncNow 를 부르지 않고 pull 만 시동한다', () async {
      await collect(gated(() => Stream.value([1]), replicaPuller: puller()));
      expect(log, ['pull'], reason: '오프라인 sync 는 실패 로그만 만든다');
    });
  });

  group('갭 키 — 조인 상대 없는 행의 재시동', () {
    test('갭이 있으면 한 번 더 왕복하고, 같은 갭에는 반복하지 않는다', () async {
      runtime.isOnline = true;
      final source = StreamController<List<int>>();
      addTearDown(source.close);

      final sub = gated(
        () => source.stream,
        replicaPuller: puller(),
        gapKeys: (value) => value.where((id) => id < 0).toSet(),
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(log, ['sync', 'pull'], reason: '구독 시 1회');

      source.add([1, -2]); // -2: 메타 없는 행
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(log, ['sync', 'pull', 'sync', 'pull'], reason: '갭 → 재시동');

      source.add([1, -2]); // 같은 갭 재emit
      source.add([3, -2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(log, hasLength(4), reason: '같은 갭 집합에는 반복 왕복하지 않는다');

      source.add([1, -2, -5]); // 갭 확장
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(log, hasLength(6), reason: '집합이 바뀌면 다시 시동');

      source.add([1, 2, 5]); // 갭 해소
      source.add([1, 2, 5, -9]); // 새 갭
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(log, hasLength(8), reason: '해소 뒤 새 갭은 다시 시동');
    });

    test('gapKeys 를 주지 않으면 값이 무엇이든 재시동하지 않는다', () async {
      runtime.isOnline = true;
      final source = StreamController<List<int>>();
      addTearDown(source.close);
      final sub = gated(
        () => source.stream,
        replicaPuller: puller(),
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      source.add([-1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(log, ['sync', 'pull']);
    });
  });

  test('등록되지 않은 replica 도메인은 스트림 에러로 드러난다 — 빈 목록으로 위장 금지', () async {
    final errors = <Object>[];
    final sub = localFirstSeededWatch<List<int>>(
      watch: () => Stream.value(<int>[]),
      runtime: runtime,
      puller: puller(),
      replicaDomains: const {'unregistered'},
      isEmpty: (value) => value.isEmpty,
    ).listen((_) {}, onError: errors.add);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await sub.cancel();
    expect(errors.single, isA<ArgumentError>());
  });

  test('구독 해제 뒤 도착한 왕복 완료는 emit 하지 않는다', () async {
    runtime.isOnline = true;
    final gate = Completer<void>();
    runtime.syncGate = gate;
    final emissions = <List<int>>[];
    final sub = gated(
      () => Stream.value(<int>[]),
      replicaPuller: puller(),
    ).listen(emissions.add);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sub.cancel();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(emissions, isEmpty);
  });
}
