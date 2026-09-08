import 'package:co_offline_sync_client/co_offline_sync_client.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// S7-3 (#12754) — 시드 게이트 공용 헬퍼 (S6-3 게이트의 계약 승계).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late CoSyncDatabase db;
  late ReplicaStore store;

  setUp(() {
    db = CoSyncDatabase(NativeDatabase.memory());
    store = ReplicaStore(db);
  });

  tearDown(() => db.close());

  Future<void> seed(String domain, String id) => store.applyPage(
    domain: domain,
    rows: [
      ReplicaRowChange(rowId: id, dataJson: '{}', serverUpdatedAtMillis: 1),
    ],
    nextCursor: 'c',
  );

  ReplicaPuller offline() => ReplicaPuller(
    store: store,
    domains: {'orders': (_) async => throw Exception('offline')},
  );

  ReplicaPuller online({List<String> rows = const []}) => ReplicaPuller(
    store: store,
    domains: {
      'orders': (_) async => ReplicaPage(
        rows: [
          for (final id in rows)
            ReplicaRowChange(
              rowId: id,
              dataJson: '{}',
              serverUpdatedAtMillis: 1,
            ),
        ],
        nextCursor: 'c',
        hasMore: false,
      ),
    },
  );

  Stream<int> gated(ReplicaPuller puller) => replicaSeededWatch<int>(
    watch: () => store.watchDomainCount('orders'),
    puller: puller,
    domains: const {'orders'},
    isEmpty: (count) => count == 0,
  );

  test('비어 있지 않은 스냅샷은 pull 실패여도 즉시 emit (오프라인 콜드스타트)', () async {
    await seed('orders', '1');
    final first = await gated(
      offline(),
    ).first.timeout(const Duration(seconds: 5));
    expect(first, 1);
  });

  test('서버로 확인되지 않은 빈 값은 emit 하지 않는다', () async {
    final emissions = <int>[];
    final sub = gated(offline()).listen(emissions.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();
    expect(emissions, isEmpty);
  });

  test('빈 값도 pull 성공 후에는 emit 된다 (신규 사용자 온라인)', () async {
    final first = await gated(
      online(),
    ).first.timeout(const Duration(seconds: 5));
    expect(first, 0);
  });

  test('pull 이 반영한 행이 watch 재emit 으로 전달된다', () async {
    final last = await gated(
      online(rows: ['1', '2']),
    ).firstWhere((count) => count == 2).timeout(const Duration(seconds: 5));
    expect(last, 2);
  });

  test('미등록 도메인은 스트림 에러로 드러난다 — 배선 누락이 빈 목록으로 위장되지 않는다', () async {
    final stream = replicaSeededWatch<int>(
      watch: () => store.watchDomainCount('ghost'),
      puller: ReplicaPuller(store: store, domains: const {}),
      domains: const {'ghost'},
      isEmpty: (count) => count == 0,
    );
    await expectLater(stream.first, throwsArgumentError);
  });
}
