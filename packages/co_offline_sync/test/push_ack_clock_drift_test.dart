import 'dart:async';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:test/test.dart';

const _schema = {
  'note': ['title', 'body'],
};

const _hour = Duration.millisecondsPerHour;
const _minute = Duration.millisecondsPerMinute;

/// push·pull 호출을 세고, 필요하면 push 응답을 테스트가 풀어 줄 때까지 붙잡는
/// 전송 래퍼.
class _ObservingTransport implements SyncTransport {
  _ObservingTransport(this._inner);

  final SyncTransport _inner;
  final List<List<String>> pushedRowIds = [];
  int pullCalls = 0;

  /// 설정되면 push 가 **서버에 적용된 뒤** 응답을 돌려주기 전에 멈춘다.
  Completer<void>? holdResponse;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    pushedRowIds.add([for (final c in request.changes) c.state.rowId]);
    final response = await _inner.push(request);
    final hold = holdResponse;
    if (hold != null) await hold.future;
    return response;
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) {
    pullCalls++;
    return _inner.pull(request);
  }
}

/// 어떤 실패든 행 귀속 영구 실패로 분류하는 분류기 — 응답을 받은 뒤의 예외가
/// 분류기로 새면 적용된 행이 격리된다는 것을 드러내는 대조용.
QuarantineReason? _classifyEverything(Object error) =>
    QuarantineReason(code: 'any', message: '$error');

void main() {
  // 서버 벽시계. 단말은 여기서 [deviceOffset] 만큼 어긋나 있다.
  var serverWall = 10 * _hour;
  var deviceOffset = 0;
  late InMemoryServerSyncStore serverStore;
  late _ObservingTransport transport;

  setUp(() {
    serverWall = 10 * _hour;
    deviceOffset = 0;
    serverStore = InMemoryServerSyncStore();
    transport = _ObservingTransport(
      InProcessTransport(
        CoSyncServer(
          store: serverStore,
          clock: HlcClock(nodeId: 'server', wallClock: () => serverWall),
          syncSchema: _schema,
        ),
      ),
    );
  });

  CoSyncClient device(
    String nodeId,
    InMemoryClientSyncStore store, {
    int maxChangesPerPush = 400,
    PushFailureClassifier? classifier,
  }) => CoSyncClient(
    store: store,
    transport: transport,
    clock: HlcClock(nodeId: nodeId, wallClock: () => serverWall + deviceOffset),
    syncSchema: _schema,
    maxChangesPerPush: maxChangesPerPush,
    classifyPushFailure: classifier,
  );

  Matcher driftBeyond(int ms) => isA<ClockDriftException>().having(
    (e) => e.remoteMillis - e.wallMillis,
    'remote - wall',
    greaterThan(ms),
  );

  Future<List<String>> serverRowIds() async => [
    for (final change in (await serverStore.changesSince(
      0,
      limit: 100,
    )).changes)
      change.state.rowId,
  ];

  group('H2 — 서버가 적용한 행은 스탬프 수용과 무관하게 해제된다 (unibook#14051)', () {
    test(
      'should_clear_acknowledged_rows_and_report_drift_when_device_is_61_minutes_behind',
      () async {
        deviceOffset = -61 * _minute;
        final store = InMemoryClientSyncStore();
        final a = device('A', store);
        await a.upsert('note', 'r1', {'title': 't1'});
        await a.upsert('note', 'r2', {'title': 't2'});

        await expectLater(a.sync(), throwsA(driftBeyond(_hour)));

        expect(
          await serverRowIds(),
          unorderedEquals(['r1', 'r2']),
          reason: '서버는 응답 전에 이미 적용했다',
        );
        expect(
          await store.pendingRows(),
          isEmpty,
          reason: '적용된 행이 pending 에 남으면 매 회차 재전송된다',
        );
        expect(await store.unsentRowCount(), 0, reason: '"미전송 N건" 이 거짓이 아니다');
        expect(transport.pushedRowIds, hasLength(1));
        expect(transport.pullCalls, 0, reason: '드리프트를 안 회차는 pull 하지 않는다');
        expect(await store.loadCursor(), isNull, reason: '커서는 전진하지 않는다');

        // 다음 회차 — 같은 행을 다시 올리지 않는다(무한 재전송 없음). 드리프트는
        // 이번엔 pull 이 같은 타입으로 보고한다.
        await expectLater(a.sync(), throwsA(driftBeyond(_hour)));
        expect(transport.pushedRowIds, hasLength(1), reason: '재전송 0');
        expect(transport.pullCalls, 1);
        expect(await store.loadCursor(), isNull);
      },
    );

    test(
      'should_push_every_chunk_before_reporting_drift_when_pending_spans_chunks',
      () async {
        deviceOffset = -61 * _minute;
        final store = InMemoryClientSyncStore();
        final a = device('A', store, maxChangesPerPush: 1);
        for (var i = 0; i < 3; i++) {
          await a.upsert('note', 'r$i', {'title': 't$i'});
        }

        await expectLater(a.sync(), throwsA(isA<ClockDriftException>()));

        expect(transport.pushedRowIds, [
          ['r0'],
          ['r1'],
          ['r2'],
        ], reason: '서버는 뒤 청크도 받아 준다 — 한 회차에 한 청크씩 새지 않는다');
        expect(await serverRowIds(), unorderedEquals(['r0', 'r1', 'r2']));
        expect(await store.pendingRows(), isEmpty);
      },
    );

    test('should_not_route_ack_drift_through_quarantine_classifier', () async {
      deviceOffset = -61 * _minute;
      final store = InMemoryClientSyncStore();
      final quarantined = <QuarantinedRow>[];
      final a = CoSyncClient(
        store: store,
        transport: transport,
        clock: HlcClock(
          nodeId: 'A',
          wallClock: () => serverWall + deviceOffset,
        ),
        syncSchema: _schema,
        classifyPushFailure: _classifyEverything,
        onRowQuarantined: quarantined.add,
      );
      await a.upsert('note', 'r1', {'title': 't1'});
      await a.upsert('note', 'r2', {'title': 't2'});

      await expectLater(a.sync(), throwsA(isA<ClockDriftException>()));

      // 응답 뒤의 예외가 분류기로 새면 이분 재시도가 적용된 행을 다시 보내고
      // 끝내 격리한다 — 서버에 있는 행을 "영영 안 올라간 행" 으로 표시하게 된다.
      expect(quarantined, isEmpty);
      expect(await store.quarantinedRowCount(), 0);
      expect(transport.pushedRowIds, [
        ['r1', 'r2'],
      ], reason: '쪼개 재전송하지 않는다');
      expect(await store.pendingRows(), isEmpty);
    });

    test(
      'should_keep_rows_edited_during_flight_pending_when_ack_drift_occurs',
      () async {
        deviceOffset = -61 * _minute;
        final store = InMemoryClientSyncStore();
        final a = device('A', store);
        await a.upsert('note', 'r1', {'title': 'before'});
        await a.upsert('note', 'r2', {'title': 'untouched'});
        final hold = Completer<void>();
        transport.holdResponse = hold;

        final syncing = expectLater(
          a.sync(),
          throwsA(isA<ClockDriftException>()),
        );
        // push 가 서버에 적용된 뒤·응답 전 — 그 사이의 로컬 편집.
        await Future<void>.delayed(Duration.zero);
        expect(transport.pushedRowIds, hasLength(1));
        deviceOffset += 1;
        await a.upsert('note', 'r1', {'title': 'during-flight'});
        hold.complete();
        await syncing;

        final pending = (await store.pendingRows()).map((p) => p.rowId);
        expect(pending, [
          'r1',
        ], reason: '해제는 전송 스냅샷 이하만 — 비행 중 편집은 다음 push 에 실린다');
      },
    );

    test('should_resume_normally_when_device_clock_is_corrected', () async {
      deviceOffset = -61 * _minute;
      final store = InMemoryClientSyncStore();
      final a = device('A', store);
      await a.upsert('note', 'r1', {'title': 't1'});
      await expectLater(a.sync(), throwsA(isA<ClockDriftException>()));

      deviceOffset = 0; // 사용자가 기기 시계를 고쳤다.
      final report = await a.sync();

      expect(report.pushedRows, 0, reason: '확정된 행은 다시 올리지 않는다');
      expect(report.pulledChanges, 0, reason: '자기 echo 는 재적용되지 않는다');
      expect(await store.loadCursor(), isNotNull, reason: '이제 커서가 전진한다');
      expect(transport.pushedRowIds, hasLength(1));
    });

    test(
      'should_accept_server_stamp_when_device_is_behind_within_the_limit',
      () async {
        // 대조군 — 59분 뒤처짐은 허용 한도 안이라 종전처럼 정상 수렴한다.
        deviceOffset = -59 * _minute;
        final store = InMemoryClientSyncStore();
        final a = device('A', store);
        await a.upsert('note', 'r1', {'title': 't1'});

        final report = await a.sync();

        expect(report.pushedRows, 1);
        expect(await store.pendingRows(), isEmpty);
        expect(await store.loadCursor(), isNotNull);
      },
    );
  });

  group('pull 의 시계 오차 — 커서 미전진, 같은 타입으로 보고 (계약 §7.2 ②)', () {
    test('should_keep_cursor_and_merge_nothing_when_pull_sees_drift', () async {
      // 정상 시계의 다른 단말이 먼저 올려 둔다.
      final writerStore = InMemoryClientSyncStore();
      final writer = device('W', writerStore);
      await writer.upsert('note', 'r1', {'title': 'from-writer'});
      await writer.sync();

      deviceOffset = -61 * _minute;
      final store = InMemoryClientSyncStore();
      final behind = device('B', store);

      await expectLater(behind.sync(), throwsA(driftBeyond(_hour)));

      expect(await store.loadCursor(), isNull);
      expect(await store.getRow('note', 'r1'), isNull, reason: '병합하지 않는다');

      deviceOffset = 0;
      final report = await behind.sync();
      expect(report.pulledChanges, 1);
      expect(await store.loadCursor(), isNotNull);
      expect((await behind.read('note', 'r1'))!.values, {
        'title': 'from-writer',
      });
    });
  });
}
