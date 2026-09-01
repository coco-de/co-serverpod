import 'change.dart';
import 'exceptions.dart';
import 'hlc.dart';
import 'merge.dart';
import 'protocol.dart';
import 'row_state.dart';
import 'schema_registry.dart';
import 'store.dart';

/// 서버 측 동기화 처리기.
///
/// 상태(행·seq)는 전부 [ServerSyncStore] 에 있고 이 클래스는 무상태다 —
/// 다중 인스턴스 환경에서 요청마다 새로 만들어도 된다. [clock] 만은 노드
/// 수명(프로세스)당 하나를 유지하는 것이 좋다.
///
/// ## 스키마 호환 창
///
/// [CoSyncServer.withRegistry] 로 만들면 [SchemaRegistry] 의 모든 버전을
/// 동시에 받아 준다. 요청은 서명으로 어느 버전인지 확정되고(서명이 정본,
/// 버전 번호는 불일치 원인 분류용 힌트), **pull 은 그 버전의 컬럼으로
/// 투영**해 내려보낸다. 그래서 구 클라이언트는 자기가 아는 컬럼만 저장하고,
/// 신 컬럼 값은 필드 단위 병합이 그대로 보존한다.
///
/// push 검증은 **레지스트리가 아는 컬럼 전체**(= 현행 버전) 기준이다 —
/// 그 클라이언트 버전 기준이 아니다. 롤링 배포 중에는 투영을 모르는 구
/// 인스턴스가 구 클라이언트에 신 컬럼을 그대로 내려줄 수 있고, 행 상태 전체를
/// 나르는 클라이언트는 그것을 다음 push 에 되실어 보낸다. 그때 그 버전 기준으로
/// 거부하면 그 단말의 동기화가 **영구히** 막힌다(적대 리뷰 발견). 되실린 값은
/// 서버가 준 것 그대로라 필드 LWW 에서 no-op 이거나 정당한 병합이다.
class CoSyncServer {
  /// 단일 스키마 서버 — 호환 창 없이 [syncSchema] 하나만 받아 준다 (종전 동작).
  CoSyncServer({
    required ServerSyncStore store,
    required HlcClock clock,
    required Map<String, List<String>> syncSchema,
  }) : this.withRegistry(
         store: store,
         clock: clock,
         registry: SchemaRegistry.single(syncSchema),
       );

  /// 호환 창 서버 — [registry] 의 모든 버전을 받아 준다.
  CoSyncServer.withRegistry({
    required ServerSyncStore store,
    required HlcClock clock,
    required this.registry,
  }) : _store = store,
       _clock = clock;

  final ServerSyncStore _store;
  final HlcClock _clock;

  /// 서버가 받아 주는 스키마 버전 창.
  final SchemaRegistry registry;

  /// 서버 현행 스키마 서명 (레지스트리의 최신 버전).
  String get schemaSignature => registry.current.signature;

  SchemaVersion _resolveSchema(String clientSignature, int? clientVersion) =>
      registry.resolve(signature: clientSignature, version: clientVersion);

  /// 서명만으로는 막을 수 없는 악성/버그 페이로드를 거부한다 (리뷰 발견 4).
  ///
  /// 서명이 일치한다고 페이로드가 스키마를 따르는 것은 아니다 — 서명은
  /// 클라이언트가 **주장하는** 값일 뿐이다. 기준은 **레지스트리 현행**(창 안의
  /// 모든 버전의 합집합)이다 — 클래스 dartdoc 의 롤링 배포 시나리오 참조.
  void _validateChange(RowChange change) {
    final columns = registry.current.columnSets[change.table];
    if (columns == null) {
      throw SyncProtocolException('unknown table: ${change.table}');
    }
    for (final field in change.state.fields.keys) {
      if (field == kDeletedField) continue;
      if (field.startsWith(r'$')) {
        throw SyncProtocolException('reserved field not allowed: $field');
      }
      if (!columns.contains(field)) {
        throw SyncProtocolException('unknown column: ${change.table}.$field');
      }
    }
  }

  /// push 를 적용한다 — 변경별로 저장 상태와 병합하고 seq 를 발급한다.
  ///
  /// 멱등: 같은 요청을 다시 받아도 행 상태가 변하지 않고, 이미 반영된 변경은
  /// seq 를 갱신하지 않은 채 건너뛴다 (`appliedCount` 0) — 재시도·중복 전달에
  /// 안전하다.
  ///
  /// ⚠️ **다중 인스턴스 동시성**: `getRow → merge → putRow` 는 이 계층에서
  /// 원자적이지 않다. 두 인스턴스가 같은 행에 동시에 push 를 적용하면 한쪽
  /// 병합이 유실될 수 있으므로, 프로덕션 [ServerSyncStore] 구현은 행 단위
  /// 직렬화(`SELECT ... FOR UPDATE` 트랜잭션 등)를 **반드시** 제공해야 한다.
  /// 병합이 멱등·교환적이라 재시도로 수렴하지만, 유실 없는 보장은 저장소
  /// 트랜잭션이 담당한다.
  Future<SyncPushResponse> handlePush(SyncPushRequest request) async {
    _resolveSchema(request.schemaSignature, request.schemaVersion);
    var applied = 0;
    for (final change in request.changes) {
      _validateChange(change);
      _clock.receive(change.state.maxHlc);
      final local = await _store.getRow(change.table, change.state.rowId);
      final merged = mergeIntoLocal(local, change.state);
      if (local != null && rowStatesEqual(local, merged)) {
        continue; // 이미 반영된 변경 — seq 를 움직이지 않는다 (재시도 멱등).
      }
      final seq = await _store.nextSeq();
      await _store.putRow(change.table, merged, seq: seq);
      applied++;
    }
    return SyncPushResponse(
      appliedCount: applied,
      serverHlcPacked: _clock.now().pack(),
    );
  }

  /// pull — 커서 이후의 변경 한 페이지를 돌려준다.
  ///
  /// 변경은 요청 클라이언트의 스키마 버전으로 **투영**된다 — 그 버전이
  /// 모르는 테이블의 변경은 빠지고, 모르는 컬럼은 행 상태에서 제거된다
  /// (`$deleted` 는 값과 무관하게 보존). 투영 결과가 비어 있으면(그 버전에는
  /// 아무 의미가 없는 변경) 페이지에서 제외하되 커서는 그대로 전진한다.
  ///
  /// 응답의 `serverHlcPacked` 는 **투영 전** 페이지 최대 스탬프와 서버 시계 중
  /// 큰 값이다 — 구 클라이언트가 숨겨진 컬럼의 스탬프를 관찰하지 못해 시계가
  /// 뒤처지는 것을 막는다(그러면 그 뒤의 삭제가 숨겨진 편집에 진다 — 적대
  /// 리뷰 발견). 구 클라이언트는 이 키를 모르므로 무시한다(가산적).
  ///
  /// `limit < 1` 은 [SyncProtocolException] 으로 거부한다 — 허용하면 커서가
  /// 전진하지 못한 채 `hasMore` 만 참이 되어 클라이언트가 무한 재요청한다
  /// (리뷰 발견 1).
  Future<SyncPullResponse> handlePull(SyncPullRequest request) async {
    final schema = _resolveSchema(
      request.schemaSignature,
      request.schemaVersion,
    );
    if (request.limit < 1) {
      throw SyncProtocolException('invalid limit: ${request.limit}');
    }
    final sinceSeq = _parseCursor(request.cursor);
    final page = await _store.changesSince(sinceSeq, limit: request.limit);
    var observed = _clock.now();
    final projected = <RowChange>[];
    for (final change in page.changes) {
      final max = change.state.maxHlc;
      if (max > observed) observed = max;
      final visible = _projectForClient(change, schema);
      if (visible != null) projected.add(visible);
    }
    return SyncPullResponse(
      changes: projected,
      nextCursor: page.nextSeq.toString(),
      hasMore: page.hasMore,
      serverHlcPacked: observed.pack(),
    );
  }

  /// [change] 를 [schema] 버전이 아는 컬럼으로 투영한다. 그 버전에 전달할
  /// 내용이 없으면 null — 테이블 자체를 모르거나, 앱 필드가 하나도 안 남고
  /// `$deleted` 필드도 없는 경우.
  ///
  /// `$deleted` 는 **값과 무관하게** 있으면 전달한다. 삭제(`true`)만 보내고
  /// 되살림(`false`)을 거르면, tombstone 을 받은 구 클라이언트는 신 클라이언트가
  /// 되살린 행을 그 버전이 아는 컬럼이 다시 바뀔 때까지 삭제된 것으로 본다
  /// (적대 리뷰 발견 — 방향 비대칭, 단일 스키마에서도 HEAD 대비 회귀였다).
  /// 서버는 lattice 원소를 떨어뜨리지 않는다 — "본 적 없는 행에 빈 alive 상태를
  /// 만들지 않는" 판단은 그 행을 가진 쪽, 즉 클라이언트 `_pull` 이 한다.
  RowChange? _projectForClient(RowChange change, SchemaVersion schema) {
    final columns = schema.columnSets[change.table];
    if (columns == null) return null;
    final projected = change.state.project(columns);
    final hasAppField = projected.fields.keys.any((k) => k != kDeletedField);
    final hasDeletedFlag = projected.deletedField != null;
    if (!hasAppField && !hasDeletedFlag) return null;
    return RowChange(table: change.table, state: projected);
  }

  int _parseCursor(String? cursor) {
    if (cursor == null || cursor.isEmpty) return 0;
    final parsed = int.tryParse(cursor);
    if (parsed == null || parsed < 0) {
      throw SyncProtocolException('invalid cursor: $cursor');
    }
    return parsed;
  }
}
