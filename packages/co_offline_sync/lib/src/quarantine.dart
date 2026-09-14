/// 서버가 **영구 거부**한 행의 사유 — 격리 원장에 남는 값.
///
/// 코어는 어떤 코드가 영구인지 모른다 (전송 계층이 앱마다 다르다). 판정은
/// [PushFailureClassifier] 가 하고, 이 클래스는 그 결과를 나른다.
class QuarantineReason {
  /// 서버가 준 실패 코드와 설명을 담아 생성한다.
  const QuarantineReason({required this.code, required this.message});

  /// 서버 실패 코드 (예: `payload_too_large` · `protocol`).
  final String code;

  /// 사람이 읽는 설명 — 사용자 안내가 아니라 진단용이다.
  final String message;

  @override
  String toString() => 'QuarantineReason($code): $message';
}

/// 격리된 pending 행 — push 에서 제외되고 사용자·운영에 드러난다.
class QuarantinedRow {
  /// 격리 대상과 사유·시각을 담아 생성한다.
  const QuarantinedRow({
    required this.table,
    required this.rowId,
    required this.reason,
    required this.at,
  });

  /// 논리 테이블 이름.
  final String table;

  /// 행 id.
  final String rowId;

  /// 격리 사유.
  final QuarantineReason reason;

  /// 격리 시각 (UTC).
  final DateTime at;

  @override
  String toString() => 'QuarantinedRow($table/$rowId, ${reason.code}, $at)';
}

/// push 실패를 **행에 귀속되는 영구 실패**로 분류한다 — 아니면 `null`.
///
/// ⚠️ **요청 단위 영구 실패를 여기서 non-null 로 돌려주면 안 된다.** 스키마
/// 불일치(`schema_outdated` 등)는 청크의 모든 행이 똑같이 실패하므로, 이분
/// 재시도가 끝까지 쪼개져 **pending 전량이 격리된다**. 그 실패는 그대로
/// 던져야 다음 회차(또는 앱 업데이트 후)에 회수된다.
///
/// 행 귀속의 판정 기준: *같은 청크의 다른 행만 남기면 성공하는가.* 페이로드
/// 상한(`payload_too_large`)·페이로드 형식(`protocol`)이 그렇다.
typedef PushFailureClassifier = QuarantineReason? Function(Object error);
