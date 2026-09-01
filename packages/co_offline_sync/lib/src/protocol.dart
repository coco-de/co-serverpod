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
class SyncPushResponse {
  /// [serverHlcPacked] 는 서버 시계의 최신 스탬프 ([Hlc.pack] 형식).
  const SyncPushResponse({
    required this.appliedCount,
    required this.serverHlcPacked,
  });

  /// 적용(병합)된 변경 수.
  final int appliedCount;

  /// 응답 시점 서버 HLC (packed) — 클라이언트 시계 동기화용.
  final String serverHlcPacked;

  /// JSON 표현.
  Map<String, Object?> toJson() => {
    'applied': appliedCount,
    'hlc': serverHlcPacked,
  };

  /// [toJson] 의 역연산.
  factory SyncPushResponse.fromJson(Map<String, Object?> json) =>
      SyncPushResponse(
        appliedCount: json['applied']! as int,
        serverHlcPacked: json['hlc']! as String,
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
