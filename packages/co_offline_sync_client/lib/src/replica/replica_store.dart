import 'package:co_offline_sync_client/src/drift/co_sync_database.dart';
import 'package:drift/drift.dart';

/// 서버가 내려준 replica 행 변경 1건 (pull 응답의 단위).
class ReplicaRowChange {
  /// 기본 생성자.
  const ReplicaRowChange({
    required this.rowId,
    required this.dataJson,
    required this.serverUpdatedAtMillis,
    this.deleted = false,
  });

  /// 행 id (도메인 내 고유).
  final String rowId;

  /// 서버 상태 JSON (thin projection).
  final String dataJson;

  /// 서버 `updatedAt` (epoch millis, UTC).
  final int serverUpdatedAtMillis;

  /// 서버측 삭제(soft-delete) 여부.
  final bool deleted;
}

/// [ReplicaStore.watchDomainJoin] 의 행 — `left` 도메인 행과 같은 rowId 의
/// `right` 도메인 행 (짝이 없으면 `null`).
typedef ReplicaJoinedRow = ({CoReplicaRowData left, CoReplicaRowData? right});

/// read-only replica 저장소 (S6-1, #12720).
///
/// 단방향 pull 복제본의 영속·조회·**반응형 watch** 를 담당한다. 쓰기는
/// `applyPage` 하나뿐이며(서버 응답 반영), 도메인 로직의 로컬 쓰기는 없다 —
/// 그건 CRDT 축(`DriftClientSyncStore`) 소관이다.
///
/// watch 는 drift **쿼리 단위** 스트림이다 — 같은 트랜잭션의 upsert 가
/// 자동으로 broadcast 되므로 S7 반응형 계층이 별도 통지 없이 구독한다
/// (코어 `TableChange` 수동 broadcast 와 달리 구독 시점·수명 경합이 없다).
class ReplicaStore {
  /// 인자는 앱 전역 `CoSyncDatabase` (로그아웃 wipe 는 CacheRegistry 상속).
  ReplicaStore(this._db);

  final CoSyncDatabase _db;

  /// [domain] 의 활성 행 목록을 watch 한다 (삭제 행 제외,
  /// `serverUpdatedAtMillis` 내림차순).
  ///
  /// 구독 즉시 현재 스냅샷이 1회 emit 되고, 이후 [applyPage] 반영마다
  /// 자동 재emit 된다.
  Stream<List<CoReplicaRowData>> watchDomain(String domain) =>
      (_db.select(_db.coReplicaRows)
            ..where((t) => t.domain.equals(domain) & t.deleted.equals(false))
            ..orderBy([(t) => OrderingTerm.desc(t.serverUpdatedAtMillis)]))
          .watch();

  /// [domain] 의 활성 행 목록 1회 조회.
  Future<List<CoReplicaRowData>> getDomain(String domain) =>
      (_db.select(_db.coReplicaRows)
            ..where((t) => t.domain.equals(domain) & t.deleted.equals(false))
            ..orderBy([(t) => OrderingTerm.desc(t.serverUpdatedAtMillis)]))
          .get();

  /// 단일 행 watch (삭제되면 `null`).
  Stream<CoReplicaRowData?> watchRow(String domain, String rowId) =>
      (_db.select(_db.coReplicaRows)..where(
            (t) =>
                t.domain.equals(domain) &
                t.rowId.equals(rowId) &
                t.deleted.equals(false),
          ))
          .watchSingleOrNull();

  /// 단일 행 1회 조회 (없거나 삭제면 `null`) — lookup 성 소비의 정본
  /// (S6-3: 찜 목록 Book 변환의 replica 폴백 등).
  Future<CoReplicaRowData?> getRow(String domain, String rowId) =>
      (_db.select(_db.coReplicaRows)..where(
            (t) =>
                t.domain.equals(domain) &
                t.rowId.equals(rowId) &
                t.deleted.equals(false),
          ))
          .getSingleOrNull();

  /// [domain] 의 활성 행 수를 watch 한다 (S7-3, #12754) — 파생 카운트의 정본
  /// (구매 도서 수 = `book_order_summary` 행 수 등).
  ///
  /// 행을 디코드하지 않는 SQL `COUNT` 라 목록 watch 보다 싸고, [applyPage]
  /// 반영마다 자동 재emit 된다. 구독 즉시 현재 값이 1회 emit 된다.
  Stream<int> watchDomainCount(String domain) {
    final count = _db.coReplicaRows.rowId.count();
    final query = _db.selectOnly(_db.coReplicaRows)
      ..addColumns([count])
      ..where(
        _db.coReplicaRows.domain.equals(domain) &
            _db.coReplicaRows.deleted.equals(false),
      );
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  /// [left] 도메인의 활성 행마다 **같은 rowId** 의 [right] 활성 행을 붙여
  /// watch 한다 (S7-3, #12754). LEFT OUTER JOIN — 짝이 없으면 `right` 가
  /// `null` 이다 (pull 순서상 한쪽이 먼저 도착한 과도기).
  ///
  /// 한 쿼리라 **두 도메인 어느 쪽 변경에도 한 번에 재emit** 된다 — 두 watch
  /// 를 소비측에서 합치면 구독 시점·emit 순서 경합이 생기고, 한쪽만 바뀐
  /// 프레임에 다른 쪽 stale 값이 섞인다. 정렬은 [left] 의
  /// `serverUpdatedAtMillis` 내림차순 — 의미 있는 정렬(찜 시각 등)은
  /// 소비측이 dataJson 으로 다시 한다.
  Stream<List<ReplicaJoinedRow>> watchDomainJoin({
    required String left,
    required String right,
  }) {
    final leftRows = _db.coReplicaRows;
    final rightRows = _db.alias(_db.coReplicaRows, 'right_rows');
    final query =
        _db.select(leftRows).join([
            leftOuterJoin(
              rightRows,
              rightRows.rowId.equalsExp(leftRows.rowId) &
                  rightRows.domain.equals(right) &
                  rightRows.deleted.equals(false),
            ),
          ])
          ..where(leftRows.domain.equals(left) & leftRows.deleted.equals(false))
          ..orderBy([OrderingTerm.desc(leftRows.serverUpdatedAtMillis)]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          (
            left: row.readTable(leftRows),
            right: row.readTableOrNull(rightRows),
          ),
      ],
    );
  }

  /// pull 응답 한 페이지를 반영한다 — **행 upsert + 커서 전진이 한
  /// 트랜잭션**이라, 중간 실패 시 커서가 전진하지 않아 다음 pull 이 같은
  /// 페이지를 다시 받는다 (upsert 멱등이라 재적용 무해).
  Future<void> applyPage({
    required String domain,
    required List<ReplicaRowChange> rows,
    required String nextCursor,
  }) => _db.transaction(() async {
    for (final row in rows) {
      await _db
          .into(_db.coReplicaRows)
          .insertOnConflictUpdate(
            CoReplicaRowsCompanion.insert(
              domain: domain,
              rowId: row.rowId,
              dataJson: row.dataJson,
              serverUpdatedAtMillis: row.serverUpdatedAtMillis,
              deleted: Value(row.deleted),
            ),
          );
    }
    await _db
        .into(_db.coReplicaCursors)
        .insertOnConflictUpdate(
          CoReplicaCursorsCompanion.insert(domain: domain, cursor: nextCursor),
        );
  });

  /// [domain] 의 저장된 커서 (없으면 `null` — 최초 pull).
  Future<String?> loadCursor(String domain) async {
    final row = await (_db.select(
      _db.coReplicaCursors,
    )..where((t) => t.domain.equals(domain))).getSingleOrNull();
    return row?.cursor;
  }

  /// [domain] 의 행·커서를 지운다 (전량 재수화가 필요할 때 — 예: 서버
  /// projection 계약 변경).
  Future<void> clearDomain(String domain) => _db.transaction(() async {
    await (_db.delete(
      _db.coReplicaRows,
    )..where((t) => t.domain.equals(domain))).go();
    await (_db.delete(
      _db.coReplicaCursors,
    )..where((t) => t.domain.equals(domain))).go();
  });
}
