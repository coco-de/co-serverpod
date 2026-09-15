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

/// 지정한 코드로만 실패하는 전송 — 실패 분류 축 검증용.
class _RejectingTransport implements SyncTransport {
  _RejectingTransport(this.error);

  Object error;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) => throw error;

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) => throw error;
}

/// push 가 응답하기 전에 멈춰 세울 수 있는 전송 — `inFlight` 관측용.
class _GatedTransport implements SyncTransport {
  _GatedTransport(this._inner);

  final SyncTransport _inner;
  final Completer<void> gate = Completer<void>();
  final Completer<void> entered = Completer<void>();

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    return _inner.push(request);
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      _inner.pull(request);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 400; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('조건이 상한 안에 성립하지 않았다');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  var wall = 1000;
  late InMemoryServerSyncStore serverStore;
  late CoSyncServer server;
  late InProcessTransport serverTransport;

  CoSyncRuntime runtimeWith(
    CoSyncDatabase db, {
    SyncTransport? transport,
    bool Function()? isAuthenticated,
    Duration writeSyncDebounce = const Duration(seconds: 2),
  }) => CoSyncRuntime(
    database: db,
    syncSchema: _testSchema,
    schemaVersion: _testSchemaVersion,
    transport: transport ?? serverTransport,
    maxFieldValueChars: 384 * 1024,
    isAuthenticated: isAuthenticated,
    writeSyncDebounce: writeSyncDebounce,
    clockFactory: (nodeId) => HlcClock(nodeId: nodeId, wallClock: () => wall),
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

  group('CoSyncFailure.from', () {
    test('should_carry_server_code_when_error_is_typed', () {
      final at = DateTime(2026, 9, 15);
      final failure = CoSyncFailure.from(
        const CoSyncRemoteException(code: 'schema_outdated', message: '앱이 낡음'),
        at: at,
      );

      expect(failure.code, 'schema_outdated');
      expect(failure.isPermanent, isTrue);
      expect(failure.message, '앱이 낡음');
      expect(failure.at, at);
    });

    test('should_classify_clock_drift_as_transient', () {
      final failure = CoSyncFailure.from(
        const CoSyncRemoteException(code: 'clock_drift', message: '시계 어긋남'),
        at: DateTime(2026, 9, 15),
      );

      // 시계 오류는 사용자 안내 대상이지만 **영구 실패가 아니다** — 기기
      // 시계를 고치면 같은 페이로드가 그대로 올라간다.
      expect(failure.code, 'clock_drift');
      expect(failure.isPermanent, isFalse);
    });

    test('should_fall_back_to_transport_code_and_stay_transient', () {
      final failure = CoSyncFailure.from(
        const SocketLikeError(),
        at: DateTime(2026, 9, 15),
      );

      // ⚠️ 여기가 true 로 뒤집히면 오프라인이 "영구 실패" 로 보인다.
      expect(failure.code, kCoSyncTransportFailureCode);
      expect(failure.isPermanent, isFalse);
    });
  });

  group('CoSyncStatus 값', () {
    test('should_treat_equal_fields_as_equal', () {
      final at = DateTime(2026, 9, 15);
      final a = CoSyncStatus(
        pendingCount: 2,
        lastSuccessAt: at,
        lastFailure: CoSyncFailure.from(const SocketLikeError(), at: at),
      );
      final b = CoSyncStatus(
        pendingCount: 2,
        lastSuccessAt: at,
        lastFailure: CoSyncFailure.from(const SocketLikeError(), at: at),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('should_report_attention_only_for_actionable_states', () {
      const idle = CoSyncStatus();
      expect(idle.isIdle, isTrue);
      expect(idle.needsAttention, isFalse);

      final transient = CoSyncStatus(
        pendingCount: 3,
        lastFailure: CoSyncFailure.from(
          const SocketLikeError(),
          at: DateTime(2026, 9, 15),
        ),
      );
      expect(transient.isIdle, isFalse);
      // 자동 재시도가 받아내므로 사유 시트를 열 이유가 없다.
      expect(transient.needsAttention, isFalse);

      expect(const CoSyncStatus(quarantinedCount: 1).needsAttention, isTrue);
      expect(
        const CoSyncStatus(
          schemaStatus: CoSyncSchemaStatus.appOutdated,
        ).needsAttention,
        isTrue,
      );
      final permanent = CoSyncStatus(
        lastFailure: CoSyncFailure.from(
          const CoSyncRemoteException(code: 'protocol', message: 'x'),
          at: DateTime(2026, 9, 15),
        ),
      );
      expect(permanent.needsAttention, isTrue);
    });

    test('should_clear_last_failure_only_with_explicit_flag', () {
      final failed = CoSyncStatus(
        lastFailure: CoSyncFailure.from(
          const SocketLikeError(),
          at: DateTime(2026, 9, 15),
        ),
      );

      expect(failed.copyWith(pendingCount: 1).lastFailure, isNotNull);
      expect(failed.copyWith(clearLastFailure: true).lastFailure, isNull);
    });
  });

  group('unsentRowCount', () {
    test('should_match_unsentRows_length_including_quarantined', () async {
      final runtime = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(runtime.dispose);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      await runtime.upsert('co_sync_probe', 'r2', {'value': 'b'});
      await runtime.store.quarantineRow(
        'co_sync_probe',
        'r2',
        reason: const QuarantineReason(code: 'protocol', message: 'x'),
        at: DateTime(2026, 9, 15),
      );

      // 격리분은 `pendingRows` 에서 빠지지만 **미전송**이다.
      expect(await runtime.store.pendingRows(), hasLength(1));
      expect(await runtime.store.unsentRows(), hasLength(2));
      expect(await runtime.store.unsentRowCount(), 2);
      expect(
        await runtime.store.unsentRowCount(),
        (await runtime.store.unsentRows()).length,
      );
    });
  });

  group('CoSyncRuntime.status', () {
    test(
      'should_expose_pending_count_while_offline_and_clear_after_sync',
      () async {
        final runtime = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
        addTearDown(runtime.dispose);
        final seen = <CoSyncStatus>[];
        runtime.status.addListener(() => seen.add(runtime.status.value));

        await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
        await runtime.upsert('co_sync_probe', 'r2', {'value': 'b'});

        expect(runtime.status.value.pendingCount, 2);
        expect(runtime.status.value.lastSuccessAt, isNull);
        expect(seen.map((s) => s.pendingCount), containsAllInOrder([1, 2]));

        await runtime.syncNow();

        expect(runtime.status.value.pendingCount, 0);
        expect(runtime.status.value.lastSuccessAt, isNotNull);
        expect(runtime.status.value.lastFailure, isNull);
        expect(runtime.status.value.isIdle, isTrue);
      },
    );

    test('should_report_in_flight_only_while_a_round_is_running', () async {
      final gated = _GatedTransport(serverTransport);
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        transport: gated,
      );
      addTearDown(runtime.dispose);
      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      expect(runtime.status.value.inFlight, isFalse);

      final sync = runtime.syncNow();
      await gated.entered.future;
      expect(runtime.status.value.inFlight, isTrue);

      gated.gate.complete();
      await sync;
      expect(runtime.status.value.inFlight, isFalse);
    });

    test('should_record_typed_failure_and_keep_pending_count', () async {
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        transport: _RejectingTransport(
          const CoSyncRemoteException(
            code: 'schema_outdated',
            message: '앱이 낡음',
          ),
        ),
      );
      addTearDown(runtime.dispose);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      await runtime.syncNow();

      final status = runtime.status.value;
      expect(status.lastFailure?.code, 'schema_outdated');
      expect(status.lastFailure?.isPermanent, isTrue);
      expect(status.needsAttention, isTrue);
      // 실패했으니 미전송분은 그대로 남아 있어야 한다.
      expect(status.pendingCount, 1);
      expect(status.lastSuccessAt, isNull);
    });

    test('should_clear_last_failure_after_a_later_success', () async {
      final rejecting = _RejectingTransport(
        const CoSyncRemoteException(code: 'clock_drift', message: '시계'),
      );
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        transport: rejecting,
      );
      addTearDown(runtime.dispose);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      await runtime.syncNow();
      expect(runtime.status.value.lastFailure?.code, 'clock_drift');

      // 전송을 정상으로 되돌리면 다음 회차가 실패 표식을 지운다.
      final healthy = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(healthy.dispose);
      await healthy.upsert('co_sync_probe', 'r2', {'value': 'b'});
      await healthy.syncNow();
      expect(healthy.status.value.lastFailure, isNull);
      expect(healthy.status.value.lastSuccessAt, isNotNull);
    });

    test('should_mirror_quarantined_count', () async {
      final runtime = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(runtime.dispose);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      await runtime.store.quarantineRow(
        'co_sync_probe',
        'r1',
        reason: const QuarantineReason(code: 'payload_too_large', message: 'x'),
        at: DateTime(2026, 9, 15),
      );
      await runtime.refreshQuarantineCount();

      expect(runtime.status.value.quarantinedCount, 1);
      // 격리분은 pendingCount 에 **포함**된다 — 두 값을 더하면 중복이다.
      expect(runtime.status.value.pendingCount, 1);
      expect(runtime.status.value.needsAttention, isTrue);
    });

    test('should_reset_every_axis_on_account_switch', () async {
      // ⚠️ 전송 계층 실패를 쓴다 — `protocol` 은 행 귀속 영구 거부라 격리
      //    카운터를 움직이고, 그러면 reset 의 `quarantinedRowCount = 0` 이
      //    리스너를 깨워 발행이 **우연히** 일어난다. 그 경로로는 reset 의
      //    명시적 발행이 있는지 없는지를 구분할 수 없다 (동등 변이).
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        transport: _RejectingTransport(const SocketLikeError()),
      );
      addTearDown(runtime.dispose);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      await runtime.syncNow();
      expect(runtime.status.value.pendingCount, 1);
      expect(runtime.status.value.lastFailure, isNotNull);
      expect(runtime.status.value.quarantinedCount, 0);
      expect(runtime.status.value.schemaStatus, CoSyncSchemaStatus.unknown);

      await runtime.reset();

      // 옛 계정의 "대기 N건" 이 다음 계정 화면에 남으면 안 된다.
      expect(runtime.status.value, const CoSyncStatus());
    });

    test(
      'should_clear_status_on_reset_even_when_row_was_quarantined',
      () async {
        // 위 테스트와 짝 — 격리가 있었던 경우도 같은 결과여야 한다.
        final runtime = runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          transport: _RejectingTransport(
            const CoSyncRemoteException(code: 'protocol', message: 'x'),
          ),
        );
        addTearDown(runtime.dispose);

        await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
        await runtime.syncNow();
        expect(runtime.status.value.quarantinedCount, greaterThan(0));

        await runtime.reset();

        expect(runtime.status.value, const CoSyncStatus());
      },
    );

    test('should_not_notify_when_nothing_changed', () async {
      final runtime = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(runtime.dispose);
      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});

      var notifications = 0;
      runtime.status.addListener(() => notifications++);
      await runtime.refreshUnsentCount();
      await runtime.refreshUnsentCount();

      expect(notifications, 0);
    });

    test('should_pick_up_backlog_written_outside_the_write_path', () async {
      // 앱 재시작·복원 경로가 남긴 pending 은 이 런타임의 `upsert` 를 거치지
      // 않는다. 그래서 `pendingCount` 는 캐시이고, 갱신 지점이 필요하다.
      final runtime = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(runtime.dispose);
      expect(runtime.status.value.pendingCount, 0);

      final stamp = HlcClock(nodeId: 'restored', wallClock: () => wall).now();
      await runtime.store.putRow(
        'co_sync_probe',
        RowState(rowId: 'r1', fields: {'value': FieldValue('a', stamp)}),
        origin: ChangeOrigin.local,
        pending: true,
      );
      // 갱신 전에는 캐시가 뒤처져 있다 — 이 값이 0 이 아니면 어딘가 다른
      // 경로가 몰래 갱신하고 있다는 뜻이라 이 단언이 그것을 잡는다.
      expect(runtime.status.value.pendingCount, 0);

      await runtime.refreshUnsentCount();
      expect(runtime.status.value.pendingCount, 1);
    });

    test('should_stay_silent_when_unauthenticated_sync_is_a_noop', () async {
      final runtime = runtimeWith(
        CoSyncDatabase(NativeDatabase.memory()),
        isAuthenticated: () => false,
      );
      addTearDown(runtime.dispose);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      await runtime.syncNow();

      // 미인증은 실패가 아니다 — 사유 시트를 열면 안 된다.
      expect(runtime.status.value.lastFailure, isNull);
      expect(runtime.status.value.inFlight, isFalse);
      expect(runtime.status.value.pendingCount, 1);
      await _waitUntil(() => true);
    });
  });
}

/// 전송 계층 실패의 대역 — 타입드 실패가 **아닌** 예외.
class SocketLikeError implements Exception {
  const SocketLikeError();

  @override
  String toString() => 'SocketLikeError: 연결이 끊겼습니다';
}
