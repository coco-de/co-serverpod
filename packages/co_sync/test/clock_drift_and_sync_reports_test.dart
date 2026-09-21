import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_sync/co_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

const _testSchemaVersion = 3;
const _testSchema = {
  'co_sync_probe': ['value', 'note'],
};

const _minute = Duration.millisecondsPerMinute;

/// push 요청 수를 세고, 필요하면 서버 응답에 구체화 건수를 덧붙이는 전송.
class _ServerTransport implements SyncTransport {
  _ServerTransport(this._inner);

  final SyncTransport _inner;
  int pushCalls = 0;

  /// 설정되면 push 응답에 `deferred`·`rejected` 를 싣는다(구체화 계층이 있는
  /// 서버의 흉내). null 이면 코어 서버 그대로 — 건수를 주지 않는다.
  ({int deferred, int rejected})? counts;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    pushCalls++;
    final applied = await _inner.push(request);
    final extra = counts;
    if (extra == null) return applied;
    return SyncPushResponse.fromJson(
      jsonDecode(
            jsonEncode(
              SyncPushResponse(
                appliedCount: applied.appliedCount,
                serverHlcPacked: applied.serverHlcPacked,
                deferredCount: extra.deferred,
                rejectedCount: extra.rejected,
              ).toJson(),
            ),
          )
          as Map<String, Object?>,
    );
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      _inner.pull(request);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // 단말 벽시계 — 서버는 여기서 [serverAhead] 만큼 앞서 있다.
  var wall = 10 * Duration.millisecondsPerHour;
  var serverAhead = 0;
  late InMemoryServerSyncStore serverStore;
  late _ServerTransport transport;

  setUp(() {
    wall = 10 * Duration.millisecondsPerHour;
    serverAhead = 0;
    serverStore = InMemoryServerSyncStore();
    transport = _ServerTransport(
      InProcessTransport(
        CoSyncServer(
          store: serverStore,
          clock: HlcClock(
            nodeId: 'server',
            wallClock: () => wall + serverAhead,
          ),
          syncSchema: _testSchema,
        ),
      ),
    );
  });

  CoSyncRuntime runtimeWith(
    CoSyncDatabase db, {
    void Function(Object, StackTrace)? onSyncError,
  }) => CoSyncRuntime(
    database: db,
    syncSchema: _testSchema,
    schemaVersion: _testSchemaVersion,
    transport: transport,
    maxFieldValueChars: 384 * 1024,
    onSyncError: onSyncError,
    clockFactory: (nodeId) => HlcClock(nodeId: nodeId, wallClock: () => wall),
  );

  group('CoSyncFailure — 시계 오차 두 방향 (unibook#14051)', () {
    test('should_classify_core_clock_drift_as_behind_and_transient', () {
      final at = DateTime(2026, 9, 22);
      final failure = CoSyncFailure.from(
        ClockDriftException(
          remoteMillis: 61 * _minute,
          wallMillis: 0,
          maxDriftMs: 60 * _minute,
        ),
        at: at,
      );

      expect(failure.code, kCoSyncClockDriftBehindCode);
      expect(failure.code, isNot(kCoSyncTransportFailureCode));
      expect(failure.isPermanent, isFalse, reason: '시계를 고치면 그대로 올라간다');
      expect(failure.isClockDrift, isTrue);
      expect(failure.message, contains('ahead of local wall clock'));
      expect(failure.at, at);
    });

    test('should_keep_server_clock_drift_code_for_device_ahead', () {
      final failure = CoSyncFailure.from(
        const CoSyncRemoteException(code: 'clock_drift', message: '시계 앞섬'),
        at: DateTime(2026, 9, 22),
      );

      expect(failure.code, kCoSyncClockDriftCode);
      expect(failure.isClockDrift, isTrue);
      expect(failure.isPermanent, isFalse);
    });

    test('should_not_flag_other_failures_as_clock_drift', () {
      for (final code in [
        kCoSyncTransportFailureCode,
        'schema_outdated',
        'payload_too_large',
      ]) {
        final failure = CoSyncFailure(
          code: code,
          isPermanent: false,
          at: DateTime(2026, 9, 22),
        );
        expect(failure.isClockDrift, isFalse, reason: code);
      }
    });
  });

  group('CoSyncRuntime — 단말 시계 뒤처짐 (계약 §7.2 ② · H2)', () {
    test(
      'should_record_clock_drift_behind_and_clear_pending_when_server_is_61_minutes_ahead',
      () async {
        serverAhead = 61 * _minute;
        final errors = <Object>[];
        final runtime = runtimeWith(
          CoSyncDatabase(NativeDatabase.memory()),
          onSyncError: (error, _) => errors.add(error),
        );
        addTearDown(runtime.dispose);
        final reports = <SyncReport>[];
        final subscription = runtime.syncReports.listen(reports.add);
        addTearDown(subscription.cancel);

        await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
        expect(runtime.status.value.pendingCount, 1);

        expect(await runtime.syncNow(), isNull, reason: '실패는 던지지 않고 null');

        expect(runtime.lastError, isA<ClockDriftException>());
        final failure = runtime.status.value.lastFailure;
        expect(failure?.code, kCoSyncClockDriftBehindCode);
        expect(failure?.isPermanent, isFalse);
        expect(failure?.isClockDrift, isTrue);
        expect(
          runtime.status.value.pendingCount,
          0,
          reason: '서버가 적용한 행은 해제됐다 — "미전송 1건" 은 거짓이다',
        );
        expect(
          (await serverStore.getRow('co_sync_probe', 'r1'))?.valuesView(),
          {'value': 'a'},
        );
        expect(await runtime.hasSyncedOnce, isFalse, reason: '커서는 전진하지 않는다');
        expect(transport.pushCalls, 1);
        expect(reports, isEmpty, reason: '실패한 회차는 보고를 발행하지 않는다');
        expect(errors.single, isA<ClockDriftException>(), reason: '침묵 실패 금지');

        // 다음 회차 — 같은 행을 다시 올리지 않는다. 뒤처짐은 계속 보고된다.
        await runtime.syncNow();
        expect(transport.pushCalls, 1, reason: '무한 재전송 없음');
        expect(
          runtime.status.value.lastFailure?.code,
          kCoSyncClockDriftBehindCode,
        );

        // 기기 시계를 고치면 다음 회차가 실패 표식을 지운다.
        wall += serverAhead;
        serverAhead = 0;
        await runtime.syncNow();
        expect(runtime.status.value.lastFailure, isNull);
        expect(await runtime.hasSyncedOnce, isTrue);
        expect(transport.pushCalls, 1);
      },
    );
  });

  group('CoSyncRuntime.syncReports — 구체화 보류·거부 건수 (unibook#14034)', () {
    test('should_publish_server_counts_for_each_successful_round', () async {
      transport.counts = (deferred: 2, rejected: 1);
      final runtime = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(runtime.dispose);
      final reports = <SyncReport>[];
      final subscription = runtime.syncReports.listen(reports.add);
      addTearDown(subscription.cancel);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      final returned = await runtime.syncNow();
      await Future<void>.delayed(Duration.zero);

      expect(returned?.pushedRows, 1);
      expect(returned?.deferredCount, 2);
      expect(returned?.rejectedCount, 1);
      expect(reports, hasLength(1));
      expect(reports.single.deferredCount, 2);
      expect(reports.single.rejectedCount, 1);
    });

    test('should_report_unknown_counts_when_server_omits_them', () async {
      final runtime = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(runtime.dispose);

      await runtime.upsert('co_sync_probe', 'r1', {'value': 'a'});
      final report = await runtime.syncNow();

      expect(report?.pushedRows, 1);
      expect(report?.deferredCount, isNull, reason: '미상은 0 이 아니다');
      expect(report?.rejectedCount, isNull);
    });

    test('should_report_zero_counts_when_nothing_was_pushed', () async {
      final runtime = runtimeWith(CoSyncDatabase(NativeDatabase.memory()));
      addTearDown(runtime.dispose);

      final report = await runtime.syncNow();

      expect(report?.pushedRows, 0);
      expect(report?.deferredCount, 0);
      expect(report?.rejectedCount, 0);
    });
  });
}
