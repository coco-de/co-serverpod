import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_offline_sync_client/co_offline_sync_client.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

Hlc _hlc(int millis, [String node = 'A']) => Hlc(millis, 0, node);

RowState _state(String rowId, Map<String, (Object?, Hlc)> fields) => RowState(
  rowId: rowId,
  fields: {
    for (final e in fields.entries) e.key: FieldValue(e.value.$1, e.value.$2),
  },
);

RowState _tombstone(String rowId, int millis) =>
    _state(rowId, {kDeletedField: (true, _hlc(millis))});

/// S3-9b (#12963) — co_sync 논리 테이블 ⋈ read-only replica 조인 watch.
///
/// - LEFT OUTER: replica 짝이 없는 좌변 행은 `replica: null` 로 **남는다**
///   (오프라인 신규 행의 정상 상태 — 빼지 않는 것이 API 의 존재 이유)
/// - 좌변 tombstone 은 행이 빠지고, replica tombstone 은 삭제 상태를 보존한다
/// - 다른 논리 테이블·다른 replica 도메인은 섞이지 않는다
/// - 어느 쪽 테이블이 바뀌어도 **한 스트림**이 재emit 된다
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late CoSyncDatabase db;
  late DriftClientSyncStore store;
  late ReplicaStore replica;

  setUp(() {
    db = CoSyncDatabase(NativeDatabase.memory());
    store = DriftClientSyncStore(db);
    replica = ReplicaStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> put(String table, RowState state) =>
      store.putRow(table, state, origin: ChangeOrigin.local, pending: false);

  Future<void> meta(String domain, List<(String, String, bool)> rows) =>
      replica.applyPage(
        domain: domain,
        rows: [
          for (final (id, data, deleted) in rows)
            ReplicaRowChange(
              rowId: id,
              dataJson: data,
              serverUpdatedAtMillis: 1,
              deleted: deleted,
            ),
        ],
        nextCursor: 'c',
      );

  Stream<List<LogicalTableReplicaJoinedRow>> watch() =>
      store.watchLogicalTableJoinReplica(
        'book_like',
        replicaDomain: 'book_meta',
        coalesceWindow: Duration.zero,
      );

  test('LEFT OUTER — replica 짝이 없는 행은 replica:null 로 남는다', () async {
    await put('book_like', _state('10', {'bookId': (10, _hlc(1))}));
    await put('book_like', _state('11', {'bookId': (11, _hlc(2))}));
    await meta('book_meta', [('10', '{"m":10}', false)]);

    final rows = await watch().first;

    final byId = {for (final row in rows) row.state.rowId: row};
    expect(byId.keys, containsAll(['10', '11']));
    expect(byId['10']?.replica?.dataJson, '{"m":10}');
    expect(
      byId['11']?.replica,
      isNull,
      reason: '오프라인에서 만든 행은 메타가 없는 것이 정상 — 빼지 않는다',
    );
    expect(
      byId['11']?.state.valuesView()['bookId'],
      11,
      reason: '좌변 상태는 디코드된 RowState 로 온다',
    );
  });

  test('좌변 tombstone 은 행이 빠지고, replica tombstone 은 삭제 상태를 보존한다', () async {
    await put('book_like', _state('10', {'bookId': (10, _hlc(1))}));
    await put('book_like', _state('11', {'bookId': (11, _hlc(1))}));
    await put('book_like', _tombstone('12', 1));
    await meta('book_meta', [
      ('10', '{}', true),
      ('11', '{}', false),
      ('12', '{}', false),
    ]);

    final rows = await watch().first;
    final byId = {for (final row in rows) row.state.rowId: row};

    expect(byId.keys, unorderedEquals(['10', '11']), reason: '12 는 해제된 찜');
    expect(byId['10']?.replica?.deleted, isTrue, reason: '미수신 null 과 구분한다');
    expect(byId['11']?.replica, isNotNull);
  });

  test('다른 논리 테이블·다른 replica 도메인은 섞이지 않는다', () async {
    await put('book_like', _state('10', {'bookId': (10, _hlc(1))}));
    await put('reading_progress', _state('10', {'bookId': (10, _hlc(1))}));
    await meta('book_order_summary', [('10', '{"other":1}', false)]);

    final rows = await watch().first;

    expect(rows, hasLength(1), reason: 'reading_progress 행은 좌변이 아니다');
    expect(
      rows.single.replica,
      isNull,
      reason: '같은 rowId 라도 다른 replica 도메인은 짝이 아니다',
    );
  });

  test('어느 쪽 테이블이 바뀌어도 한 스트림이 재emit 된다', () async {
    final emissions = <int>[];
    final sub = watch().listen(
      (rows) => emissions.add(rows.where((r) => r.replica != null).length),
    );
    await pumpEventQueue();

    await put('book_like', _state('10', {'bookId': (10, _hlc(1))}));
    await pumpEventQueue();
    final afterLeft = emissions.length;
    expect(emissions.last, 0, reason: '좌변만 있고 메타는 아직 없다');

    await meta('book_meta', [('10', '{}', false)]);
    await pumpEventQueue();
    await sub.cancel();

    expect(afterLeft, greaterThan(1), reason: '좌변 반영 → 재emit');
    expect(
      emissions.length,
      greaterThan(afterLeft),
      reason: 'replica 반영만으로도 재emit — 두 watch 를 소비측에서 합칠 필요가 없다',
    );
    expect(emissions.last, 1, reason: '메타 도착으로 짝이 채워졌다');
  });

  test('clearAll(로그아웃 wipe)이 빈 목록 emit 으로 자연 전달된다', () async {
    await put('book_like', _state('10', {'bookId': (10, _hlc(1))}));
    await meta('book_meta', [('10', '{}', false)]);
    final emissions = <int>[];
    final sub = watch().listen((rows) => emissions.add(rows.length));
    await pumpEventQueue();
    expect(emissions.last, 1);

    await store.clearAll();
    await pumpEventQueue();
    await sub.cancel();

    expect(emissions.last, 0);
  });

  test('stateJson 이 JSON 그대로 디코드된다 — 필드·HLC 보존', () async {
    final state = _state('7', {
      'bookId': (7, _hlc(5, 'B')),
      'createdAt': (1735689600000, _hlc(6, 'B')),
    });
    await put('book_like', state);

    final rows = await watch().first;

    final decoded = rows.single.state;
    expect(jsonEncode(decoded.toJson()), jsonEncode(state.toJson()));
    expect(decoded.maxHlc, _hlc(6, 'B'));
  });
}
