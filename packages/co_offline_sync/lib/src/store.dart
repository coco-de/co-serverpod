import 'change.dart';
import 'hlc.dart';
import 'quarantine.dart';
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
  ///
  /// 계약 두 가지:
  ///
  /// 1. **격리된 행은 빼야 한다** ([QuarantineCapableStore]). 격리는 "이
  ///    행은 재전송해도 같은 자리에서 거부된다" 는 판정이므로, 여기 남으면
  ///    매 회차가 같은 행에서 멈춘다 — 격리의 존재 이유가 사라진다.
  /// 2. **로컬 쓰기 순서(스냅샷 HLC 오름차순)로 정렬해야 한다.** 정렬이
  ///    없으면 저장 엔진의 물리 순서가 전송 순서가 되어, 뒤에 만들어진
  ///    자식 행이 앞선 부모 행보다 먼저 나가는 창이 생긴다(H9). 뒤 청크가
  ///    실패하면 그 창이 서버에 그대로 남는다. 동률은 `(table, rowId)` 로
  ///    깨 결정적으로 만든다.
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

/// 영구 실패 행 **격리**를 지원하는 저장소의 추가 계약 (선택).
///
/// [ClientSyncStore] 본체와 분리한 이유: 이미 배포된 구현체를 깨지 않기
/// 위해서다. [CoSyncClient] 는 스토어가 이 계약을 함께 구현할 때만 격리
/// 경로를 켜고, 아니면 종전처럼 실패를 그대로 던진다 — 격리하지 못하는
/// 스토어에서 "격리했다" 고 치고 넘어가면 그 행이 pending 에 남아 무한
/// 재시도가 된다.
///
/// ⚠️ [ClientSyncStore] 를 **감싸는 래퍼**(세대 스코프 데코레이터 등)를
/// 만든다면 이 계약도 함께 위임하라. 래퍼가 이것을 구현하지 않으면 안쪽
/// 스토어가 지원해도 격리가 조용히 꺼진다.
abstract interface class QuarantineCapableStore {
  /// [table]/[rowId] 를 격리한다 — 이후 [ClientSyncStore.pendingRows] 에서
  /// 제외되고, 행 상태·pending 스냅샷은 그대로 보존된다.
  ///
  /// 보존이 핵심이다: 격리는 폐기가 아니라 **보류**이므로, 해제
  /// ([requeueQuarantined]) 후 같은 스냅샷으로 재전송할 수 있어야 한다.
  Future<void> quarantineRow(
    String table,
    String rowId, {
    required QuarantineReason reason,
    required DateTime at,
  });

  /// 현재 격리된 행 목록 (사용자 화면·운영 집계의 원천).
  Future<List<QuarantinedRow>> quarantinedRows();

  /// 격리를 푼다 — 다음 push 에 다시 실린다. 그 행이 격리 상태가 아니었으면
  /// `false`.
  Future<bool> requeueQuarantined(String table, String rowId);

  /// 격리를 전부 푼다 — 해제된 행 수를 돌려준다 (앱 업데이트 후 일괄 재시도).
  Future<int> requeueAllQuarantined();

  /// 현재 격리된 행 수.
  Future<int> quarantinedRowCount();
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
