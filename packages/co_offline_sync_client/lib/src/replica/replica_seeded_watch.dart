import 'dart:async';

import 'package:co_offline_sync_client/src/replica/replica_puller.dart';

/// replica watch 에 **시드 게이트**를 씌운 스트림 (S6-3 에서 확립 ·
/// S7-3 kobic#12754 에서 공용화).
///
/// 구독하면:
/// 1. [watch] 를 열어 로컬 스냅샷을 받고, 동시에 [puller] 로 [domains] 를
///    증분 pull 시동한다 — 종전 1회성 서버 호출과 같은 신선도 보장. 반영은
///    watch 재emit 으로 자동 전달된다.
/// 2. 값이 **비어 있지 않으면 즉시** 내보낸다 — 오프라인 콜드스타트의 핵심
///    경로다 (마지막 pull 스냅샷으로 화면이 선다, kobic#11909).
/// 3. 서버로 한 번도 확인되지 않은 **빈** 값은 내보내지 않는다. [domains]
///    전부의 pull 이 성공한 뒤에야 빈 값도 내보낸다 — 신규 사용자의 최초
///    온라인 진입에서 "0 → N" 깜빡임을 막고, 오프라인 + replica 미시드(pull
///    실패)면 종전 실패 의미론(상태 무변경)과 같아진다.
///
/// [isEmpty] 가 게이트의 판정이다 — 목록은 `list.isEmpty`, 카운트는
/// `count == 0`. 판정을 소비측에 맡기는 이유는 "비어 있음" 의 형태가 타입마다
/// 다르기 때문이다.
///
/// 구독 해제 시 watch 를 끊고 컨트롤러를 닫는다 — 닫아 두면 지연 도착한 pull
/// 완료 콜백의 add 가 `isClosed` 가드에 걸려 버퍼에 쌓이지 않는다.
///
/// [puller] 에 [domains] 가 등록돼 있지 않으면 스트림 에러로 드러난다
/// ([ReplicaPuller.pull] 의 [ArgumentError]) — 배선 누락이 "빈 목록" 으로
/// 위장되지 않게 한다.
Stream<T> replicaSeededWatch<T>({
  required Stream<T> Function() watch,
  required ReplicaPuller puller,
  required Set<String> domains,
  required bool Function(T value) isEmpty,
}) {
  // `late` 필수 — 아래 클로저(emitIfReady)가 대입문보다 앞에서 참조해
  // definite-assignment 분석이 `late` 없이는 컴파일을 거부한다.
  // ignore: avoid-unnecessary-local-late
  late final StreamController<T> controller;
  StreamSubscription<T>? subscription;
  T? latest;
  var hasLatest = false;
  var pullSucceeded = false;

  void emitIfReady() {
    if (!hasLatest) return;
    final value = latest as T;
    if (isEmpty(value) && !pullSucceeded) return;
    if (!controller.isClosed) controller.add(value);
  }

  controller = StreamController<T>(
    onListen: () {
      subscription = watch().listen((value) {
        latest = value;
        hasLatest = true;
        emitIfReady();
      }, onError: controller.addError);
      unawaited(
        puller
            .pull(domains)
            .then((_) {
              pullSucceeded = domains.every(
                (domain) => !puller.lastErrors.containsKey(domain),
              );
              emitIfReady();
            })
            .catchError((Object error, StackTrace stackTrace) {
              if (!controller.isClosed) controller.addError(error, stackTrace);
            }),
      );
    },
    onCancel: () async {
      await subscription?.cancel();
      await controller.close();
    },
  );
  return controller.stream;
}
