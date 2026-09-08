/// 서버가 거부한 동기화 요청의 타입드 실패.
///
/// 소비 앱의 전송 어댑터가 서버의 실패를 이 타입으로 변환한다.
/// 생성 클라이언트나 특정 endpoint에 의존하지 않는다:
///
/// | [code] | 의미 | 권장 대응 |
/// |---|---|---|
/// | `schema_outdated` | 앱 스키마 버전이 서버 지원 창 아래 (또는 힌트 없는 구 앱) | **영구** — 앱 업데이트 안내, 로컬 쓰기는 계속 |
/// | `schema_server_behind` | 앱이 서버보다 앞섬 (롤링 배포 중간) | **일시** — 재시도, 안내 없음 |
/// | `schema_mismatch` | 같은 버전 번호로 다른 스키마 — 배포 결함 | 영구 + 리포트 |
/// | `protocol` | 페이로드·커서·limit 위반 | 클라 결함 — 재시도 무의미, 리포트 |
/// | `payload_too_large` | push 하드 게이트 위반 — 요청 바이트·변경 수·필드 값 길이 상한 (S2-3 #12812) | **영구** — 같은 페이로드 재전송은 무의미. 요소 분할(스트로크 포인트 쪼개기)·배치 축소 |
/// | `clock_drift` | 원격 스탬프가 허용 한도 이상 미래 | 기기 시계 확인 안내 |
///
/// `schema_server_behind` 는 서버 롤아웃 대기이므로 앱 업데이트 대상으로
/// 분류하지 않는다. 이 분류에 따른 재시도 정책은 소비 앱이 제공한다.
class CoSyncRemoteException implements Exception {
  /// 서버가 부여한 실패 코드와 메시지를 담아 생성한다.
  const CoSyncRemoteException({required this.code, required this.message});

  /// 서버 실패 코드 (`schema_outdated` / `schema_server_behind` /
  /// `schema_mismatch` / `protocol` / `payload_too_large` / `clock_drift`).
  final String code;

  /// 서버가 남긴 사람이 읽는 설명.
  final String message;

  /// 앱 스키마가 서버 지원 창보다 낡았다 — 업데이트 안내 대상.
  bool get isSchemaOutdated => code == 'schema_outdated';

  /// 서버가 아직 이 앱의 스키마를 모른다(롤아웃 중) — 잠시 뒤 재시도.
  bool get isServerBehind => code == 'schema_server_behind';

  /// push 하드 게이트에 걸렸다 — 같은 페이로드 재전송은 무의미하다 (#12812).
  bool get isPayloadTooLarge => code == 'payload_too_large';

  /// 재시도가 의미 없는 실패인가 (스키마 낡음·서명 충돌·프로토콜 결함·
  /// 페이로드 상한).
  ///
  /// `schema_server_behind` 와 `clock_drift` 는 **일시**다.
  bool get isPermanent =>
      code == 'schema_outdated' ||
      code == 'schema_mismatch' ||
      code == 'protocol' ||
      code == 'payload_too_large';

  @override
  String toString() => 'CoSyncRemoteException($code): $message';
}
