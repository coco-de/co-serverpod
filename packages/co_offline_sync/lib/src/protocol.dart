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

/// 클라이언트 → 서버: 로컬에서 쌓인 변경을 밀어 올리는 요청.
class SyncPushRequest {
  /// [schemaSignature] 는 [SchemaMismatchException] 판정에 쓰인다.
  const SyncPushRequest({
    required this.nodeId,
    required this.schemaSignature,
    required this.changes,
  });

  /// 보내는 노드의 식별자.
  final String nodeId;

  /// 클라이언트가 알고 있는 동기화 스키마 서명.
  final String schemaSignature;

  /// 밀어 올릴 변경 목록.
  final List<RowChange> changes;

  /// JSON 표현.
  Map<String, Object?> toJson() => {
    'node': nodeId,
    'schema': schemaSignature,
    'changes': [for (final c in changes) c.toJson()],
  };

  /// [toJson] 의 역연산.
  factory SyncPushRequest.fromJson(Map<String, Object?> json) =>
      SyncPushRequest(
        nodeId: json['node']! as String,
        schemaSignature: json['schema']! as String,
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
  });

  /// 요청 노드의 식별자.
  final String nodeId;

  /// 클라이언트가 알고 있는 동기화 스키마 서명.
  final String schemaSignature;

  /// 불투명 커서 (서버가 발급한 값 그대로 반납; 최초 null).
  final String? cursor;

  /// 한 페이지 최대 변경 수.
  final int limit;

  /// JSON 표현.
  Map<String, Object?> toJson() => {
    'node': nodeId,
    'schema': schemaSignature,
    'cursor': cursor,
    'limit': limit,
  };

  /// [toJson] 의 역연산.
  factory SyncPullRequest.fromJson(Map<String, Object?> json) =>
      SyncPullRequest(
        nodeId: json['node']! as String,
        schemaSignature: json['schema']! as String,
        cursor: json['cursor'] as String?,
        limit: json['limit']! as int,
      );
}

/// 서버 → 클라이언트: 커서 이후의 변경 한 페이지.
class SyncPullResponse {
  /// [hasMore] 가 true 면 [nextCursor] 로 즉시 다음 페이지를 요청한다.
  const SyncPullResponse({
    required this.changes,
    required this.nextCursor,
    required this.hasMore,
  });

  /// 이 페이지의 변경 목록 (서버 적용 순서).
  final List<RowChange> changes;

  /// 다음 요청에 쓸 커서.
  final String nextCursor;

  /// 이 페이지 뒤에 더 남았는가.
  final bool hasMore;

  /// JSON 표현.
  Map<String, Object?> toJson() => {
    'changes': [for (final c in changes) c.toJson()],
    'cursor': nextCursor,
    'more': hasMore,
  };

  /// [toJson] 의 역연산.
  factory SyncPullResponse.fromJson(Map<String, Object?> json) =>
      SyncPullResponse(
        changes: _changesFromJson(json['changes']),
        nextCursor: json['cursor']! as String,
        hasMore: json['more']! as bool,
      );
}
