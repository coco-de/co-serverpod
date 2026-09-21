import 'change.dart';
import 'exceptions.dart';

List<RowChange> _changesFromJson(Object? raw) {
  if (raw is! List<Object?>) {
    throw const SyncProtocolException('changes must be a list');
  }
  return [
    for (final item in raw) RowChange.fromJson(item! as Map<String, Object?>),
  ];
}

/// `sv`(스키마 버전 힌트)를 관대하게 읽는다 — 없으면 null, 정수(또는 정수값의
/// num)면 그 값, 그 밖은 [SyncProtocolException]. 선택 힌트 하나의 형식 오류가
/// 미분류 `TypeError` 로 요청 전체를 죽이지 않게 한다.
int? _schemaVersionFromJson(Object? raw) => switch (raw) {
  null => null,
  final int value => value,
  final num value when value == value.truncateToDouble() => value.toInt(),
  _ => throw const SyncProtocolException('sv must be an integer'),
};

/// push 응답의 선택 건수(`deferred`·`rejected`)를 **관대하게** 읽는다 — 0 이상
/// 정수(또는 정수값의 유한 num)면 그 값, 없거나 형식이 어긋나면 null(미상).
///
/// ⚠️ 여기서 던지면 안 된다 — `sv` 는 서버가 **요청**을 검증하는 자리라 거부가
/// 맞지만, 이 값은 클라이언트가 **서버가 이미 적용한** push 의 응답에서 읽는다.
/// 디코드가 실패하면 그 청크가 전송 실패로 보여 적용된 행이 pending 에 남고 매
/// 회차 재전송된다(unibook#14051 H2 와 같은 모양). 관측용 값이라 모르면 모른다고
/// 답하면 충분하다 — 0 으로 접지 않는다(판정 불가는 통과가 아니다).
int? _countFromJson(Object? raw) {
  if (raw is int) return raw >= 0 ? raw : null;
  if (raw is double &&
      raw.isFinite &&
      raw >= 0 &&
      raw == raw.truncateToDouble()) {
    return raw.toInt();
  }
  return null;
}

/// 클라이언트 → 서버: 로컬에서 쌓인 변경을 밀어 올리는 요청.
class SyncPushRequest {
  /// [schemaSignature] 는 [SchemaMismatchException] 판정에 쓰인다.
  /// [schemaVersion] 은 불일치 시 원인 분류용 힌트 — 없어도 동작한다.
  const SyncPushRequest({
    required this.nodeId,
    required this.schemaSignature,
    required this.changes,
    this.schemaVersion,
  });

  /// 보내는 노드의 식별자.
  final String nodeId;

  /// 클라이언트가 알고 있는 동기화 스키마 서명.
  final String schemaSignature;

  /// 클라이언트 스키마 버전 힌트 (레지스트리 서버의 원인 분류용, 선택).
  final int? schemaVersion;

  /// 밀어 올릴 변경 목록.
  final List<RowChange> changes;

  /// JSON 표현. `sv` 는 [schemaVersion] 이 있을 때만 실린다 (와이어 가산적).
  Map<String, Object?> toJson() => {
    'node': nodeId,
    'schema': schemaSignature,
    if (schemaVersion != null) 'sv': schemaVersion,
    'changes': [for (final c in changes) c.toJson()],
  };

  /// [toJson] 의 역연산.
  factory SyncPushRequest.fromJson(Map<String, Object?> json) =>
      SyncPushRequest(
        nodeId: json['node']! as String,
        schemaSignature: json['schema']! as String,
        schemaVersion: _schemaVersionFromJson(json['sv']),
        changes: _changesFromJson(json['changes']),
      );
}

/// 서버 → 클라이언트: push 적용 결과.
///
/// ## 보류·거부 건수 (unibook#14034, 와이어 가산적)
///
/// 병합(`appliedCount`)은 서버가 행을 **받았다**는 뜻이지, 그 행이 서버 쪽 도메인
/// 모델로 **구체화됐다**는 뜻이 아니다. 구체화 계층이 있는 서버는 그 결과를
/// [deferredCount](보류 — 서버가 나중에 재시도)·[rejectedCount](거부 — 상태가
/// 바뀔 때까지 재시도 안 함)로 함께 알려 준다. 둘 다 **선택**이다:
///
/// | 서버 | 키 | 클라이언트가 읽는 값 |
/// |---|---|---|
/// | 셀 수 있는 서버 | 항상 싣는다 (0 포함) | 그 값 |
/// | 구 서버 · 구체화 계층이 없는 서버 | 없음 | **null(미상)** — 0 이 아니다 |
///
/// 구 클라이언트의 [fromJson] 은 모르는 키를 읽지 않으므로 그대로 동작한다.
class SyncPushResponse {
  /// [serverHlcPacked] 는 서버 시계의 최신 스탬프 ([Hlc.pack] 형식).
  /// [deferredCount]·[rejectedCount] 는 서버가 셀 수 있을 때만 준다 (0 이상).
  const SyncPushResponse({
    required this.appliedCount,
    required this.serverHlcPacked,
    this.deferredCount,
    this.rejectedCount,
  }) : assert(
         deferredCount == null || deferredCount >= 0,
         'deferredCount must be >= 0',
       ),
       assert(
         rejectedCount == null || rejectedCount >= 0,
         'rejectedCount must be >= 0',
       );

  /// 적용(병합)된 변경 수.
  final int appliedCount;

  /// 응답 시점 서버 HLC (packed) — 클라이언트 시계 동기화용.
  final String serverHlcPacked;

  /// 서버가 받았지만 구체화를 **보류**한 변경 수 — 서버가 나중에 재시도한다.
  ///
  /// null 은 **미상**이다 — 이 값을 주지 않는 서버의 응답이다. 0 으로 읽지 말 것
  /// (판정 불가는 통과가 아니다).
  final int? deferredCount;

  /// 서버가 받았지만 구체화를 **거부**한 변경 수 — 행은 서버에 남고, 그 행의
  /// 상태가 다시 바뀔 때까지 재시도하지 않는다. null 은 미상 ([deferredCount]).
  final int? rejectedCount;

  /// JSON 표현. `deferred`·`rejected` 는 값이 있을 때만 실린다 (와이어 가산적).
  Map<String, Object?> toJson() => {
    'applied': appliedCount,
    'hlc': serverHlcPacked,
    if (deferredCount != null) 'deferred': deferredCount,
    if (rejectedCount != null) 'rejected': rejectedCount,
  };

  /// [toJson] 의 역연산. `deferred`·`rejected` 가 없거나 형식이 어긋나면
  /// null(미상)이다 — 관측용 값의 디코드 실패가 서버가 이미 적용한 push 를
  /// 실패로 보이게 해서는 안 된다(이 파일의 `_countFromJson` 참조).
  factory SyncPushResponse.fromJson(Map<String, Object?> json) =>
      SyncPushResponse(
        appliedCount: json['applied']! as int,
        serverHlcPacked: json['hlc']! as String,
        deferredCount: _countFromJson(json['deferred']),
        rejectedCount: _countFromJson(json['rejected']),
      );
}

/// 클라이언트 → 서버: 커서 이후의 변경을 당겨오는 요청.
class SyncPullRequest {
  /// [cursor] 는 직전 [SyncPullResponse.nextCursor], 최초에는 null.
  const SyncPullRequest({
    required this.nodeId,
    required this.schemaSignature,
    required this.cursor,
    this.limit = 200,
    this.schemaVersion,
  });

  /// 요청 노드의 식별자.
  final String nodeId;

  /// 클라이언트가 알고 있는 동기화 스키마 서명.
  final String schemaSignature;

  /// 클라이언트 스키마 버전 힌트 (레지스트리 서버의 원인 분류용, 선택).
  final int? schemaVersion;

  /// 불투명 커서 (서버가 발급한 값 그대로 반납; 최초 null).
  final String? cursor;

  /// 한 페이지 최대 변경 수.
  final int limit;

  /// JSON 표현. `sv` 는 [schemaVersion] 이 있을 때만 실린다 (와이어 가산적).
  Map<String, Object?> toJson() => {
    'node': nodeId,
    'schema': schemaSignature,
    if (schemaVersion != null) 'sv': schemaVersion,
    'cursor': cursor,
    'limit': limit,
  };

  /// [toJson] 의 역연산.
  factory SyncPullRequest.fromJson(Map<String, Object?> json) =>
      SyncPullRequest(
        nodeId: json['node']! as String,
        schemaSignature: json['schema']! as String,
        schemaVersion: _schemaVersionFromJson(json['sv']),
        cursor: json['cursor'] as String?,
        limit: json['limit']! as int,
      );
}

/// 서버 → 클라이언트: 커서 이후의 변경 한 페이지.
class SyncPullResponse {
  /// [hasMore] 가 true 면 [nextCursor] 로 즉시 다음 페이지를 요청한다.
  /// [serverHlcPacked] 는 투영 전 페이지 최대 스탬프와 서버 시계 중 큰 값 —
  /// 구 서버는 주지 않으므로 선택이다.
  const SyncPullResponse({
    required this.changes,
    required this.nextCursor,
    required this.hasMore,
    this.serverHlcPacked,
  });

  /// 이 페이지의 변경 목록 (서버 적용 순서).
  final List<RowChange> changes;

  /// 다음 요청에 쓸 커서.
  final String nextCursor;

  /// 이 페이지 뒤에 더 남았는가.
  final bool hasMore;

  /// 응답 시점 서버 HLC (packed, [Hlc.pack] 형식) — 클라이언트 시계 동기화용.
  /// 투영으로 숨겨진 컬럼의 스탬프도 이 값에 반영돼 있다 (선택, 가산적).
  final String? serverHlcPacked;

  /// JSON 표현. `hlc` 는 [serverHlcPacked] 가 있을 때만 실린다.
  Map<String, Object?> toJson() => {
    'changes': [for (final c in changes) c.toJson()],
    'cursor': nextCursor,
    'more': hasMore,
    if (serverHlcPacked != null) 'hlc': serverHlcPacked,
  };

  /// [toJson] 의 역연산.
  factory SyncPullResponse.fromJson(Map<String, Object?> json) =>
      SyncPullResponse(
        changes: _changesFromJson(json['changes']),
        nextCursor: json['cursor']! as String,
        hasMore: json['more']! as bool,
        serverHlcPacked: json['hlc'] as String?,
      );
}
