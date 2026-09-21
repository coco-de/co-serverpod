import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_sync/src/co_sync_remote_exception.dart';
import 'package:flutter/foundation.dart' show immutable;

/// 부팅 시 사전 대조 결과 — 첫 push 실패를 기다리지 않고 사용자 안내를
/// 갈라 쓰는 근거 (S5 게이트 3번, #12794).
///
/// ⚠️ 이 판정은 UX 용이다. 동기화를 실제로 막는 안전장치는 push/pull 의
/// 서명 대조(서버 `SchemaRegistry.resolve`)이며, 여기서 [compatible] 이
/// 나와도 그 대조는 그대로 수행된다.
enum CoSyncSchemaStatus {
  /// 아직 대조하지 않았거나 조회에 실패했다 (오프라인 등).
  unknown,

  /// 앱 버전이 서버 창 안이고 서명이 일치한다 (창 안의 구 버전 포함).
  compatible,

  /// 앱 버전이 서버 최소 지원 버전보다 낮다 — 앱 업데이트 안내.
  appOutdated,

  /// 앱 버전이 서버 현행보다 높다 — 서버 롤아웃 대기 (일시).
  serverBehind,

  /// 버전은 창 안인데 현행 서명이 다르다 — 배포 결함 (리포트).
  signatureConflict,
}

/// 서버가 코드를 주지 않은 실패에 붙는 코드 — 전송 계층(연결 끊김·타임아웃·
/// 5xx·직렬화)에서 난 일시 실패다.
///
/// ⚠️ "원인 미상" 이 아니라 **"재시도가 의미 있는 실패"** 를 뜻한다. 서버가
/// 분류한 영구 실패는 언제나 [CoSyncRemoteException.code] 를 갖는다.
const String kCoSyncTransportFailureCode = 'transport';

/// 서버가 거부한 시계 오차의 코드 — 이 단말의 시계가 서버보다 허용 한도를 넘어
/// **앞섰다** (서버가 push 를 받지 않는다). [CoSyncRemoteException.code] 로 온다.
const String kCoSyncClockDriftCode = 'clock_drift';

/// 이 단말의 코어 시계가 서버 스탬프를 거부한 실패의 코드 — 단말 시계가 서버보다
/// 허용 한도(`HlcClock.maxDriftMs`, 기본 1시간) 넘게 **뒤처졌다** (unibook#14051 ·
/// 계약 §7.2 HLC 거부 ②).
///
/// [kCoSyncClockDriftCode] 와 방향이 반대라 코드를 가른다. 둘 다 **일시** 실패다 —
/// 기기 시계를 고치면 같은 상태가 그대로 올라간다(재스탬프 없음). 이 경우 push 는
/// 이미 서버에 적용돼 pending 에서 빠졌고, pull 은 커서를 옮기지 않았다.
const String kCoSyncClockDriftBehindCode = 'clock_drift_behind';

/// 마지막 동기화 실패 요약 — 사용자에게 **사유를 다르게 보여 주기** 위한 값.
///
/// 원본 예외([CoSyncRuntime.lastError])는 그대로 남는다. 이 타입은 UI 가
/// `is CoSyncRemoteException` 분기를 하지 않게 하려고 코드를 평평하게 편 것이다.
@immutable
class CoSyncFailure {
  /// 실패 코드와 분류를 담아 생성한다.
  const CoSyncFailure({
    required this.code,
    required this.isPermanent,
    required this.at,
    this.message,
  });

  /// [error] 를 분류한다 — 타입드 실패면 서버 코드를, 코어 시계의 거부면
  /// [kCoSyncClockDriftBehindCode] 를, 아니면 [kCoSyncTransportFailureCode] 를 쓴다.
  ///
  /// [CoSyncRuntime] 의 동기화 경로가 실패를 기록하는 **유일한** 분류기다 —
  /// 분기를 여기 한 곳에만 두어 런타임 상태와 다른 소비처의 판정이 갈리지 않는다.
  factory CoSyncFailure.from(Object error, {required DateTime at}) {
    if (error is CoSyncRemoteException) {
      return CoSyncFailure(
        code: error.code,
        isPermanent: error.isPermanent,
        at: at,
        message: error.message,
      );
    }
    if (error is ClockDriftException) {
      // 서버 실패는 전송 어댑터가 [CoSyncRemoteException] 으로 옮긴다(위 분기).
      // 날것으로 여기 닿는 드리프트는 이 단말의 코어 시계가 **서버 스탬프**를
      // 거부한 것 = 단말이 뒤처졌다. 종전에는 아래 `transport` 로 접혀 "잠시 뒤
      // 재시도" 로 보였다 — 사용자가 시계를 고칠 이유를 알 수 없었다 (G3).
      return CoSyncFailure(
        code: kCoSyncClockDriftBehindCode,
        isPermanent: false,
        at: at,
        message: error.message,
      );
    }
    // ⚠️ 여기서 `isPermanent: true` 로 두면 안 된다 — 오프라인·타임아웃이
    //    "영구 실패" 로 표시되어 사용자가 데이터를 잃었다고 오해한다.
    return CoSyncFailure(
      code: kCoSyncTransportFailureCode,
      isPermanent: false,
      at: at,
      message: error.toString(),
    );
  }

  /// 서버 실패 코드 (`schema_outdated`·`clock_drift`·`payload_too_large` 등),
  /// [kCoSyncClockDriftBehindCode] 또는 [kCoSyncTransportFailureCode].
  final String code;

  /// 재시도가 의미 없는 실패인가 ([CoSyncRemoteException.isPermanent]).
  final bool isPermanent;

  /// 기기 시계가 허용 한도를 넘어 어긋난 실패인가 — 방향과 무관하게 "기기 시계를
  /// 확인하세요" 안내의 대상이다 ([kCoSyncClockDriftCode] · 앞섬,
  /// [kCoSyncClockDriftBehindCode] · 뒤처짐).
  bool get isClockDrift =>
      code == kCoSyncClockDriftCode || code == kCoSyncClockDriftBehindCode;

  /// 실패를 관측한 시각.
  final DateTime at;

  /// 서버가 남긴 설명(있으면) 또는 예외 문자열 — 로그·진단용.
  final String? message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CoSyncFailure &&
          other.code == code &&
          other.isPermanent == isPermanent &&
          other.at == at &&
          other.message == message;

  @override
  int get hashCode => Object.hash(code, isPermanent, at, message);

  @override
  String toString() => 'CoSyncFailure($code, permanent=$isPermanent, at=$at)';
}

/// 동기화 런타임의 **관측 가능한 상태 전부** — 사용자 상태 UI(unibook#13737)의
/// 단일 입력값.
///
/// ## 왜 값 하나로 묶는가
///
/// 건수·시각·진행 여부를 각각 `ValueListenable` 로 내보내면 UI 가 그것들을
/// 다시 조합하게 되고, 그 조합이 **런타임과 어긋나는 순간**(한 축만 갱신된
/// 프레임)이 생긴다. "대기 3건인데 실패 아님" 같은 중간 상태가 화면에
/// 잠깐 보이는 것이 정확히 그 증상이다. 한 값으로 원자적으로 발행한다.
///
/// ## 무엇이 여기에 없는가
///
/// - 개별 격리 행(사유·시각)은 [CoSyncRuntime.listQuarantinedRows] 로 읽는다.
///   상태 값은 프레임마다 비교되므로 목록을 싣지 않는다.
/// - 원본 예외는 [CoSyncRuntime.lastError] 에 남는다.
@immutable
class CoSyncStatus {
  /// 상태 필드를 담아 생성한다.
  const CoSyncStatus({
    this.pendingCount = 0,
    this.quarantinedCount = 0,
    this.inFlight = false,
    this.schemaStatus = CoSyncSchemaStatus.unknown,
    this.lastSuccessAt,
    this.lastFailure,
  });

  /// 아직 서버에 닿지 않은 행 수 — pending ∪ 격리
  /// ([QuarantineCapableStore.unsentRowCount]).
  ///
  /// ⚠️ 격리분을 **포함한다**. "아직 안 올라갔다" 를 묻는 자리에서 격리된 행은
  /// 가장 확실하게 서버에 없는 행이기 때문이다. 그중 몇 건이 격리인지는
  /// [quarantinedCount] 가 따로 말한다 — 두 값을 더하지 말 것.
  final int pendingCount;

  /// 그중 영구 거부로 격리된 행 수 ([pendingCount] 의 부분집합).
  final int quarantinedCount;

  /// 지금 동기화 회차가 진행 중인가.
  final bool inFlight;

  /// 마지막 스키마 창 사전 대조 결과.
  final CoSyncSchemaStatus schemaStatus;

  /// 마지막으로 동기화가 성공한 시각 (한 번도 없으면 null).
  final DateTime? lastSuccessAt;

  /// 마지막 실패 (성공하면 null 로 지워진다).
  final CoSyncFailure? lastFailure;

  /// 미전송분이 하나도 없고 실패도 없는가 — UI 가 조용히 있어도 되는 상태.
  bool get isIdle =>
      pendingCount == 0 &&
      !inFlight &&
      lastFailure == null &&
      schemaStatus != CoSyncSchemaStatus.appOutdated;

  /// 사용자가 **행동해야** 하는 상태인가 — 격리·영구 실패·앱 낡음.
  ///
  /// 일시 실패(오프라인·전송 오류)는 여기 들어가지 않는다. 자동 재시도가
  /// 받아내므로 사유 시트를 열 이유가 없다.
  bool get needsAttention =>
      quarantinedCount > 0 ||
      (lastFailure?.isPermanent ?? false) ||
      schemaStatus == CoSyncSchemaStatus.appOutdated;

  /// 일부 필드만 바꾼 사본.
  CoSyncStatus copyWith({
    int? pendingCount,
    int? quarantinedCount,
    bool? inFlight,
    CoSyncSchemaStatus? schemaStatus,
    DateTime? lastSuccessAt,
    CoSyncFailure? lastFailure,
    bool clearLastFailure = false,
  }) => CoSyncStatus(
    pendingCount: pendingCount ?? this.pendingCount,
    quarantinedCount: quarantinedCount ?? this.quarantinedCount,
    inFlight: inFlight ?? this.inFlight,
    schemaStatus: schemaStatus ?? this.schemaStatus,
    lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    lastFailure: clearLastFailure ? null : (lastFailure ?? this.lastFailure),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CoSyncStatus &&
          other.pendingCount == pendingCount &&
          other.quarantinedCount == quarantinedCount &&
          other.inFlight == inFlight &&
          other.schemaStatus == schemaStatus &&
          other.lastSuccessAt == lastSuccessAt &&
          other.lastFailure == lastFailure;

  @override
  int get hashCode => Object.hash(
    pendingCount,
    quarantinedCount,
    inFlight,
    schemaStatus,
    lastSuccessAt,
    lastFailure,
  );

  @override
  String toString() =>
      'CoSyncStatus(pending=$pendingCount, quarantined=$quarantinedCount, '
      'inFlight=$inFlight, schema=${schemaStatus.name}, '
      'lastSuccessAt=$lastSuccessAt, lastFailure=$lastFailure)';
}
