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

/// 클라이언트와 서버의 동기화 대상 스키마 서명이 다를 때.
///
/// 서명이 다른 채로 병합하면 필드가 조용히 유실되므로, 동기화 자체를 거부한다.
/// 소비 측은 앱 업데이트 유도 또는 서버 롤아웃 대기로 해소한다.
class SchemaMismatchException extends CoOfflineSyncException {
  /// 양쪽 서명을 담아 생성한다.
  SchemaMismatchException({required this.expected, required this.actual})
    : super('schema signature mismatch: server=$expected client=$actual');

  /// 서버 쪽 서명.
  final String expected;

  /// 클라이언트가 보낸 서명.
  final String actual;
}

/// 와이어에서 온 페이로드가 프로토콜 형식에 맞지 않을 때.
class SyncProtocolException extends CoOfflineSyncException {
  /// 설명을 담아 생성한다.
  const SyncProtocolException(super.message);
}
