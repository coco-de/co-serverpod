import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:test/test.dart';

const _schema = {
  'note': ['title', 'body'],
};

Map<String, Object?> _wire(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

/// d0d653a2(#14034 이전) 의 `SyncPushResponse.fromJson` 을 **그대로** 옮긴 것 —
/// 이미 배포된 앱이 새 서버 응답을 읽는 방식이다. 이 코드를 고치지 말 것.
({int applied, String hlc}) _decodeLikeDeployedClient(
  Map<String, Object?> json,
) => (applied: json['applied']! as int, hlc: json['hlc']! as String);

/// 서버 응답에 구체화 건수를 덧붙이는 전송 — 구체화 계층이 있는 서버의 흉내.
///
/// 청크마다 `deferred = 변경 수`, `rejected = 1` 을 싣는다. [omitCountsOnCall]
/// 번째 push 는 건수를 싣지 않는다(구 서버 인스턴스가 섞인 롤링 배포).
class _CountingServerTransport implements SyncTransport {
  _CountingServerTransport(this._inner);

  final SyncTransport _inner;
  int pushCalls = 0;
  int? omitCountsOnCall;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    pushCalls++;
    final applied = await _inner.push(request);
    if (pushCalls == omitCountsOnCall) return applied;
    return SyncPushResponse.fromJson(
      _wire(
        SyncPushResponse(
          appliedCount: applied.appliedCount,
          serverHlcPacked: applied.serverHlcPacked,
          deferredCount: request.changes.length,
          rejectedCount: 1,
        ).toJson(),
      ),
    );
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) =>
      _inner.pull(request);
}

void main() {
  group(
    'SyncPushResponse 와이어 — deferredCount·rejectedCount (unibook#14034)',
    () {
      const hlc = '0000000003e8-0000-server';

      test('should_omit_count_keys_when_counts_are_unknown', () {
        const response = SyncPushResponse(
          appliedCount: 2,
          serverHlcPacked: hlc,
        );

        expect(response.toJson().keys, unorderedEquals(['applied', 'hlc']));
      });

      test('should_write_counts_including_zero_when_known', () {
        const response = SyncPushResponse(
          appliedCount: 2,
          serverHlcPacked: hlc,
          deferredCount: 0,
          rejectedCount: 3,
        );

        final json = response.toJson();
        expect(json['deferred'], 0, reason: '0 은 "보류 없음" 이라는 판정이다 — 생략하지 않는다');
        expect(json['rejected'], 3);
      });

      test('should_round_trip_counts_through_the_wire', () {
        const response = SyncPushResponse(
          appliedCount: 5,
          serverHlcPacked: hlc,
          deferredCount: 2,
          rejectedCount: 1,
        );

        final decoded = SyncPushResponse.fromJson(_wire(response.toJson()));

        expect(decoded.appliedCount, 5);
        expect(decoded.serverHlcPacked, hlc);
        expect(decoded.deferredCount, 2);
        expect(decoded.rejectedCount, 1);
      });

      test('should_read_absent_counts_as_unknown_not_zero', () {
        final fromOldServer = SyncPushResponse.fromJson(
          _wire({'applied': 4, 'hlc': hlc}),
        );

        expect(fromOldServer.deferredCount, isNull);
        expect(fromOldServer.rejectedCount, isNull);
      });

      test('should_let_deployed_client_decoder_ignore_new_keys', () {
        final fromNewServer = _wire(
          const SyncPushResponse(
            appliedCount: 3,
            serverHlcPacked: hlc,
            deferredCount: 1,
            rejectedCount: 2,
          ).toJson(),
        );

        final legacy = _decodeLikeDeployedClient(fromNewServer);

        expect(legacy.applied, 3);
        expect(legacy.hlc, hlc);
      });

      for (final (name, raw) in <(String, Object?)>[
        ('string', '3'),
        ('negative', -1),
        ('fraction', 1.5),
        ('infinite', double.infinity),
        ('bool', true),
        ('object', {'n': 1}),
      ]) {
        test(
          'should_read_malformed_${name}_count_as_unknown_without_throwing',
          () {
            // 던지면 서버가 이미 적용한 청크가 전송 실패로 보여 재전송 루프가 된다.
            final decoded = SyncPushResponse.fromJson({
              'applied': 1,
              'hlc': hlc,
              'deferred': raw,
              'rejected': raw,
            });

            expect(decoded.deferredCount, isNull);
            expect(decoded.rejectedCount, isNull);
            expect(decoded.appliedCount, 1);
          },
        );
      }

      test(
        'should_accept_integral_double_counts_from_number_only_decoders',
        () {
          final decoded = SyncPushResponse.fromJson({
            'applied': 1,
            'hlc': hlc,
            'deferred': 2.0,
            'rejected': 0.0,
          });

          expect(decoded.deferredCount, 2);
          expect(decoded.rejectedCount, 0);
        },
      );
    },
  );

  group('SyncReport — 회차 집계 (unibook#14034)', () {
    late InMemoryServerSyncStore serverStore;
    late CoSyncServer server;
    late _CountingServerTransport transport;
    var wall = 1000;

    setUp(() {
      wall = 1000;
      serverStore = InMemoryServerSyncStore();
      server = CoSyncServer(
        store: serverStore,
        clock: HlcClock(nodeId: 'server', wallClock: () => wall),
        syncSchema: _schema,
      );
      transport = _CountingServerTransport(InProcessTransport(server));
    });

    CoSyncClient client({
      SyncTransport? transportOverride,
      int maxChangesPerPush = 400,
    }) => CoSyncClient(
      store: InMemoryClientSyncStore(),
      transport: transportOverride ?? transport,
      clock: HlcClock(nodeId: 'A', wallClock: () => wall),
      syncSchema: _schema,
      maxChangesPerPush: maxChangesPerPush,
    );

    test('should_sum_counts_across_chunks_when_server_reports_them', () async {
      final a = client(maxChangesPerPush: 2);
      for (var i = 0; i < 5; i++) {
        await a.upsert('note', 'r$i', {'title': 't$i'});
      }

      final report = await a.sync();

      expect(transport.pushCalls, 3, reason: '청크 [2, 2, 1]');
      expect(report.pushedRows, 5);
      expect(report.deferredCount, 5, reason: '2 + 2 + 1');
      expect(report.rejectedCount, 3, reason: '청크마다 1');
    });

    test(
      'should_report_unknown_when_any_chunk_response_lacks_counts',
      () async {
        transport.omitCountsOnCall = 2;
        final a = client(maxChangesPerPush: 2);
        for (var i = 0; i < 5; i++) {
          await a.upsert('note', 'r$i', {'title': 't$i'});
        }

        final report = await a.sync();

        expect(report.pushedRows, 5);
        expect(
          report.deferredCount,
          isNull,
          reason: '모르는 몫을 0 으로 더하면 "보류 없음" 으로 거짓 보고한다',
        );
        expect(report.rejectedCount, isNull);
      },
    );

    test('should_report_zero_not_unknown_when_nothing_was_pushed', () async {
      final report = await client().sync();

      expect(transport.pushCalls, 0);
      expect(report.deferredCount, 0, reason: '올린 것이 없으면 보류될 것도 없다');
      expect(report.rejectedCount, 0);
    });

    test(
      'should_report_unknown_when_server_has_no_projection_counts',
      () async {
        // 코어 서버 단독은 구체화 계층이 없어 건수를 싣지 않는다.
        final a = client(transportOverride: InProcessTransport(server));
        await a.upsert('note', 'r1', {'title': 't1'});

        final report = await a.sync();

        expect(report.pushedRows, 1);
        expect(report.deferredCount, isNull);
        expect(report.rejectedCount, isNull);
      },
    );

    test('should_combine_reports_and_keep_unknown_as_unknown', () {
      const known = SyncReport(
        pushedRows: 2,
        pulledChanges: 1,
        quarantinedRows: 1,
        deferredCount: 1,
        rejectedCount: 0,
      );
      const unknown = SyncReport(pushedRows: 1, pulledChanges: 0);

      final both = known.combinedWith(known);
      expect(both.pushedRows, 4);
      expect(both.pulledChanges, 2);
      expect(both.quarantinedRows, 2);
      expect(both.deferredCount, 2);
      expect(both.rejectedCount, 0);

      final mixed = known.combinedWith(unknown);
      expect(mixed.pushedRows, 3);
      expect(mixed.deferredCount, isNull);
      expect(mixed.rejectedCount, isNull);
    });
  });
}
