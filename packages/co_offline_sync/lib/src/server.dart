import 'change.dart';
import 'exceptions.dart';
import 'hlc.dart';
import 'merge.dart';
import 'protocol.dart';
import 'row_state.dart';
import 'schema_signature.dart';
import 'store.dart';

/// 서버 측 동기화 처리기.
///
/// 상태(행·seq)는 전부 [ServerSyncStore] 에 있고 이 클래스는 무상태다 —
/// 다중 인스턴스 환경에서 요청마다 새로 만들어도 된다. [clock] 만은 노드
/// 수명(프로세스)당 하나를 유지하는 것이 좋다.
class CoSyncServer {
  /// [syncSchema] 는 동기화 대상 `테이블 → 컬럼 목록` — 서명 계산과
  /// 페이로드 검증(미지 테이블·컬럼·예약 필드 거부)에 함께 쓴다.
  CoSyncServer({
    required ServerSyncStore store,
    required HlcClock clock,
    required Map<String, List<String>> syncSchema,
  }) : _store = store,
       _clock = clock,
       _schema = {
         for (final entry in syncSchema.entries) entry.key: Set.of(entry.value),
       },
       schemaSignature = computeSchemaSignature(syncSchema);

  final ServerSyncStore _store;
  final HlcClock _clock;
  final Map<String, Set<String>> _schema;

  /// 서버가 아는 동기화 스키마 서명.
  final String schemaSignature;

  void _checkSchema(String clientSignature) {
    if (clientSignature != schemaSignature) {
      throw SchemaMismatchException(
        expected: schemaSignature,
        actual: clientSignature,
      );
    }
  }

  /// 서명만으로는 막을 수 없는 악성/버그 페이로드를 거부한다 (리뷰 발견 4).
  ///
  /// 서명이 일치한다고 페이로드가 스키마를 따르는 것은 아니다 — 서명은
  /// 클라이언트가 **주장하는** 값일 뿐이다.
  void _validateChange(RowChange change) {
    final columns = _schema[change.table];
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
    _checkSchema(request.schemaSignature);
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
  /// `limit < 1` 은 [SyncProtocolException] 으로 거부한다 — 허용하면 커서가
  /// 전진하지 못한 채 `hasMore` 만 참이 되어 클라이언트가 무한 재요청한다
  /// (리뷰 발견 1).
  Future<SyncPullResponse> handlePull(SyncPullRequest request) async {
    _checkSchema(request.schemaSignature);
    if (request.limit < 1) {
      throw SyncProtocolException('invalid limit: ${request.limit}');
    }
    final sinceSeq = _parseCursor(request.cursor);
    final page = await _store.changesSince(sinceSeq, limit: request.limit);
    return SyncPullResponse(
      changes: page.changes,
      nextCursor: page.nextSeq.toString(),
      hasMore: page.hasMore,
    );
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
