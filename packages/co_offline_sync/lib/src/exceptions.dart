/// co_offline_sync 의 모든 예외의 공통 상위 타입.
sealed class CoOfflineSyncException implements Exception {
  const CoOfflineSyncException(this.message);

  /// 사람이 읽는 설명.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// 원격 HLC 가 로컬 벽시계보다 허용 한도 이상 미래일 때.
///
/// 상대 노드의 시계가 심하게 틀어졌다는 뜻이므로, 그 스탬프를 받아들이면
/// 이후 모든 로컬 스탬프가 그 미래 시각에 끌려간다 — 받아들이지 않고 실패시킨다.
class ClockDriftException extends CoOfflineSyncException {
  /// 드리프트 판정에 쓰인 값들을 담아 생성한다.
  ClockDriftException({
    required this.remoteMillis,
    required this.wallMillis,
    required this.maxDriftMs,
  }) : super(
         'remote HLC is ${remoteMillis - wallMillis}ms ahead of local wall '
         'clock (max allowed: ${maxDriftMs}ms)',
       );

  /// 원격 스탬프의 벽시계 성분.
  final int remoteMillis;

  /// 판정 시점의 로컬 벽시계.
  final int wallMillis;

  /// 허용 드리프트 상한.
  final int maxDriftMs;
}

/// 같은 밀리초 안에서 논리 카운터가 16비트를 넘었을 때 (실사용에서 도달 불가).
class HlcCounterOverflowException extends CoOfflineSyncException {
  /// 오버플로가 난 밀리초를 담아 생성한다.
  HlcCounterOverflowException({required int millis})
    : super('HLC counter overflow at millis=$millis');
}

/// 스키마 불일치의 원인 분류 — 소비 측이 사용자 안내를 갈라 쓰는 근거.
///
/// | 값 | 뜻 | 소비 측 대응 |
/// |---|---|---|
/// | [clientOutdated] | 클라이언트 버전이 지원 창 **아래** | 앱 업데이트 유도 (영구) |
/// | [serverBehind] | 클라이언트 버전이 서버 현행보다 **위** | 서버 롤아웃 대기 후 재시도 (일시) |
/// | [signatureConflict] | 버전 번호는 창 안인데 서명이 다름 | 같은 버전 번호로 다른 스키마를 배포한 **결함** — 개발 단계 검출 |
/// | [unknown] | 서명이 어느 버전과도 다르고 버전 힌트도 없음 | 버전 힌트를 보내지 않는 구 클라이언트 — 업데이트 유도 |
enum SchemaMismatchReason {
  /// 서명이 레지스트리의 어느 버전과도 일치하지 않고 버전 힌트도 없다.
  unknown,

  /// 클라이언트 스키마 버전이 서버의 최소 지원 버전보다 낮다.
  clientOutdated,

  /// 클라이언트 스키마 버전이 서버의 현행 버전보다 높다.
  serverBehind,

  /// 버전 번호는 지원 창 안인데 그 버전의 서명과 다르다.
  signatureConflict,
}

/// 클라이언트와 서버의 동기화 대상 스키마 서명이 다를 때.
///
/// 서명이 다른 채로 병합하면 필드가 조용히 유실되므로, 동기화 자체를 거부한다.
/// 소비 측은 [reason] 으로 앱 업데이트 유도(영구)와 서버 롤아웃 대기(일시)를
/// 갈라 안내한다. 버전 정보는 클라이언트가 힌트를 보냈을 때만 채워진다.
class SchemaMismatchException extends CoOfflineSyncException {
  /// 양쪽 서명을 담아 생성한다. [reason] 기본값은 [SchemaMismatchReason.unknown].
  SchemaMismatchException({
    required this.expected,
    required this.actual,
    this.reason = SchemaMismatchReason.unknown,
    this.clientVersion,
    this.minSupportedVersion,
    this.currentVersion,
  }) : super(
         'schema signature mismatch (${reason.name}): '
         'server=$expected client=$actual'
         '${clientVersion == null ? '' : ' clientVersion=v$clientVersion'}'
         '${_windowSuffix(minSupportedVersion, currentVersion)}',
       );

  static String _windowSuffix(int? min, int? current) {
    if (min != null && current != null) return ' supported=v$min..v$current';
    if (min != null) return ' minSupported=v$min';
    if (current != null) return ' current=v$current';
    return '';
  }

  /// 서버 쪽 (현행) 서명.
  final String expected;

  /// 클라이언트가 보낸 서명.
  final String actual;

  /// 불일치 원인 분류.
  final SchemaMismatchReason reason;

  /// 클라이언트가 힌트로 보낸 스키마 버전 (없으면 null).
  final int? clientVersion;

  /// 서버가 받아 주는 가장 오래된 스키마 버전 (레지스트리 서버만 채운다).
  final int? minSupportedVersion;

  /// 서버 현행 스키마 버전 (레지스트리 서버만 채운다).
  final int? currentVersion;
}

/// 와이어에서 온 페이로드가 프로토콜 형식에 맞지 않을 때.
class SyncProtocolException extends CoOfflineSyncException {
  /// 설명을 담아 생성한다.
  const SyncProtocolException(super.message);
}
