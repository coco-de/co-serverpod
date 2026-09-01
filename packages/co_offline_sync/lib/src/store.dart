import 'change.dart';
import 'hlc.dart';
import 'row_state.dart';

/// 저장소 변경 이벤트의 출처.
enum ChangeOrigin {
  /// 이 노드의 로컬 쓰기 (upsert/delete).
  local,

  /// 원격에서 pull 로 들어온 병합.
  remote,
}

/// 테이블 단위 변경 통지 — 반응형 계층(R2)의 소비 단위.
///
/// 화면/리포지토리는 이 스트림을 구독해 "어느 테이블의 어느 행이 바뀌었다" 를
/// 재조회 없이 감지한다.
class TableChange {
  /// 이벤트 필드를 담아 생성한다.
  const TableChange({
    required this.table,
    required this.rowId,
    required this.origin,
  });

  /// 논리 테이블 이름.
  final String table;

  /// 바뀐 행 id.
  final String rowId;

  /// 변경 출처.
  final ChangeOrigin origin;

  @override
  String toString() => 'TableChange($table/$rowId, $origin)';
}

/// push 대기 중인 로컬 변경 행의 스냅샷.
class PendingRow {
  /// [snapshotHlc] 는 스냅샷 시점 행의 [RowState.maxHlc].
  const PendingRow({
    required this.table,
    required this.rowId,
    required this.snapshotHlc,
  });

  /// 논리 테이블 이름.
  final String table;

  /// 행 id.
  final String rowId;

  /// 스냅샷 시점의 행 최대 HLC — ack 시 이 값 이하일 때만 pending 해제된다
  /// (전송 중 로컬 편집이 있으면 pending 유지 → 다음 push 에 재전송).
  final Hlc snapshotHlc;
}

/// 클라이언트 측 동기화 저장소 계약.
///
/// 병합 판단은 엔진([CoSyncClient])이 하고, 저장소는 **영속·pending 부기·
/// 변경 통지**만 책임진다. 프로덕션 구현은 SQLite/drift 위에, 테스트·참조
/// 구현은 [InMemoryClientSyncStore].
abstract interface class ClientSyncStore {
  /// 행 상태를 읽는다 (없으면 null).
  Future<RowState?> getRow(String table, String rowId);

  /// 병합이 끝난 행 상태를 저장하고 [changes] 로 통지한다.
  ///
  /// [pending] 이 true 면 push 대기 목록에 넣는다(로컬 쓰기), false 면
  /// 대기 목록을 건드리지 않는다(원격 병합).
  Future<void> putRow(
    String table,
    RowState state, {
    required ChangeOrigin origin,
    required bool pending,
  });

  /// push 대기 중인 행 스냅샷 목록.
  Future<List<PendingRow>> pendingRows();

  /// push ack 후 대기 해제 — 현재 행 maxHlc 가 [upTo] 이하일 때만 해제한다.
  Future<void> clearPending(String table, String rowId, Hlc upTo);

  /// 저장된 pull 커서 (없으면 null).
  Future<String?> loadCursor();

  /// pull 커서 저장.
  Future<void> saveCursor(String cursor);

  /// 저장된 모든 행을 통틀어 가장 큰 HLC (행이 없으면 null).
  ///
  /// 재시작 시 시계 시드용 — `HlcClock.seed` 참조 (리뷰 발견 2).
  Future<Hlc?> maxHlc();

  /// 테이블 단위 변경 통지 스트림 (broadcast).
  Stream<TableChange> get changes;
}

/// [ServerSyncStore.changesSince] 의 결과 페이지.
class ServerChangesPage {
  /// 페이지 필드를 담아 생성한다.
  const ServerChangesPage({
    required this.changes,
    required this.nextSeq,
    required this.hasMore,
  });

  /// seq 오름차순 변경 목록.
  final List<RowChange> changes;

  /// 다음 조회에 쓸 seq 커서 (이 페이지 마지막 변경의 seq).
  final int nextSeq;

  /// 이 페이지 뒤에 더 남았는가.
  final bool hasMore;
}

/// 서버 측 동기화 저장소 계약.
///
/// ⚠️ 프로덕션 구현은 seq·행 상태를 **반드시 DB 에** 둔다 — 다중 인스턴스
/// (EC2 2대, sticky 세션 없음) 환경에서 인메모리 상태는 요청마다 유실된다.
/// [InMemoryServerSyncStore] 는 테스트·참조용이다.
abstract interface class ServerSyncStore {
  /// 행 상태를 읽는다 (없으면 null).
  Future<RowState?> getRow(String table, String rowId);

  /// 병합이 끝난 행 상태를 [seq] 와 함께 저장한다.
  ///
  /// [seq] 는 [nextSeq] 가 발급한 단조 증가 값 — pull 커서의 기준이다.
  Future<void> putRow(String table, RowState state, {required int seq});

  /// 단조 증가 시퀀스를 발급한다 (프로덕션: DB 시퀀스).
  Future<int> nextSeq();

  /// [sinceSeq] 초과분의 변경을 seq 오름차순으로 최대 [limit] 개 돌려준다.
  Future<ServerChangesPage> changesSince(int sinceSeq, {required int limit});
}
