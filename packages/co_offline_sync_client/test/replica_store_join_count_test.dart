import 'package:co_offline_sync_client/co_offline_sync_client.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// S7-3 (#12754) — 파생 카운트·도메인 조인 watch.
///
/// - `watchDomainCount`: 활성 행 수, tombstone 제외, upsert 마다 재emit
/// - `watchDomainJoin`: LEFT OUTER JOIN 이라 짝 없는 행도 남고, 어느 쪽
///   도메인 변경에도 한 스트림이 재emit 된다
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late CoSyncDatabase db;
  late ReplicaStore store;

  setUp(() {
    db = CoSyncDatabase(NativeDatabase.memory());
    store = ReplicaStore(db);
  });

  tearDown(() => db.close());

  Future<void> apply(
    String domain,
    List<(String, String, bool)> rows, {
    String cursor = 'c',
  }) => store.applyPage(
    domain: domain,
    rows: [
      for (final (id, data, deleted) in rows)
        ReplicaRowChange(
          rowId: id,
          dataJson: data,
          serverUpdatedAtMillis: int.parse(id),
          deleted: deleted,
        ),
    ],
    nextCursor: cursor,
  );

  group('watchDomainCount', () {
    test('활성 행만 세고, tombstone 은 빠지며, 반영마다 재emit 된다', () async {
      final counts = <int>[];
      final sub = store.watchDomainCount('orders').listen(counts.add);
      await Future<void>.delayed(Duration.zero);

      await apply('orders', [('1', '{}', false), ('2', '{}', false)]);
      await Future<void>.delayed(Duration.zero);
      await apply('orders', [('2', '{}', true), ('3', '{}', false)]);
      await Future<void>.delayed(Duration.zero);
      // 다른 도메인은 이 카운트에 영향이 없다.
      await apply('meta', [('9', '{}', false)]);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(counts.first, 0, reason: '구독 즉시 현재 값(0)이 나온다');
      expect(counts.last, 2, reason: '1·3 활성, 2 tombstone');
      expect(counts, contains(2));
    });
  });

  group('watchDomainJoin', () {
    test('같은 rowId 로 붙고, 짝 없는 왼쪽 행은 right=null 로 남는다', () async {
      await apply('likes', [
        ('10', '{"l":1}', false),
        ('11', '{"l":2}', false),
      ]);
      await apply('meta', [('10', '{"m":1}', false)]);

      final rows = await store
          .watchDomainJoin(left: 'likes', right: 'meta')
          .first;

      final byId = {for (final row in rows) row.left.rowId: row};
      expect(byId.keys, containsAll(['10', '11']));
      expect(byId['10']?.right?.dataJson, '{"m":1}');
      expect(byId['11']?.right, isNull, reason: 'LEFT OUTER — 메타 미도착 과도기');
    });

    test('오른쪽 도메인의 tombstone 은 짝에서 빠지고, 왼쪽 tombstone 은 행이 빠진다', () async {
      await apply('likes', [('10', '{}', false), ('11', '{}', false)]);
      await apply('meta', [('10', '{}', true), ('11', '{}', false)]);

      final rows = await store
          .watchDomainJoin(left: 'likes', right: 'meta')
          .first;
      final byId = {for (final row in rows) row.left.rowId: row};
      expect(byId['10']?.right, isNull, reason: '메타 tombstone 은 짝이 아니다');
      expect(byId['11']?.right, isNotNull);

      await apply('likes', [('11', '{}', true)]);
      final after = await store
          .watchDomainJoin(left: 'likes', right: 'meta')
          .first;
      expect(after.map((r) => r.left.rowId), [
        '10',
      ], reason: '해제된 찜은 행 자체가 빠진다');
    });

    test('어느 쪽 도메인이 바뀌어도 같은 스트림이 재emit 된다', () async {
      final emissions = <int>[];
      final sub = store
          .watchDomainJoin(left: 'likes', right: 'meta')
          .listen((rows) => emissions.add(rows.length));
      await Future<void>.delayed(Duration.zero);

      await apply('likes', [('10', '{}', false)]);
      await Future<void>.delayed(Duration.zero);
      final afterLeft = emissions.length;
      await apply('meta', [('10', '{}', false)]);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(afterLeft, greaterThan(1), reason: '왼쪽 반영 → 재emit');
      expect(
        emissions.length,
        greaterThan(afterLeft),
        reason: '오른쪽(메타) 반영만으로도 재emit — 두 watch 를 합칠 필요가 없다',
      );
    });
  });
}
