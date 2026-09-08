import 'dart:async';
import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_offline_sync_client/src/drift/co_sync_database.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

/// [DriftClientSyncStore.watchLogicalTableJoinReplica] 의 행 — 논리 테이블의
/// 활성 행 상태와, 같은 rowId 의 replica 행 (미수신이면 `null`).
/// replica tombstone 도 보존하므로 소비측이 삭제와 미수신을 구분할 수 있다.
///
/// `replica` 의 `dataJson` 해석은 소비측 소관이다 — 이 패키지는 도메인을
/// 모른다 (`book_replica` 의 `watchLocalFirstLikedBooks` 가 첫 소비처).
typedef LogicalTableReplicaJoinedRow = ({
  RowState state,
  CoReplicaRowData? replica,
});

/// `ClientSyncStore` 의 drift 구현 — 행 상태·pending·커서를 SQLite 에 영속.
///
/// 계약 (코어 `ClientSyncStore` dartdoc 기준):
/// - 병합 판단은 코어(`CoSyncClient`)가 한다. 이 구현은 영속·부기·통지만.
/// - `clearPending(upTo)` 는 현재 행 maxHlc 가 `upTo` **이하일 때만** 해제 —
///   전송 중 로컬 편집을 보존한다. packed HLC 가 고정폭 사전순이라 SQL
///   문자열 비교로 판정한다.
/// - `putRow(pending: false)`(원격 병합)는 기존 pending 플래그·스냅샷을
///   **건드리지 않는다**.
///
/// 계정 전환 시 `clearAll` 을 호출해 이전 계정의 동기화 상태(행·pending·커서)
/// 노출을 막는 배선은 앱 부트스트랩 책임이다 (S3-3, `CacheRegistry.clearAll`
/// 로그아웃 선례 kobic#6520 과 동일 사유).
class DriftClientSyncStore implements ClientSyncStore {
  /// `db` 는 보통 `CoSyncDatabase.create()`, 테스트는
  /// `CoSyncDatabase(NativeDatabase.memory())`.
  ///
  /// [tombstonePolicy] 는 `deleted` 물질화 컬럼(S7-2, #12753)의 판정
  /// 기준이다 — **`CoSyncClient` 에 배선한 정책과 같아야 한다** (양쪽 다
  /// 코어 기본값 `deleteWins`). 갈리면 화면(watch)과 읽기 뷰(`readRow`)가
  /// 같은 행을 다르게 판정한다.
  DriftClientSyncStore(
    this._db, {
    TombstonePolicy tombstonePolicy = TombstonePolicy.deleteWins,
  }) : _tombstonePolicy = tombstonePolicy;

  static const String _cursorKey = 'pull_cursor';
  static const String _nodeIdKey = 'node_id';

  final CoSyncDatabase _db;
  final TombstonePolicy _tombstonePolicy;
  final StreamController<TableChange> _changes =
      StreamController<TableChange>.broadcast(sync: true);

  /// 계정에 귀속된 앱 로컬 메타데이터. sync cursor/nodeId와 키를 격리한다.
  /// 서버로 전송하지 않으며 [clearAll]의 계정 wipe에 함께 참여한다.
  Future<String?> readLocalMetadata(String key) async {
    final metadata = _db.coSyncMeta;
    final row = await (_db.select(
      metadata,
    )..where((t) => t.metaKey.equals('local:$key'))).getSingleOrNull();
    return row?.metaValue;
  }

  /// 로컬 복구 보관함 등의 namespace 조회. SQL 와일드카드는 문자로 처리한다.
  Future<Map<String, String>> readLocalMetadataWithPrefix(String prefix) async {
    final escaped = prefix
        .replaceAll('!', '!!')
        .replaceAll('%', '!%')
        .replaceAll('_', '!_');
    final metadata = _db.coSyncMeta;
    final rows = await (_db.select(
      metadata,
    )..where((t) => t.metaKey.like('local:$escaped%', escapeChar: '!'))).get();
    return {for (final row in rows) row.metaKey.substring(6): row.metaValue};
  }

  /// `.bin`의 원래 캔버스 등 복구 근거를 프로세스 재시작에도 보존한다.
  Future<void> writeLocalMetadata(String key, String value) async {
    final metadata = _db.coSyncMeta;
    await _db
        .into(metadata)
        .insertOnConflictUpdate(
          CoSyncMetaCompanion.insert(metaKey: 'local:$key', metaValue: value),
        );
  }

  /// 행 단위 변경 통지 (코어 계약).
  ///
  /// ⚠️ **화면 소비의 정본이 아니다** (S7-2, #12753). 이 스트림은 재생·버퍼
  /// 없는 broadcast 라 ① 구독 이전 이벤트가 유실되고 ② 초기 스냅샷이 없고
  /// ③ [clearAll](로그아웃 wipe)이 **아무것도 emit 하지 않는다**. 화면은
  /// [watchLogicalTable]/[watchLogicalTableCount](drift 쿼리 watch — 구독
  /// 즉시 스냅샷 + wipe 자연 발화)를 구독하고, 이 스트림은 동기화 내부와
  /// 세밀한 무효화 신호(table/rowId 선필터)에만 쓴다.
  @override
  Stream<TableChange> get changes => _changes.stream;

  Future<CoSyncRowData?> _selectRow(String table, String rowId) =>
      (_db.select(
            _db.coSyncRows,
          )..where((t) => t.logicalTable.equals(table) & t.rowId.equals(rowId)))
          .getSingleOrNull();

  @override
  Future<RowState?> getRow(String table, String rowId) async {
    final row = await _selectRow(table, rowId);
    if (row == null) return null;
    return RowState.fromJson(jsonDecode(row.stateJson) as Map<String, Object?>);
  }

  @override
  Future<void> putRow(
    String table,
    RowState state, {
    required ChangeOrigin origin,
    required bool pending,
  }) async {
    final packedMax = state.maxHlc.pack();
    await _db.transaction(() async {
      final existing = await _selectRow(table, state.rowId);
      // 원격 병합(pending=false)은 기존 pending 부기를 보존한다.
      final keepPending = pending || (existing?.pending ?? false);
      final snapshot = pending ? packedMax : existing?.pendingSnapshotHlc;
      await _db
          .into(_db.coSyncRows)
          .insertOnConflictUpdate(
            CoSyncRowsCompanion.insert(
              logicalTable: table,
              rowId: state.rowId,
              stateJson: jsonEncode(state.toJson()),
              maxHlc: packedMax,
              pending: Value(keepPending),
              pendingSnapshotHlc: Value(snapshot),
              // tombstone 물질화 (S7-2) — 논리 테이블 watch/COUNT 가 JSON
              // 디코드 없이 SQL 로 거를 수 있게 저장 시점에 동기한다.
              deleted: Value(state.isDeleted(_tombstonePolicy)),
            ),
          );
    });
    _changes.add(TableChange(table: table, rowId: state.rowId, origin: origin));
  }

  @override
  Future<List<PendingRow>> pendingRows() async {
    final rows = await (_db.select(
      _db.coSyncRows,
    )..where((t) => t.pending.equals(true))).get();
    return [
      for (final row in rows)
        PendingRow(
          table: row.logicalTable,
          rowId: row.rowId,
          snapshotHlc: Hlc.parse(row.pendingSnapshotHlc ?? row.maxHlc),
        ),
    ];
  }

  @override
  Future<void> clearPending(String table, String rowId, Hlc upTo) async {
    // packed HLC 는 고정폭 사전순 == HLC 순서 — 문자열 비교로 가드한다.
    await (_db.update(_db.coSyncRows)..where(
          (t) =>
              t.logicalTable.equals(table) &
              t.rowId.equals(rowId) &
              t.maxHlc.isSmallerOrEqualValue(upTo.pack()),
        ))
        .write(
          const CoSyncRowsCompanion(
            pending: Value(false),
            pendingSnapshotHlc: Value(null),
          ),
        );
  }

  @override
  Future<Hlc?> maxHlc() async {
    // packed HLC 는 고정폭 사전순 == HLC 순서 — SQL 문자열 max 로 판정한다.
    final query = _db.selectOnly(_db.coSyncRows)
      ..addColumns([_db.coSyncRows.maxHlc.max()]);
    final row = await query.getSingleOrNull();
    final packed = row?.read(_db.coSyncRows.maxHlc.max());
    return packed == null ? null : Hlc.parse(packed);
  }

  @override
  Future<String?> loadCursor() async {
    final row = await (_db.select(
      _db.coSyncMeta,
    )..where((t) => t.metaKey.equals(_cursorKey))).getSingleOrNull();
    return row?.metaValue;
  }

  @override
  Future<void> saveCursor(String cursor) => _db
      .into(_db.coSyncMeta)
      .insertOnConflictUpdate(
        CoSyncMetaCompanion.insert(metaKey: _cursorKey, metaValue: cursor),
      );

  /// 설치 단위 HLC nodeId — 없으면 UUID v4 를 생성해 영속한다.
  ///
  /// 로그아웃 wipe(`clearAll`/CacheRegistry) 시 함께 삭제되어 다음 로그인에서
  /// 새 nodeId 가 발급된다 — 계정 간 스탬프 상관을 남기지 않는 의도된 동작.
  Future<String> ensureNodeId() async {
    final row = await (_db.select(
      _db.coSyncMeta,
    )..where((t) => t.metaKey.equals(_nodeIdKey))).getSingleOrNull();
    if (row != null) return row.metaValue;
    final nodeId = const Uuid().v4();
    await _db
        .into(_db.coSyncMeta)
        .insertOnConflictUpdate(
          CoSyncMetaCompanion.insert(metaKey: _nodeIdKey, metaValue: nodeId),
        );
    return nodeId;
  }

  // ─── 논리 테이블 단위 소비 API (S7-2, #12753) ───
  //
  // 화면(repository watch)의 정본 소비 경로다 — `ReplicaStore.watchDomain`
  // 과 같은 drift 쿼리 watch 라 ① 구독 즉시 스냅샷 ② [clearAll](로그아웃
  // wipe)이 DELETE 로 자연 발화한다 — `changes` 스트림의 세 공백(유실·
  // 무스냅샷·wipe 무통지)이 구조적으로 없다. ③ 버스트(pull 은 행마다 별도
  // putRow 트랜잭션 — drift 자연 코얼레싱 **없음**, 실측 50행=50회)는
  // `coalesceWindow` 스로틀이 접는다.

  Expression<bool> _activeIn($CoSyncRowsTable t, String table) =>
      t.logicalTable.equals(table) & t.deleted.equals(false);

  /// [table] 의 활성(비-tombstone) 행 상태 목록을 watch 한다.
  ///
  /// 판정은 물질화 `deleted` 컬럼(스토어의 [TombstonePolicy] 기준) — 정본
  /// 판정과의 정합은 `putRow` 가 저장 시점에 보장한다.
  ///
  /// [coalesceWindow] 는 버스트 코얼레싱 창이다 — pull 은 행마다 별도
  /// `putRow` 트랜잭션이라 drift watch 가 **행 수만큼** 재실행된다(실측:
  /// 50행 = 50회). 첫 변경은 즉시 emit 하고, 이후 창 안의 변경은 최신
  /// 1회로 접는다 (leading + trailing-latest). 테스트처럼 결정적 타이밍이
  /// 필요하면 `Duration.zero` 를 넘긴다.
  Stream<List<RowState>> watchLogicalTable(
    String table, {
    Duration coalesceWindow = const Duration(milliseconds: 100),
  }) => _throttleTrailing(
    (_db.select(_db.coSyncRows)
          ..where((t) => _activeIn(t, table))
          ..orderBy([(t) => OrderingTerm.asc(t.rowId)]))
        .watch()
        .map(
          (rows) => [
            for (final row in rows)
              RowState.fromJson(
                jsonDecode(row.stateJson) as Map<String, Object?>,
              ),
          ],
        ),
    coalesceWindow,
  );

  /// [table] 의 **tombstone** 행 상태 목록 1회 조회 (S3-12 #12846).
  ///
  /// [getLogicalTable] 은 `deleted = false` 만 준다 — 화면이 지운 것을 그리면
  /// 안 되기 때문이다. 그런데 **로컬 스냅샷과 행을 병합**하는 경로는 "지운
  /// 것" 을 알아야 한다: 다른 단말이 지운 요소가 이 단말의 낡은 스냅샷에
  /// 남아 있을 때, tombstone 을 못 보면 그것을 "아직 안 올라간 로컬 추가분"
  /// 으로 오인해 **되살린다**. 삭제가 두 번째 단말에서 영영 확정되지 않는다.
  Future<List<RowState>> getLogicalTableTombstones(String table) async {
    final rows =
        await (_db.select(_db.coSyncRows)
              ..where(
                (t) => t.logicalTable.equals(table) & t.deleted.equals(true),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.rowId)]))
            .get();
    return [
      for (final row in rows)
        RowState.fromJson(jsonDecode(row.stateJson) as Map<String, Object?>),
    ];
  }

  /// [table] 의 활성 행 상태 목록 1회 조회.
  Future<List<RowState>> getLogicalTable(String table) async {
    final rows =
        await (_db.select(_db.coSyncRows)
              ..where((t) => _activeIn(t, table))
              ..orderBy([(t) => OrderingTerm.asc(t.rowId)]))
            .get();
    return [
      for (final row in rows)
        RowState.fromJson(jsonDecode(row.stateJson) as Map<String, Object?>),
    ];
  }

  /// [table] 의 활성 행 수를 watch 한다 — 파생 집계(S7-3 로컬 COUNT)의
  /// 원천. JSON 디코드 없이 SQL COUNT 로 센다.
  ///
  /// [coalesceWindow] 계약은 [watchLogicalTable] 과 같다.
  Stream<int> watchLogicalTableCount(
    String table, {
    Duration coalesceWindow = const Duration(milliseconds: 100),
  }) {
    final countExp = _db.coSyncRows.rowId.count();
    final query = _db.selectOnly(_db.coSyncRows)
      ..addColumns([countExp])
      ..where(_activeIn(_db.coSyncRows, table));
    return _throttleTrailing(
      query.watchSingle().map((row) => row.read(countExp) ?? 0),
      coalesceWindow,
    );
  }

  /// leading + trailing-latest 스로틀 — 첫 이벤트는 즉시, 창 안의 후속
  /// 이벤트는 최신 1건으로 접어 창 경과 시 emit 한다. 값 유실이 없고
  /// (마지막 상태는 반드시 도착) 지연 상한이 [window] 다.
  static Stream<T> _throttleTrailing<T>(Stream<T> source, Duration window) {
    if (window == Duration.zero) return source;
    late StreamController<T> controller;
    StreamSubscription<T>? subscription;
    Timer? timer;
    T? pendingValue;
    var hasPending = false;

    void onWindowEnd() {
      timer = null;
      if (hasPending) {
        hasPending = false;
        final value = pendingValue as T;
        pendingValue = null;
        controller.add(value);
        timer = Timer(window, onWindowEnd);
      }
    }

    controller = StreamController<T>(
      onListen: () {
        subscription = source.listen(
          (value) {
            if (timer == null) {
              controller.add(value);
              timer = Timer(window, onWindowEnd);
            } else {
              pendingValue = value;
              hasPending = true;
            }
          },
          onError: controller.addError,
          onDone: () {
            // 잔여 최신값을 유실 없이 흘려보내고 닫는다.
            if (hasPending) {
              hasPending = false;
              controller.add(pendingValue as T);
            }
            unawaited(controller.close());
          },
        );
      },
      onCancel: () async {
        timer?.cancel();
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// [table] 의 활성 행 수 1회 조회.
  Future<int> countLogicalTable(String table) async {
    final countExp = _db.coSyncRows.rowId.count();
    final query = _db.selectOnly(_db.coSyncRows)
      ..addColumns([countExp])
      ..where(_activeIn(_db.coSyncRows, table));
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// [table] 의 활성 행마다 **같은 rowId** 의 [replicaDomain] replica
  /// 행을 붙여 watch 한다 (S3-9b #12963) — co_sync 논리 테이블 ⋈ read-only
  /// replica.
  ///
  /// `ReplicaStore.watchDomainJoin`(replica ⋈ replica)의 자매본이되 좌변이
  /// **CRDT 축**이다. LEFT OUTER JOIN 이라 짝이 없어도 좌변 행이 남는다 —
  /// 오프라인에서 만든 행은 조인 상대(서버 pull 복제본)가 아직 없는 것이
  /// 정상이며, 그 행을 **빼지 않고 `replica: null` 로 드러내는 것**이 이 API 의
  /// 존재 이유다(소비측이 플레이스홀더로 자리를 표시하고 pull 을 시동한다).
  ///
  /// 한 쿼리라 **두 테이블 어느 쪽 변경에도 한 번에 재emit** 된다 — 두 watch
  /// 를 소비측에서 합치면 구독 시점·emit 순서 경합이 생기고, 한쪽만 바뀐
  /// 프레임에 다른 쪽 stale 값이 섞인다(swr-pattern §11-3). 좌변 tombstone 은
  /// 물질화 `deleted` 컬럼으로 제외한다. replica tombstone 은 보존한다 —
  /// 삭제된 도서를 메타 미수신 플레이스홀더로 되살리지 않도록 소비측이
  /// `replica.deleted` 를 확인한다.
  ///
  /// 정렬은 [watchLogicalTable] 과 같은 rowId 오름차순 — 의미 있는 정렬
  /// (찜 시각 등)은 좌변 상태를 디코드해야 하므로 소비측이 한다. 행마다
  /// `stateJson` 을 JSON 디코드하므로 비용은 행 수에 선형이다(`CoSyncRows` 에
  /// 정렬축 컬럼이 없다 — S3-9b R2 실측은 `book_replica` 테스트 참조).
  ///
  /// [coalesceWindow] 계약은 [watchLogicalTable] 과 같다.
  Stream<List<LogicalTableReplicaJoinedRow>> watchLogicalTableJoinReplica(
    String table, {
    required String replicaDomain,
    Duration coalesceWindow = const Duration(milliseconds: 100),
  }) {
    final rows = _db.coSyncRows;
    final replica = _db.alias(_db.coReplicaRows, 'replica_rows');
    final query =
        _db.select(rows).join([
            leftOuterJoin(
              replica,
              replica.rowId.equalsExp(rows.rowId) &
                  replica.domain.equals(replicaDomain),
            ),
          ])
          ..where(_activeIn(rows, table))
          ..orderBy([OrderingTerm.asc(rows.rowId)]);
    return _throttleTrailing(
      query.watch().map(
        (results) => [
          for (final result in results)
            (
              state: RowState.fromJson(
                jsonDecode(result.readTable(rows).stateJson)
                    as Map<String, Object?>,
              ),
              replica: result.readTableOrNull(replica),
            ),
        ],
      ),
      coalesceWindow,
    );
  }

  /// 동기화 상태 전체 삭제 (행·pending·커서) — 계정 전환/로그아웃 배선용.
  ///
  /// ⚠️ `changes` 로는 통지되지 않는다 — 화면은 [watchLogicalTable] 계열을
  /// 구독해야 wipe 가 빈 목록 emit 으로 자연 전달된다 (S7-2 계약).
  Future<void> clearAll() async {
    await _db.transaction(() async {
      await _db.delete(_db.coSyncRows).go();
      await _db.delete(_db.coSyncMeta).go();
    });
  }

  /// 스트림·DB 정리 (테스트 teardown 용).
  Future<void> dispose() async {
    await _changes.close();
    await _db.close();
  }
}
