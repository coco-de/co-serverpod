import 'dart:async';

import 'package:co_sync/src/co_sync_runtime.dart';
import 'package:co_sync/src/replica/replica_puller.dart';

/// co_sync 논리 테이블(⋈ replica) watch 에 **2축 시드 게이트**를 씌운 스트림
/// (S3-9b #12963, 설계 §6.4 "S3-9b 읽기 원천").
///
/// `replicaSeededWatch` 의 자매본이다 — 그쪽은 좌변이 replica 라 "그 도메인을
/// 한 번이라도 pull 했는가"(도메인별 커서) 하나로 빈 목록과 미수신을 갈랐다.
/// 좌변이 co_sync 논리 테이블이 되면 그 판정을 그대로 쓸 수 없다: co_sync 는
/// **설치 단위 단일 커서**(`hasSyncedOnce`)라 도메인별 시드 여부가 없고,
/// 조인 상대(replica)의 커서는 좌변의 시드 여부를 말하지 않는다.
///
/// 그래서 판정은 **두 축의 OR** 다 (🧑 제품 결정 2026-09-05):
///
/// | co_sync `hasSyncedOnce` | replica pull 성공 | 빈 값 |
/// |---|---|---|
/// | false | false | **미수신 — 내보내지 않는다** |
/// | 그 외 | | 내보낸다 (진짜 빈 목록) |
///
/// 구독하면:
/// 1. [watch] 를 열어 로컬 스냅샷을 받는다. 값이 **비어 있지 않으면 즉시**
///    내보낸다 — 오프라인 콜드스타트의 핵심 경로다(마지막 로컬 상태로 화면이
///    선다).
/// 2. 동시에 **sync → replica pull 순서로** 서버 왕복을 시동한다. 순서가
///    의도다: 오프라인에서 만든 로컬 행(찜)은 push 가 서버에 착지한 **뒤에야**
///    조인 상대(도서 메타)의 멤버십에 들어가므로, pull 을 먼저 하면 그 행의
///    메타가 내려오지 않아 플레이스홀더가 다음 트리거까지 남는다.
///    `syncNow` 는 [runtime] 이 온라인일 때만 부르고(오프라인 실패 로그를 만들지
///    않기 위함 — 진행 중 요청이 있으면 합류한다), pull 은 항상 시동한다
///    (실패는 [ReplicaPuller.lastErrors] 로 판정 재료가 된다).
/// 3. 두 축 중 하나라도 시드되면 빈 값도 내보낸다.
///
/// [gapKeys] 는 **조인 상대가 아직 없는 행**을 식별하는 훅이다 — 값에서 뽑은
/// 키 집합이 비어 있지 않고 **직전에 트리거한 집합과 다르면** 2 를 다시
/// 시동한다(sync → pull). 같은 집합에 반복 시동하지 않는 이유는 pull 이 성공해도
/// 메타가 오지 않는 행(projector 가 거부한 행 등)에 무한
/// 왕복을 만들지 않기 위함이다. 집합이 바뀌면(새 행이 늘거나 일부가 채워지면)
/// 다시 시동한다. 도메인 지식은 없다 — 무엇이 "갭"인지는 호출자가 정한다.
///
/// 구독 해제 시 watch 를 끊고 컨트롤러를 닫는다 — 닫힌 뒤 도착한 왕복 완료
/// 콜백의 add 는 `isClosed` 가드에 걸려 버퍼에 쌓이지 않는다.
///
/// [puller] 에 [replicaDomains] 가 등록돼 있지 않으면 스트림 에러로 드러난다
/// ([ReplicaPuller.pull] 의 [ArgumentError]) — 배선 누락이 "빈 목록" 으로
/// 위장되지 않게 한다.
Stream<T> localFirstSeededWatch<T>({
  required Stream<T> Function() watch,
  required CoSyncRuntime runtime,
  required ReplicaPuller puller,
  required Set<String> replicaDomains,
  required bool Function(T value) isEmpty,
  Set<Object> Function(T value)? gapKeys,
}) {
  // `late` 필수 — 아래 클로저가 대입문보다 앞에서 참조해 definite-assignment
  // 분석이 `late` 없이는 컴파일을 거부한다 (`replicaSeededWatch` 와 동일).
  // ignore: avoid-unnecessary-local-late
  late final StreamController<T> controller;
  StreamSubscription<T>? subscription;
  T? latest;
  var hasLatest = false;
  var localSeeded = false;
  var replicaSeeded = false;
  T? lastEmitted;
  var hasEmitted = false;
  Set<Object>? lastTriggeredGap;

  void emitIfReady() {
    if (!hasLatest) return;
    final value = latest as T;
    if (isEmpty(value) && !localSeeded && !replicaSeeded) return;
    // 시드 판정이 늦게 뒤집혀도 **같은 스냅샷 객체**를 두 번 내보내지 않는다 —
    // watch 재emit(새 객체)만 흘리고, 판정 갱신은 억제돼 있던 값을 풀 때만 emit 한다.
    if (hasEmitted && identical(lastEmitted, value)) return;
    if (controller.isClosed) return;
    lastEmitted = value;
    hasEmitted = true;
    controller.add(value);
  }

  Future<void> refreshLocalSeeded() async {
    // 조회 실패는 "미시드" 로 둔다 — 판정 불가를 통과로 읽지 않는다.
    try {
      localSeeded = localSeeded || await runtime.hasSyncedOnce;
    } on Object catch (error, stackTrace) {
      if (!controller.isClosed) controller.addError(error, stackTrace);
    }
  }

  /// sync → pull. 순서가 계약이다 (dartdoc 2).
  Future<void> roundTrip() async {
    if (runtime.isOnline) {
      // 실패는 runtime 이 삼키고 lastError/onSyncError 로 드러낸다.
      await runtime.syncNow();
    }
    await refreshLocalSeeded();
    try {
      await puller.pull(replicaDomains);
      replicaSeeded =
          replicaSeeded ||
          replicaDomains.every(
            (domain) => !puller.lastErrors.containsKey(domain),
          );
    } on Object catch (error, stackTrace) {
      if (!controller.isClosed) controller.addError(error, stackTrace);
    }
    emitIfReady();
  }

  void maybeTriggerForGaps(T value) {
    final resolveGap = gapKeys;
    if (resolveGap == null) return;
    final gap = resolveGap(value);
    if (gap.isEmpty) {
      // 갭이 닫혔다 — 다음에 새 갭이 생기면 다시 시동할 수 있게 초기화한다.
      lastTriggeredGap = null;
      return;
    }
    final previous = lastTriggeredGap;
    if (previous != null &&
        previous.length == gap.length &&
        previous.containsAll(gap)) {
      return;
    }
    lastTriggeredGap = Set.unmodifiable(gap);
    unawaited(roundTrip());
  }

  controller = StreamController<T>(
    onListen: () {
      subscription = watch().listen((value) {
        latest = value;
        hasLatest = true;
        emitIfReady();
        maybeTriggerForGaps(value);
      }, onError: controller.addError);
      unawaited(refreshLocalSeeded().then((_) => emitIfReady()));
      unawaited(roundTrip());
    },
    onCancel: () async {
      await subscription?.cancel();
      await controller.close();
    },
  );
  return controller.stream;
}
