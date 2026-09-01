import 'change.dart';
import 'exceptions.dart';
import 'hlc.dart';
import 'merge.dart';
import 'protocol.dart';
import 'row_state.dart';
import 'schema_signature.dart';
import 'store.dart';
import 'transport.dart';

/// 삭제 여부가 해석된 행의 읽기 뷰.
class RowView {
  /// 해석 결과를 담아 생성한다.
  const RowView({
    required this.rowId,
    required this.isDeleted,
    required this.values,
  });

  /// 행 id.
  final String rowId;

  /// [TombstonePolicy] 로 해석된 삭제 여부.
  final bool isDeleted;

  /// 애플리케이션 필드 값 (예약 필드 제외).
  final Map<String, Object?> values;
}

/// [CoSyncClient.sync] 의 결과 요약.
class SyncReport {
  /// 결과 수치를 담아 생성한다.
  const SyncReport({required this.pushedRows, required this.pulledChanges});

  /// push 로 올린 행 수.
  final int pushedRows;

  /// pull 로 받아 병합한 변경 수.
  final int pulledChanges;

  @override
  String toString() =>
      'SyncReport(pushed: $pushedRows, pulled: $pulledChanges)';
}

/// 클라이언트 측 동기화 엔진 — 로컬 쓰기 스탬핑 · push/pull · 병합.
///
/// 로컬 쓰기는 오프라인에서도 즉시 [ClientSyncStore] 에 반영되고
/// [changes] 로 통지된다 (offline-first). [sync] 는 온라인일 때 호출한다.
///
/// 재시작 안전성: 첫 조작 전에 저장소의 최대 HLC 로 시계를 자동 시드해,
/// 재시작 직후의 로컬 편집이 이미 관찰한 스탬프보다 과거로 찍혀 LWW 에서
/// 조용히 패배하는 것(리뷰 발견 2)을 막는다.
///
/// [sync] 는 내부에서 직렬화된다 — 동시에 여러 번 호출해도 순서대로 실행되어
/// 커서가 과거로 되감기지 않는다.
class CoSyncClient {
  /// [syncSchema] 는 동기화 대상 `테이블 → 컬럼 목록` — 서명 계산과 로컬
  /// 쓰기 검증에 함께 쓴다.
  CoSyncClient({
    required ClientSyncStore store,
    required SyncTransport transport,
    required HlcClock clock,
    required Map<String, List<String>> syncSchema,
    this.tombstonePolicy = TombstonePolicy.deleteWins,
  }) : _store = store,
       _transport = transport,
       _clock = clock,
       _schema = {
         for (final entry in syncSchema.entries) entry.key: Set.of(entry.value),
       },
       schemaSignature = computeSchemaSignature(syncSchema);

  final ClientSyncStore _store;
  final SyncTransport _transport;
  final HlcClock _clock;
  final Map<String, Set<String>> _schema;

  /// 클라이언트가 아는 동기화 스키마 서명.
  final String schemaSignature;

  /// 읽기 뷰의 tombstone 해석 정책.
  final TombstonePolicy tombstonePolicy;

  bool _seeded = false;
  Future<void> _tail = Future<void>.value();

  /// 테이블 단위 변경 통지 스트림 (로컬·원격 모두).
  Stream<TableChange> get changes => _store.changes;

  /// 재시작 후 첫 조작 전에 저장소 최대 HLC 로 시계를 전진시킨다.
  Future<void> _ensureSeeded() async {
    if (_seeded) return;
    _seeded = true;
    final floor = await _store.maxHlc();
    if (floor != null) _clock.seed(floor);
  }

  void _validateLocalWrite(String table, Map<String, Object?> fields) {
    final columns = _schema[table];
    if (columns == null) {
      throw ArgumentError.value(table, 'table', 'not in syncSchema');
    }
    for (final name in fields.keys) {
      if (name.startsWith(r'$')) {
        throw ArgumentError.value(name, 'fields', r'$ prefix is reserved');
      }
      if (!columns.contains(name)) {
        throw ArgumentError.value(name, 'fields', 'not a column of $table');
      }
    }
  }

  /// 필드들을 로컬에 쓴다 — 각 필드에 새 HLC 를 스탬프하고 병합·저장한다.
  ///
  /// [fields] 는 [syncSchema] 의 컬럼이어야 하며 `$` 접두는 예약이다
  /// (위반 시 [ArgumentError] — assert 가 아니라 릴리스에서도 던진다).
  Future<void> upsert(
    String table,
    String rowId,
    Map<String, Object?> fields,
  ) async {
    _validateLocalWrite(table, fields);
    await _ensureSeeded();
    final hlc = _clock.now();
    await _applyLocal(table, rowId, {
      for (final e in fields.entries) e.key: FieldValue(e.value, hlc),
    });
  }

  /// 행을 삭제한다 (tombstone 기록 — 물리 삭제 아님).
  Future<void> delete(String table, String rowId) async {
    await _ensureSeeded();
    final hlc = _clock.now();
    await _applyLocal(table, rowId, {kDeletedField: FieldValue(true, hlc)});
  }

  /// 삭제된 행을 명시적으로 되살린다.
  Future<void> restore(String table, String rowId) async {
    await _ensureSeeded();
    final hlc = _clock.now();
    await _applyLocal(table, rowId, {kDeletedField: FieldValue(false, hlc)});
  }

  Future<void> _applyLocal(
    String table,
    String rowId,
    Map<String, FieldValue> stamped,
  ) async {
    final local = await _store.getRow(table, rowId);
    final incoming = RowState(rowId: rowId, fields: stamped);
    final merged = mergeIntoLocal(local, incoming);
    await _store.putRow(
      table,
      merged,
      origin: ChangeOrigin.local,
      pending: true,
    );
  }

  /// 행을 읽어 [tombstonePolicy] 로 해석한 뷰를 돌려준다 (없으면 null).
  Future<RowView?> read(String table, String rowId) async {
    final state = await _store.getRow(table, rowId);
    if (state == null) return null;
    return RowView(
      rowId: rowId,
      isDeleted: state.isDeleted(tombstonePolicy),
      values: state.valuesView(),
    );
  }

  /// push 후 pull 을 (페이지가 남는 동안) 반복해 서버와 수렴한다.
  ///
  /// 동시 호출은 내부 큐로 직렬화된다. [pullLimit] 은 1 이상이어야 한다.
  Future<SyncReport> sync({int pullLimit = 200}) {
    if (pullLimit < 1) {
      throw ArgumentError.value(pullLimit, 'pullLimit', 'must be >= 1');
    }
    final result = _tail.then((_) => _doSync(pullLimit));
    // 실패해도 다음 sync 가 이어지도록 에러를 삼킨 tail 만 보관한다.
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<SyncReport> _doSync(int pullLimit) async {
    await _ensureSeeded();
    final pushed = await _push();
    final pulled = await _pull(pullLimit);
    return SyncReport(pushedRows: pushed, pulledChanges: pulled);
  }

  Future<int> _push() async {
    final pending = await _store.pendingRows();
    if (pending.isEmpty) return 0;
    final changes = <RowChange>[];
    for (final p in pending) {
      final state = await _store.getRow(p.table, p.rowId);
      if (state == null) continue;
      changes.add(RowChange(table: p.table, state: state));
    }
    final response = await _transport.push(
      SyncPushRequest(
        nodeId: _clock.nodeId,
        schemaSignature: schemaSignature,
        changes: changes,
      ),
    );
    _clock.receive(Hlc.parse(response.serverHlcPacked));
    for (final change in changes) {
      // 전송 스냅샷의 maxHlc 이하일 때만 해제 — 전송 중 로컬 편집은
      // pending 으로 남아 다음 push 에 다시 실린다.
      await _store.clearPending(
        change.table,
        change.state.rowId,
        change.state.maxHlc,
      );
    }
    return changes.length;
  }

  Future<int> _pull(int limit) async {
    var cursor = await _store.loadCursor();
    var total = 0;
    while (true) {
      final response = await _transport.pull(
        SyncPullRequest(
          nodeId: _clock.nodeId,
          schemaSignature: schemaSignature,
          cursor: cursor,
          limit: limit,
        ),
      );
      for (final change in response.changes) {
        _clock.receive(change.state.maxHlc);
        final local = await _store.getRow(change.table, change.state.rowId);
        final merged = mergeIntoLocal(local, change.state);
        if (local != null && rowStatesEqual(local, merged)) continue;
        await _store.putRow(
          change.table,
          merged,
          origin: ChangeOrigin.remote,
          pending: false,
        );
        total++;
      }
      // 진행 가드 (리뷰 발견 1): 커서가 전진하지 않았는데 hasMore 면 서버가
      // 제자리걸음을 시키는 것 — 무한 루프 대신 실패시킨다.
      if (response.hasMore && response.nextCursor == (cursor ?? '0')) {
        throw SyncProtocolException(
          'pull made no progress at cursor ${response.nextCursor}',
        );
      }
      cursor = response.nextCursor;
      await _store.saveCursor(cursor);
      if (!response.hasMore) break;
    }
    return total;
  }
}
