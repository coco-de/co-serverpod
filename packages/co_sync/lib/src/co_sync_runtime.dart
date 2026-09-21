import 'dart:async';
import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_sync/src/co_sync_remote_exception.dart';
import 'package:co_sync/src/co_sync_status.dart';
import 'package:co_sync/src/drift/co_sync_database.dart';
import 'package:co_sync/src/drift_client_sync_store.dart';
import 'package:flutter/foundation.dart';

/// 서버가 알려 주는 스키마 버전 창 (`CoSyncEndpoint.getSchemaWindow`).
typedef SchemaWindowInfo = ({
  int currentVersion,
  int minSupportedVersion,
  String currentSignature,
});

/// 서버 스키마 창을 조회하는 통로 — 전송 어댑터가 함께 구현한다
/// (앱에서 구현한 전송 어댑터). 테스트는 가짜로 대체한다.
abstract interface class SchemaWindowProbe {
  /// 서버의 현행·최소 지원 버전과 현행 서명.
  Future<SchemaWindowInfo> fetchSchemaWindow();
}

/// upsert 사전검증 실패 — 필드 값의 직렬화 길이가 상한을 넘는다 (S3-5 #12839).
///
/// 서버 하드 게이트(`payload_too_large`, 영구 거부)에 걸릴 행을 **pending 에
/// 넣기 전에** 거른다. 넣고 나면 그 행이 매 push 마다 같은 자리에서 거부되어
/// 단말의 동기화가 영구히 막힌다(포이즌 행). 코어 `ArgumentError`(미지 컬럼·
/// 예약 필드)와 같은 계약 위반 축이라 같은 타입 계열로 던진다 — 도메인
/// 리포지토리가 값을 분할(예: 스트로크 포인트 분할)하는 것이 해법이다.
class CoSyncFieldTooLargeError extends ArgumentError {
  /// 위반한 필드와 측정값을 담아 생성한다.
  CoSyncFieldTooLargeError({
    required this.table,
    required this.field,
    required this.length,
    required this.max,
  }) : super.value(
         length,
         'fields',
         '$table.$field serialized length $length > max $max',
       );

  /// 논리 테이블명.
  final String table;

  /// 위반 필드명.
  final String field;

  /// 직렬화 길이 (String 은 문자 수, 그 외는 JSON 문자열 길이).
  final int length;

  /// 상한 — 서버 `coSyncMaxFieldValueChars` 와 같은 값이어야 한다.
  final int max;
}

/// co_offline_sync 클라이언트 런타임 — 스토어·시계·엔진 조립 + sync 트리거.
///
/// 앱 부트스트랩이 1개를 만들어 DI 에 등록한다 (S3-3 #12705 · S3-5 #12839):
///
/// ```dart
/// // transport implements the core SyncTransport contract.
/// final runtime = CoSyncRuntime(
///   database: coSyncDatabase,
///   transport: transport,
///   syncSchema: appSyncSchema,
///   schemaVersion: appSchemaVersion,
///   schemaProbe: schemaProbe, // optional server schema window probe
///   maxFieldValueChars: appMaxFieldValueChars, // match the server limit
///   isAuthenticated: () => authGateway.isAuthenticated,
/// );
/// runtime.bindOnlineStream(statusStream.map((s) => s == .online));
/// // Before clearing account data: await runtime.reset();
/// // After installing login credentials: await runtime.onAuthenticated();
/// ```
///
/// - **오프라인 쓰기는 즉시 로컬 반영**되고 [changes] 로 통지된다. 쓰기 뒤에는
///   [scheduleSync] 가 디바운스 push 를 예약한다(온라인·인증 상태일 때만).
/// - **온라인 복귀(오프라인→온라인 전이)마다** 스키마 창을 사전 대조한 뒤
///   [syncNow] 가 자동 실행된다 (뷰어 MutationQueueFlush 의 연결성 트리거 선례).
/// - **인증 게이트**: [isAuthenticated] 가 false 면 어떤 경로도 서버를 치지
///   않는다 — 미로그인 부팅의 401 pull 과 그 실패 로그를 없앤다. 로그인 직후는
///   [onAuthenticated] 가 트리거다.
/// - 동기화 실패는 삼키지 않고 [lastError] 에 남기며 [onSyncError] 로
///   통지한다 — 침묵 실패 금지, 로그는 건수와 무관하게 남긴다.
/// - 기기 시계가 서버보다 허용 한도 넘게 **뒤처지면** 실패 코드는
///   [kCoSyncClockDriftBehindCode] 다(서버가 거부하는 앞섬은 `clock_drift`).
///   그 회차의 push 는 이미 서버에 적용돼 미전송 건수에서 빠진다(unibook#14051).
class CoSyncRuntime {
  /// [syncSchema]·[schemaVersion] 은 서버 레지스트리의 현행과 같아야 한다
  /// (스키마는 소비 앱에서 관리한다). [schemaProbe] 가 없으면 사전 대조를
  /// 건너뛴다(동기화는 그대로).
  ///
  /// [maxFieldValueChars] 는 upsert 사전검증 상한 — **서버 게이트와 같은 값**
  /// 를 넘긴다. 이 패키지는
  /// 도메인·코덱을 모르므로 값은 호출자(DI)가 준다. [isAuthenticated] 가 없으면
  /// 항상 인증된 것으로 본다(테스트·단일 사용자 도구용) — 앱은 반드시 넘긴다.
  /// [isLifecycleSyncEnabled] 는 새 복귀·주기 polling 의 정책 콜백이다.
  /// 도메인 정책은 앱이 주입하며, 매 트리거에서 읽어 원격 설정 변경을 따른다.
  CoSyncRuntime({
    required CoSyncDatabase database,
    required SyncTransport transport,
    required int maxFieldValueChars,
    required Map<String, List<String>> syncSchema,
    required int schemaVersion,
    SchemaWindowProbe? schemaProbe,
    bool Function()? isAuthenticated,
    bool Function()? isLifecycleSyncEnabled,
    PushFailureClassifier? classifyPushFailure,
    this.writeSyncDebounce = const Duration(seconds: 2),
    this.periodicSyncInterval = const Duration(seconds: 60),
    this.maxQuarantineProbesPerPush = 24,
    this.onSyncError,
    this.onSchemaStatus,
    @visibleForTesting HlcClock Function(String nodeId)? clockFactory,
  }) : _classifyPushFailure = classifyPushFailure ?? classifyCoSyncRowRejection,
       _database = database,
       _transport = transport,
       _syncSchema = syncSchema,
       _schemaVersion = schemaVersion,
       _schemaProbe = schemaProbe,
       _maxFieldValueChars = maxFieldValueChars,
       _isAuthenticated = isAuthenticated ?? _alwaysAuthenticated,
       _onLifecycleSyncEnabled = isLifecycleSyncEnabled ?? _alwaysAuthenticated,
       _clockFactory = clockFactory ?? ((nodeId) => HlcClock(nodeId: nodeId)) {
    if (maxFieldValueChars < 1) {
      throw ArgumentError.value(
        maxFieldValueChars,
        'maxFieldValueChars',
        'must be >= 1',
      );
    }
    if (periodicSyncInterval <= .zero) {
      throw ArgumentError.value(
        periodicSyncInterval,
        'periodicSyncInterval',
        'must be positive',
      );
    }
    store = DriftClientSyncStore(_database);
    // 두 축은 이미 각자 notifier 를 갖고 있다 — 집계 값이 그것들과 어긋나지
    // 않도록 복제 대신 구독한다.
    _schemaStatus.addListener(_publishStatus);
    _quarantinedRowCount.addListener(_publishStatus);
  }

  static bool _alwaysAuthenticated() => true;

  final CoSyncDatabase _database;
  final SyncTransport _transport;
  final Map<String, List<String>> _syncSchema;
  final int _schemaVersion;
  final SchemaWindowProbe? _schemaProbe;
  final int _maxFieldValueChars;
  final bool Function() _isAuthenticated;
  final bool Function() _onLifecycleSyncEnabled;
  final HlcClock Function(String nodeId) _clockFactory;
  final PushFailureClassifier _classifyPushFailure;

  /// 로컬 쓰기 뒤 push 를 예약하는 디바운스 창 — 연속 편집을 한 요청으로 모은다.
  final Duration writeSyncDebounce;

  /// 포그라운드에서 원격 변경을 회수하는 주기 (#13215).
  /// [bindForegroundStream] 으로 앱 생명주기가 연결된 경우에만 예약한다.
  final Duration periodicSyncInterval;

  /// 영구 거부 청크를 행 단위로 좁힐 때 쓸 추가 push 요청 예산 (회차당).
  /// 코어 `CoSyncClient.maxQuarantineProbesPerPush` 로 그대로 전달된다.
  final int maxQuarantineProbesPerPush;

  /// 동기화 실패 통지 (앱이 로깅/모니터링 배선).
  final void Function(Object error, StackTrace stackTrace)? onSyncError;

  /// 스키마 창 사전 대조 결과 통지 — [CoSyncSchemaStatus.appOutdated] 면 앱이
  /// 업데이트 안내를 띄우는 자리.
  final void Function(CoSyncSchemaStatus status, SchemaWindowInfo? window)?
  onSchemaStatus;

  /// drift 스토어 — 도메인 리포지토리가 watch/조회에 사용한다.
  late final DriftClientSyncStore store;

  CoSyncClient? _syncClient;
  Future<CoSyncClient>? _clientInitialization;
  StreamSubscription<bool>? _onlineSubscription;
  StreamSubscription<bool>? _foregroundSubscription;
  bool _isForeground = true;
  bool _disposed = false;
  bool _resetting = false;
  bool _automaticSyncSuspended = false;

  /// 마지막으로 관측한 연결성 원신호 (구독 전이면 null).
  bool? _lastOnline;

  /// 인증 게이트를 통과한 상태에서 본 마지막 온라인 여부 — 전이 판정용.
  bool _wasOnline = false;

  /// [reset] 세대 — 증가하면 그 이전에 시작된 sync 의 결과는 무시된다.
  int _operationGeneration = 0;
  Future<SyncReport?>? _inFlight;
  Future<void>? _automaticInFlight;
  Future<CoSyncSchemaStatus>? _schemaInFlight;
  Timer? _debounceTimer;
  Timer? _periodicTimer;
  int _writeRevision = 0;

  /// 마지막 동기화 실패 (성공 시 null 로 초기화).
  Object? lastError;

  /// 마지막 스키마 창 사전 대조 결과 (초기값 [CoSyncSchemaStatus.unknown]).
  CoSyncSchemaStatus get lastSchemaStatus => _schemaStatus.value;

  /// UI 관찰용 상태. 같은 사전 대조 결과는 다시 통지하지 않는다.
  /// [reset] 시 unknown 으로 돌아가 이전 계정의 안내도 해제된다.
  ValueListenable<CoSyncSchemaStatus> get schemaStatus => _schemaStatus;

  final ValueNotifier<CoSyncSchemaStatus> _schemaStatus = ValueNotifier(
    .unknown,
  );

  /// 현재 격리된 행 수 — 사용자 상태 UI(B5)와 운영 집계의 입력값.
  ///
  /// 스토어가 정본이며 이 값은 그 캐시다. 동기화 회차마다·[reset] 시점에
  /// 다시 읽어 맞춘다 ([refreshQuarantineCount]).
  ValueListenable<int> get quarantinedRowCount => _quarantinedRowCount;

  final ValueNotifier<int> _quarantinedRowCount = ValueNotifier(0);

  /// 행이 새로 격리될 때마다 발화하는 broadcast 스트림.
  ///
  /// ⚠️ 재생·버퍼가 없다 — 구독 이전 격리는 오지 않는다. "지금 몇 건인가" 는
  /// [quarantinedRowCount] 또는 [listQuarantinedRows] 로 읽어야 한다. 이
  /// 스트림은 **새로 생긴 사건**의 통지 전용이다(토스트 등).
  Stream<QuarantinedRow> get quarantineEvents => _quarantineEvents.stream;

  final StreamController<QuarantinedRow> _quarantineEvents =
      StreamController<QuarantinedRow>.broadcast();

  /// 성공한 동기화 회차마다 그 회차의 집계 보고를 발행하는 broadcast 스트림
  /// (unibook#14034).
  ///
  /// [syncNow] 의 반환값과 같은 보고다. 디바운스·주기·온라인 복귀 같은 자동
  /// 트리거는 반환값을 버리므로, 서버의 구체화 보류·거부 건수
  /// ([SyncReport.deferredCount]·[SyncReport.rejectedCount] — null 은 **미상**)를
  /// 관찰하려면 이 스트림을 구독한다.
  ///
  /// ⚠️ 재생·버퍼가 없다 — 구독 이전 회차는 오지 않는다. 실패한 회차는 발행하지
  /// 않는다(그 몫은 [status] 의 `lastFailure` 다).
  Stream<SyncReport> get syncReports => _syncReports.stream;

  final StreamController<SyncReport> _syncReports =
      StreamController<SyncReport>.broadcast();

  /// 관측 가능한 동기화 상태 전부 — 사용자 상태 UI 의 단일 입력값
  /// (unibook#13737 H6).
  ///
  /// [schemaStatus]·[quarantinedRowCount] 를 **포함한다**. 축별 notifier 는
  /// 기존 소비자를 위해 남지만, 새 UI 는 이것 하나만 구독하면 한 프레임 안의
  /// 원자적 스냅샷을 얻는다.
  ///
  /// ⚠️ [CoSyncStatus.pendingCount] 는 스토어를 읽어 갱신되는 **캐시**다.
  /// 런타임 밖에서 스토어를 직접 쓰면 (테스트 픽스처 주입 등) 이 값이
  /// 뒤처진다 — 그때는 [refreshUnsentCount] 로 맞춘다.
  ValueListenable<CoSyncStatus> get status => _status;

  final ValueNotifier<CoSyncStatus> _status = ValueNotifier(
    const CoSyncStatus(),
  );

  int _unsentRowCount = 0;
  bool _syncInFlight = false;
  DateTime? _lastSuccessAt;
  CoSyncFailure? _lastFailure;

  /// [status] 를 현재 축들로 다시 발행한다.
  ///
  /// `ValueNotifier` 는 값이 **달라야** 통지하므로 (CoSyncStatus 는 값 동등성을
  /// 갖는다) 같은 상태의 반복 발행은 리스너를 깨우지 않는다.
  void _publishStatus() {
    if (_disposed) return;
    _status.value = CoSyncStatus(
      pendingCount: _unsentRowCount,
      quarantinedCount: _quarantinedRowCount.value,
      inFlight: _syncInFlight,
      schemaStatus: _schemaStatus.value,
      lastSuccessAt: _lastSuccessAt,
      lastFailure: _lastFailure,
    );
  }

  /// 스토어에서 미전송 행 수를 다시 읽어 [status] 를 맞춘다.
  ///
  /// 로컬 쓰기·동기화 회차·격리 해제마다 런타임이 스스로 부른다. 앱은 부팅
  /// 직후(이전 세션의 잔여 pending 을 화면에 드러내려면) 한 번 부르면 된다.
  Future<void> refreshUnsentCount() async {
    if (_disposed) return;
    final generation = _operationGeneration;
    final int count;
    try {
      count = await store.unsentRowCount();
    } on Object catch (_) {
      // 상태 표시는 부가 기능이다 — 스토어 조회 실패가 쓰기·동기화 경로를
      // 깨뜨리면 안 된다. 다음 갱신 시점에 다시 시도한다.
      return;
    }
    if (!_isCurrent(generation)) return;
    _unsentRowCount = count;
    _publishStatus();
  }

  /// 격리된 행 목록 (사유·시각 포함).
  Future<List<QuarantinedRow>> listQuarantinedRows() => store.quarantinedRows();

  /// 스토어에서 격리 건수를 다시 읽어 [quarantinedRowCount] 를 맞춘다.
  Future<void> refreshQuarantineCount() async {
    if (_disposed) return;
    final generation = _operationGeneration;
    final count = await store.quarantinedRowCount();
    if (!_isCurrent(generation)) return;
    _quarantinedRowCount.value = count;
  }

  /// 한 행의 격리를 풀고 동기화를 예약한다 — 그 행이 격리 상태가 아니었으면
  /// `false`.
  Future<bool> requeueQuarantinedRow(String table, String rowId) async {
    final requeued = await store.requeueQuarantined(table, rowId);
    if (requeued) {
      await refreshQuarantineCount();
      await refreshUnsentCount();
      scheduleSync();
    }
    return requeued;
  }

  /// 격리를 전부 풀고 동기화를 예약한다 (앱·서버 업데이트 후 일괄 재시도).
  Future<int> requeueAllQuarantinedRows() async {
    final requeued = await store.requeueAllQuarantined();
    if (requeued > 0) {
      await refreshQuarantineCount();
      await refreshUnsentCount();
      scheduleSync();
    }
    return requeued;
  }

  void _onRowQuarantined(QuarantinedRow row) {
    _quarantinedRowCount.value = _quarantinedRowCount.value + 1;
    if (!_quarantineEvents.isClosed) _quarantineEvents.add(row);
  }

  /// 이 앱이 아는 스키마 서명 (서버 현행 서명과 대조 대상).
  String get schemaSignature => computeSchemaSignature(_syncSchema);

  /// 테이블 단위 변경 통지 스트림 (S7 반응형 접점).
  Stream<TableChange> get changes => store.changes;

  /// 인증 게이트의 현재 판정 (DI 가 넘긴 콜백을 그대로 묻는다).
  bool get isAuthenticated => _isAuthenticated();

  /// 마지막으로 관측한 온라인 여부 — [bindOnlineStream] 전이면 false.
  bool get isOnline => _lastOnline ?? false;

  /// 로컬 복구 작업이 시작된 계정 세대. await 뒤 [isGenerationCurrent]로 확인한다.
  int get operationGeneration => _operationGeneration;

  /// reset·dispose 이전 작업이 wipe 뒤 로컬 메타데이터를 다시 쓰지 않게 한다.
  /// reset 진행 중에는 새로 캡처한 세대도 사용할 수 없다.
  bool isGenerationCurrent(int capturedGeneration) =>
      _isCurrent(capturedGeneration);

  bool _isCurrent(int generation) =>
      !_disposed && !_resetting && generation == _operationGeneration;

  bool get _canSync =>
      !_disposed && !_resetting && _isAuthenticated() && _lastOnline != false;

  bool get _canAutomaticallySync => _canSync && !_automaticSyncSuspended;

  bool get _canLifecycleSync =>
      _canAutomaticallySync &&
      isOnline &&
      _isForeground &&
      _onLifecycleSyncEnabled();

  void _checkCurrent(int generation) {
    if (!_isCurrent(generation)) throw const CoSyncCancelled();
  }

  /// 이 설치가 서버와 한 번이라도 pull 을 완료했는가 (`pull_cursor` 메타 존재).
  ///
  /// 도메인이 "로컬이 비어 있음" 을 "아직 안 받음" 과 구분하는 게이트로 쓴다
  /// (S3 설계 §3.2). 로그아웃 wipe 뒤에는 다시 false 다.
  Future<bool> get hasSyncedOnce async => await store.loadCursor() != null;

  /// 엔진을 지연 조립한다 — nodeId 는 설치 단위로 영속된다
  /// ([DriftClientSyncStore.ensureNodeId]). [reset] 뒤 첫 조작에서 재조립되며,
  /// 그 사이 wipe 가 있었다면 새 nodeId 를 받는다.
  Future<CoSyncClient> _ensureClient() async {
    final generation = _operationGeneration;
    _checkCurrent(generation);
    final existing = _syncClient;
    if (existing != null) return existing;
    final initializing = _clientInitialization;
    if (initializing != null) return initializing;
    final work = _createClient(generation);
    _clientInitialization = work;
    try {
      return await work;
    } finally {
      if (identical(_clientInitialization, work)) _clientInitialization = null;
    }
  }

  Future<CoSyncClient> _createClient(int generation) async {
    // reset 이 nodeId 조회·생성 중 끼어들면 트랜잭션을 롤백한다. wipe 뒤에
    // 옛 초기화가 nodeId 를 다시 기록하거나 새 세대 엔진으로 등록하지 않는다.
    final nodeId = await _database.transaction(() async {
      _checkCurrent(generation);
      final value = await store.ensureNodeId();
      _checkCurrent(generation);
      return value;
    });
    _checkCurrent(generation);
    final client = CoSyncClient(
      // 세대 스코프 — reset 이후 옛 엔진의 쓰기(pull 병합·커서·pending 해제)는
      // 스토어에 닿지 않는다. 코어 sync 에는 취소가 없으므로 wipe 뒤에 옛 계정
      // 상태가 되살아나는 경합을 여기서 끊는다.
      store: _GenerationScopedStore(
        store,
        _database,
        () => _checkCurrent(generation),
      ),
      transport: _GenerationScopedTransport(_transport, () {
        _checkCurrent(generation);
        if (!_canSync) throw const CoSyncCancelled();
      }),
      clock: _clockFactory(nodeId),
      syncSchema: _syncSchema,
      schemaVersion: _schemaVersion,
      maxQuarantineProbesPerPush: maxQuarantineProbesPerPush,
      classifyPushFailure: _classifyPushFailure,
      onRowQuarantined: _onRowQuarantined,
    );
    _syncClient = client;
    // 엔진을 새로 만든 시점의 잔여 격리(이전 실행에서 남은 것)를 드러낸다 —
    // 건수와 무관하게 읽는다. 실패해도 동기화를 막지 않는다.
    unawaited(refreshQuarantineCount());
    return client;
  }

  /// 로컬 쓰기 — 오프라인에서도 즉시 반영된다. 쓰기 뒤 [scheduleSync].
  ///
  /// 필드 직렬화 길이가 상한을 넘으면 [CoSyncFieldTooLargeError] — pending 에
  /// 들어가기 **전에** 거른다(서버 영구 거부 행이 단말을 막는 것을 방지).
  Future<void> upsert(
    String table,
    String rowId,
    Map<String, Object?> fields,
  ) async {
    _validateFieldSizes(table, fields);
    await _write((client) => client.upsert(table, rowId, fields));
  }

  /// 행 삭제 (tombstone). 쓰기 뒤 [scheduleSync].
  Future<void> delete(String table, String rowId) async {
    await _write((client) => client.delete(table, rowId));
  }

  /// Atomically writes [fields] with a tombstone, including for a missing row.
  ///
  /// Uses the same field-size limit as [upsert], core schema/reserved-field
  /// validation, account-generation guards, notifications and [scheduleSync].
  /// Omitted fields are preserved; no intermediate live row or restore occurs.
  Future<void> deleteWithFields(
    String table,
    String rowId,
    Map<String, Object?> fields,
  ) async {
    final snapshot = Map<String, Object?>.of(fields);
    _validateFieldSizes(table, snapshot);
    await _write((client) => client.deleteWithFields(table, rowId, snapshot));
  }

  /// 삭제된 행 되살림 (`$deleted: false`, 코어 `restore` 위임). 쓰기 뒤 [scheduleSync].
  Future<void> restore(String table, String rowId) async {
    await _write((client) => client.restore(table, rowId));
  }

  Future<void> _write(Future<void> Function(CoSyncClient) write) async {
    final generation = _operationGeneration;
    try {
      final client = await _ensureClient();
      _checkCurrent(generation);
      await write(client);
      _checkCurrent(generation);
      _writeRevision++;
      // "아직 안 올라감 N건" 은 쓰기 직후에 올라가야 한다 — 동기화가 돌기를
      // 기다리면 오프라인에서 영원히 0 으로 보인다(이 표시의 존재 이유).
      await refreshUnsentCount();
      scheduleSync();
    } on CoSyncCancelled {
      // 로그아웃 중 옛 계정 조작을 새 DB 로 가져오지 않는다.
    }
  }

  /// 행 읽기 (tombstone 해석 포함).
  Future<RowView?> read(String table, String rowId) async =>
      (await _ensureClient()).read(table, rowId);

  /// 서버 `_validatePushLimits` 와 같은 식 — String 은 길이가 곧 직렬화 길이의
  /// 하한, 그 외는 `jsonEncode` 결과 길이 (`co_sync_codec.serializedFieldLength`
  /// 와 동일해야 한다).
  void _validateFieldSizes(String table, Map<String, Object?> fields) {
    for (final entry in fields.entries) {
      final value = entry.value;
      final length = value is String ? value.length : jsonEncode(value).length;
      if (length > _maxFieldValueChars) {
        throw CoSyncFieldTooLargeError(
          table: table,
          field: entry.key,
          length: length,
          max: _maxFieldValueChars,
        );
      }
    }
  }

  /// 로컬 쓰기 뒤 push 를 예약한다 — [debounce](기본 [writeSyncDebounce]) 안의
  /// 연속 쓰기는 마지막 한 번으로 합쳐진다.
  ///
  /// 발화 시점에 오프라인이거나 미인증이면 no-op 이다 — 그 경우는 온라인 전이
  /// ([bindOnlineStream])·로그인([onAuthenticated])이 잔여 pending 을 회수한다.
  void scheduleSync({Duration? debounce}) {
    if (_disposed || _resetting || _automaticSyncSuspended) return;
    final generation = _operationGeneration;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce ?? writeSyncDebounce, () {
      _debounceTimer = null;
      if (!_isCurrent(generation) || !isOnline || !_canAutomaticallySync) {
        return;
      }
      unawaited(syncNow());
    });
  }

  /// push→pull 수행. 동시 요청은 합류하고 진행 중 쓰기는 후속 회차로 회수한다.
  /// 실패는 던지지 않고 null 반환 + [lastError] 기록.
  ///
  /// 실패를 삼키는 이유: 연결성 트리거 경로에서 예외가 새면 구독이 죽어
  /// **이후 복귀 트리거까지 전부 소실**되기 때문이다. 대신 [onSyncError] 와
  /// [lastError] 로 반드시 드러낸다.
  ///
  /// 미인증이면 아무것도 하지 않고 null 이다(에러 아님). 실행 중 [reset] 이
  /// 일어나면 그 결과는 버려진다(성공·실패 어느 쪽도 상태에 남지 않는다).
  Future<SyncReport?> syncNow() async {
    if (!_canSync || lastSchemaStatus == .appOutdated) return null;
    final existing = _inFlight;
    if (existing != null) return existing;
    final work = _syncGuarded(_operationGeneration);
    _inFlight = work;
    _syncInFlight = true;
    _publishStatus();
    try {
      return await work;
    } finally {
      if (identical(_inFlight, work)) _inFlight = null;
      // 합류한 호출은 자기 회차가 아니므로 진행 표시를 끄지 않는다.
      if (_inFlight == null) {
        _syncInFlight = false;
        _publishStatus();
      }
    }
  }

  Future<SyncReport?> _syncGuarded(int generation) async {
    try {
      final client = await _ensureClient();
      _checkCurrent(generation);
      SyncReport? total;
      int revision;
      do {
        if (!_canSync) return null;
        revision = _writeRevision;
        _debounceTimer?.cancel();
        _debounceTimer = null;
        final report = await client.sync();
        _checkCurrent(generation);
        // 보류·거부 건수는 한 회차라도 미상이면 합도 미상이다 (unibook#14034).
        total = total?.combinedWith(report) ?? report;
        lastError = null;
        // 합류한 디바운스가 push 스냅샷 이후의 쓰기를 잃지 않게 한다.
        // 단순 트리거 합류는 추가 왕복을 만들지 않고 새 쓰기만 한 번 더 민다.
      } while (revision != _writeRevision);
      // 스토어가 정본이다 — 콜백 누적만 믿으면 requeue·로컬 쓰기로 풀린 몫이
      // 반영되지 않는다.
      await refreshQuarantineCount();
      _lastSuccessAt = DateTime.now();
      _lastFailure = null;
      await refreshUnsentCount();
      _publishStatus();
      if (_isCurrent(generation) && !_syncReports.isClosed) {
        _syncReports.add(total);
      }
      return total;
    } on CoSyncCancelled {
      return null;
    } on Object catch (error, stackTrace) {
      if (!_isCurrent(generation)) return null;
      lastError = error;
      // `ClockDriftException`(코어 시계가 서버 스탬프를 거부 = 단말 뒤처짐)은
      // `CoSyncFailure.from` 이 `clock_drift_behind` 로 가른다 — 계약 §7.2 ② 의
      // 명시 분기를 분류기 한 곳에 둔다(두 곳이면 한쪽이 죽은 코드가 된다).
      // push 는 이미 확정돼 있으니 아래 미전송 건수 갱신이 그것을 드러낸다.
      _lastFailure = CoSyncFailure.from(error, at: DateTime.now());
      // 실패해도 미전송 건수는 바뀌었을 수 있다 — 청크 일부가 올라간 뒤
      // 뒤 청크가 거부된 경우다. 성공 경로에만 두면 그 몫이 안 보인다.
      await refreshUnsentCount();
      _publishStatus();
      onSyncError?.call(error, stackTrace);
      return null;
    }
  }

  /// 서버 스키마 창과 이 앱의 버전·서명을 대조한다.
  ///
  /// 조회 실패(오프라인·서버 미배포 등)는 [CoSyncSchemaStatus.unknown] 이며
  /// 예외를 던지지 않는다 — 사전 대조는 UX 용이라 동기화를 막지 않는다.
  /// 결과는 [lastSchemaStatus] 와 [onSchemaStatus] 로 드러낸다.
  Future<CoSyncSchemaStatus> verifySchemaWindow() async {
    if (!_canSync) return .unknown;
    final existing = _schemaInFlight;
    if (existing != null) return existing;
    final work = _verifySchemaWindow(_operationGeneration);
    _schemaInFlight = work;
    try {
      return await work;
    } finally {
      if (identical(_schemaInFlight, work)) _schemaInFlight = null;
    }
  }

  Future<CoSyncSchemaStatus> _verifySchemaWindow(int generation) async {
    final probe = _schemaProbe;
    if (probe == null) return lastSchemaStatus;
    SchemaWindowInfo? window;
    CoSyncSchemaStatus status;
    try {
      window = await probe.fetchSchemaWindow();
      if (!_isCurrent(generation) || !_canSync) return .unknown;
      status = classifySchemaWindow(
        window,
        clientVersion: _schemaVersion,
        clientSignature: schemaSignature,
      );
    } on Object catch (error, stackTrace) {
      if (!_isCurrent(generation) || !_canSync) return .unknown;
      status = CoSyncSchemaStatus.unknown;
      onSyncError?.call(error, stackTrace);
    }
    _schemaStatus.value = status;
    onSchemaStatus?.call(status, window);
    return status;
  }

  /// 서버 창 대비 이 앱의 위치를 분류한다 (순수 함수 — 테스트·재사용용).
  ///
  /// 서버 `SchemaRegistry.resolve` 와 같은 우선순위다: **현행 서명 일치가
  /// 정본**, 그다음 버전 번호로 아래/위/충돌을 가른다. 창 안의 구 버전
  /// (min ≤ v < current) 은 서명이 현행과 다른 것이 정상이므로 [compatible] 이다.
  static CoSyncSchemaStatus classifySchemaWindow(
    SchemaWindowInfo window, {
    required int clientVersion,
    required String clientSignature,
  }) {
    if (clientSignature == window.currentSignature) {
      return CoSyncSchemaStatus.compatible;
    }
    if (clientVersion < window.minSupportedVersion) {
      return CoSyncSchemaStatus.appOutdated;
    }
    if (clientVersion > window.currentVersion) {
      return CoSyncSchemaStatus.serverBehind;
    }
    if (clientVersion == window.currentVersion) {
      return CoSyncSchemaStatus.signatureConflict;
    }
    return CoSyncSchemaStatus.compatible;
  }

  /// 온라인 여부 스트림을 구독해 **오프라인→온라인 전이마다** 스키마 창을
  /// 사전 대조한 뒤 [syncNow] 를 실행한다. 첫 온라인 신호에도 1회 실행한다
  /// (부팅 직후 잔여 pending 회수).
  ///
  /// 미인증 상태의 신호는 원신호([isOnline])만 갱신하고 전이 판정에 쓰지
  /// 않는다 — 그래서 로그인 뒤 첫 온라인 신호(또는 [onAuthenticated])가 다시
  /// 전이로 잡힌다.
  ///
  /// 사전 대조가 [CoSyncSchemaStatus.appOutdated] 면 그 회차의 동기화는
  /// 건너뛴다 — 어차피 서버가 `schema_outdated` 로 거부하므로 실패 로그만
  /// 쌓인다. 로컬 쓰기와 pending 은 그대로 보존되어 앱 업데이트 후 회수된다.
  void bindOnlineStream(Stream<bool> online) {
    if (_disposed) return;
    unawaited(_onlineSubscription?.cancel());
    _wasOnline = false;
    _onlineSubscription = online.listen((onlineNow) {
      _lastOnline = onlineNow;
      _refreshPeriodicTimer();
      if (!_isAuthenticated()) return;
      final becameOnline = onlineNow && !_wasOnline;
      _wasOnline = onlineNow;
      if (becameOnline) unawaited(_onBecameOnline());
    });
  }

  /// 로그인 트리거 — AuthBloc 이 `Authenticated` 를 emit 한 **직후**(계정 전환
  /// wipe 뒤) 호출한다. 온라인이면(또는 연결성 미구독이면) 사전 대조 → sync.
  /// 오프라인이면 no-op — 온라인 전이가 처리한다.
  Future<void> onAuthenticated() async {
    if (_disposed || _resetting) return;
    _automaticSyncSuspended = false;
    _refreshPeriodicTimer();
    if (!_isAuthenticated()) return;
    if (_lastOnline == false) return;
    if (_lastOnline ?? false) _wasOnline = true;
    await _onBecameOnline();
  }

  Future<void> _onBecameOnline({bool fromLifecycle = false}) async {
    if (!_canAutomaticallySync) return;
    if (fromLifecycle && !_canLifecycleSync) return;
    final existing = _automaticInFlight;
    if (existing != null) return existing;
    final work = _runAutomaticSync(
      _operationGeneration,
      fromLifecycle: fromLifecycle,
    );
    _automaticInFlight = work;
    try {
      await work;
    } finally {
      if (identical(_automaticInFlight, work)) _automaticInFlight = null;
    }
  }

  Future<void> _runAutomaticSync(
    int generation, {
    required bool fromLifecycle,
  }) async {
    final status = await verifySchemaWindow();
    if (!_isCurrent(generation) || !_canAutomaticallySync) return;
    if (fromLifecycle && !_canLifecycleSync) return;
    if (status == CoSyncSchemaStatus.appOutdated) return;
    await syncNow();
  }

  /// 앱 생명주기를 연결한다. 복귀 때 즉시 동기화하고 전경에서만 주기를 돈다.
  ///
  /// [initiallyForeground] 은 스트림 구독 전의 실제 앱 상태다. 초기값 설정은
  /// 로그인/온라인 트리거와 중복 왕복을 만들지 않고 타이머만 준비한다.
  /// `isLifecycleSyncEnabled` 는 복귀·매 tick 마다 읽는다 — 플래그 전부 OFF 면
  /// 새 polling 만 멈추고 수동 동기화·온라인 복귀·기존 pending 회수는 유지한다.
  void bindForegroundStream(
    Stream<bool> foreground, {
    required bool initiallyForeground,
  }) {
    if (_disposed) return;
    unawaited(_foregroundSubscription?.cancel());
    _isForeground = initiallyForeground;
    _foregroundSubscription = foreground.listen((isForeground) {
      final resumed = isForeground && !_isForeground;
      _isForeground = isForeground;
      _refreshPeriodicTimer();
      if (resumed && _onLifecycleSyncEnabled()) {
        unawaited(_onBecameOnline(fromLifecycle: true));
      }
    });
    _refreshPeriodicTimer();
  }

  void _refreshPeriodicTimer() {
    if (_foregroundSubscription == null ||
        !_isForeground ||
        !isOnline ||
        !_canAutomaticallySync) {
      _periodicTimer?.cancel();
      _periodicTimer = null;
      return;
    }
    // 플래그가 모두 OFF 여도 timer 는 유지한다 — 원격 개방 뒤 다음 tick 이
    // 새 값을 읽어야 한다. 서버 호출 직전에만 도메인 정책을 묻는다.
    _periodicTimer ??= Timer.periodic(periodicSyncInterval, (_) {
      if (_canLifecycleSync) {
        unawaited(_onBecameOnline(fromLifecycle: true));
      }
    });
  }

  /// 로그아웃·계정 전환 — 엔진을 폐기하고 진행 중인 sync 의 결과를 무시한다.
  ///
  /// `CacheRegistry.registerBeforeClear(runtime.reset)` 로 등록해 DB wipe
  /// **앞**에 실행되게 한다: wipe 뒤에 옛 계정의 sync 가 결과를 저장하거나
  /// 옛 nodeId 로 시계를 시드하는 경합을 막는다. 진행 중 sync 는
  /// [inFlightTimeout] 까지만 기다린다 — 그 이상은 wipe 를 막지 않는다
  /// (`CacheRegistry` 의 DB 당 3초 상한과 같은 판단, #6668).
  Future<void> reset({
    Duration inFlightTimeout = const Duration(seconds: 3),
  }) async {
    if (_disposed) return;
    _operationGeneration++;
    final generation = _operationGeneration;
    _resetting = true;
    _automaticSyncSuspended = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _syncClient = null;
    final initialization = _clientInitialization;
    _clientInitialization = null;
    _wasOnline = false;
    lastError = null;
    _lastFailure = null;
    _lastSuccessAt = null;
    _unsentRowCount = 0;
    _syncInFlight = false;
    _schemaStatus.value = .unknown;
    _quarantinedRowCount.value = 0;
    // 두 notifier 가 이미 unknown/0 이면 리스너가 안 깨므로 직접 발행한다 —
    // 옛 계정의 "대기 N건" 이 다음 계정 화면에 남는 것을 막는다.
    _publishStatus();
    final inFlight = _inFlight;
    _inFlight = null;
    _automaticInFlight = null;
    _schemaInFlight = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    try {
      await Future.wait<Object?>([
        ?initialization,
        ?inFlight,
      ]).timeout(inFlightTimeout);
    } on Object catch (_) {
      // 상한 초과·실패 어느 쪽도 wipe 를 막지 않는다 — 결과는 세대 검사가 버린다.
    } finally {
      if (generation == _operationGeneration) _resetting = false;
    }
  }

  /// 구독 해제 + 스토어/DB 정리.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _operationGeneration++;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    await _onlineSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    _schemaStatus.removeListener(_publishStatus);
    _quarantinedRowCount.removeListener(_publishStatus);
    _schemaStatus.dispose();
    _quarantinedRowCount.dispose();
    _status.dispose();
    await _quarantineEvents.close();
    await _syncReports.close();
    await store.dispose();
  }
}

/// 이전 세대 작업은 오류 로그 없이 종료한다 — 사용자 동기화 실패가 아니다.
class CoSyncCancelled implements Exception {
  /// 이전 계정 또는 폐기된 런타임의 작업임을 표시한다.
  const CoSyncCancelled();

  @override
  String toString() =>
      'CoSyncCancelled: runtime generation is no longer active';
}

/// 요청 직전·응답 직후에 인증과 세대를 재확인한다. 진행 중 요청 자체는
/// 취소할 수 없지만 옛 엔진이 새 계정 자격으로 후속 push/pull 을 보내지 못한다.
class _GenerationScopedTransport implements SyncTransport {
  const _GenerationScopedTransport(this._inner, this._onCheckCurrent);

  final SyncTransport _inner;
  final void Function() _onCheckCurrent;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    _onCheckCurrent();
    final response = await _inner.push(request);
    _onCheckCurrent();
    return response;
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    _onCheckCurrent();
    final response = await _inner.pull(request);
    _onCheckCurrent();
    return response;
  }
}

/// 세대가 지난 엔진은 읽기·쓰기 모두 종료한다. 쓰기는 트랜잭션 내부에서
/// 시작·완료를 확인하므로 reset 이 DB await 사이에 끼어들어도 롤백된다.
/// ⚠️ [QuarantineCapableStore] 도 함께 위임한다 — 위임하지 않으면 안쪽
/// 스토어가 지원해도 코어가 격리를 켜지 못해 조용히 종전 동작으로 돌아간다.
class _GenerationScopedStore
    implements ClientSyncStore, QuarantineCapableStore {
  const _GenerationScopedStore(
    this._inner,
    this._database,
    this._onCheckCurrent,
  );

  /// [QuarantineCapableStore] 도 함께 구현한 스토어여야 한다 (런타임은 항상
  /// `DriftClientSyncStore` 를 넘긴다).
  final ClientSyncStore _inner;
  final CoSyncDatabase _database;
  final void Function() _onCheckCurrent;

  Future<T> _read<T>(Future<T> Function() read) async {
    _onCheckCurrent();
    final result = await read();
    _onCheckCurrent();
    return result;
  }

  Future<void> _write(AsyncCallback write) {
    _onCheckCurrent();
    return _database.transaction(() async {
      _onCheckCurrent();
      await write();
      _onCheckCurrent();
    });
  }

  @override
  Stream<TableChange> get changes => _inner.changes;

  @override
  Future<RowState?> getRow(String table, String rowId) =>
      _read(() => _inner.getRow(table, rowId));

  @override
  Future<void> putRow(
    String table,
    RowState state, {
    required ChangeOrigin origin,
    required bool pending,
  }) => _write(
    () => _inner.putRow(table, state, origin: origin, pending: pending),
  );

  @override
  Future<List<PendingRow>> pendingRows() => _read(_inner.pendingRows);

  @override
  Future<List<PendingRow>> unsentRows() => _read(_quarantine.unsentRows);

  @override
  Future<void> clearPending(String table, String rowId, Hlc upTo) =>
      _write(() => _inner.clearPending(table, rowId, upTo));

  @override
  Future<String?> loadCursor() => _read(_inner.loadCursor);

  @override
  Future<void> saveCursor(String cursor) =>
      _write(() => _inner.saveCursor(cursor));

  @override
  Future<Hlc?> maxHlc() => _read(_inner.maxHlc);

  QuarantineCapableStore get _quarantine => _inner as QuarantineCapableStore;

  @override
  Future<void> quarantineRow(
    String table,
    String rowId, {
    required QuarantineReason reason,
    required DateTime at,
  }) => _write(
    () => _quarantine.quarantineRow(table, rowId, reason: reason, at: at),
  );

  @override
  Future<List<QuarantinedRow>> quarantinedRows() =>
      _read(_quarantine.quarantinedRows);

  @override
  Future<bool> requeueQuarantined(String table, String rowId) async {
    var requeued = false;
    await _write(() async {
      requeued = await _quarantine.requeueQuarantined(table, rowId);
    });
    return requeued;
  }

  @override
  Future<int> requeueAllQuarantined() async {
    var requeued = 0;
    await _write(() async {
      requeued = await _quarantine.requeueAllQuarantined();
    });
    return requeued;
  }

  @override
  Future<int> quarantinedRowCount() => _read(_quarantine.quarantinedRowCount);

  @override
  Future<int> unsentRowCount() => _read(_quarantine.unsentRowCount);
}
