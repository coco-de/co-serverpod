import 'dart:async';

import 'package:co_sync/src/replica/replica_store.dart';

/// 도메인 하나의 pull 응답 한 페이지.
class ReplicaPage {
  /// 기본 생성자.
  const ReplicaPage({
    required this.rows,
    required this.nextCursor,
    required this.hasMore,
  });

  /// 이 페이지의 행 변경들.
  final List<ReplicaRowChange> rows;

  /// 다음 pull 의 시작 커서 (서버 발급 opaque 값).
  final String nextCursor;

  /// 이어서 받을 페이지가 남았는가.
  final bool hasMore;
}

/// 도메인 하나를 증분 조회하는 서버 접점 (S6-2 가 실구현을 배선한다).
///
/// [cursor] 가 `null` 이면 최초 전량 pull 이다.
typedef ReplicaDomainFetch = Future<ReplicaPage> Function(String? cursor);

/// replica 증분 pull 실행기 (S6-1, #12720).
///
/// 등록된 도메인들을 커서 기반으로 증분 pull 해 [ReplicaStore] 에 반영한다.
/// 트리거는 `CoSyncRuntime.bindOnlineStream` 과 같은 **오프라인→온라인 전이**
/// 패턴이며, 실패는 삼키되 [lastErrors]/[onError] 로 반드시 노출한다
/// (연결성 구독이 예외로 죽으면 이후 트리거가 전부 소실되기 때문 —
/// `CoSyncRuntime.syncNow` 와 같은 근거).
class ReplicaPuller {
  /// [domains] 는 도메인명 → 증분 조회 함수. [onError] 는 도메인 단위 실패
  /// 통지(앱이 로깅 배선).
  ReplicaPuller({
    required ReplicaStore store,
    required Map<String, ReplicaDomainFetch> domains,
    this.onError,
    this.maxPagesPerDomain = 50,
  }) : _store = store,
       _domains = Map.unmodifiable(domains);

  final ReplicaStore _store;
  final Map<String, ReplicaDomainFetch> _domains;

  /// 도메인 단위 실패 통지 (도메인명·에러·스택).
  final void Function(String domain, Object error, StackTrace stackTrace)?
  onError;

  /// 한 번의 pull 에서 도메인당 최대 페이지 수 — 서버 결함(`hasMore` 고착)이
  /// 무한 루프가 되지 않게 하는 상한. 도달 시 남은 분은 다음 트리거로 미룬다.
  final int maxPagesPerDomain;

  StreamSubscription<bool>? _onlineSubscription;
  bool _wasOnline = false;
  final Map<String, Future<void>> _inFlightByDomain = {};
  final Map<String, Object> _lastErrors = {};

  /// 마지막 pull 에서 실패한 도메인 → 에러 (전부 성공 시 빈 맵).
  ///
  /// **도메인별로** 갱신된다 — 부분 pull([pull])이 다른 도메인의 기록을
  /// 지우지 않고, 어떤 도메인의 성공은 그 도메인의 기록만 지운다. 시드
  /// 게이트(`replicaSeededWatch`)는 자기 도메인 키만 본다.
  Map<String, Object> get lastErrors => Map.unmodifiable(_lastErrors);

  /// 등록된 전 도메인을 1회 pull 한다.
  ///
  /// 도메인 하나의 실패는 다른 도메인의 pull 을 막지 않는다 — 실패 도메인은
  /// 커서가 전진하지 않아 다음 트리거에서 같은 지점부터 재시도된다.
  /// 실행 중인 도메인이 있으면 그 실행에 합류한다(중첩 방지, [pull] 참조).
  Future<void> pullAll() => pull(_domains.keys);

  /// [domains] 만 1회 pull 한다 (S7-3, #12754) — mutation 직후 관련 도메인만
  /// 즉시 재수화할 때 쓴다 (찜 토글 → `book_like`·`book_meta`, 구매 →
  /// `book_order_summary`·`book_meta`). 반영은 drift watch 재emit 으로
  /// 소비측에 자동 전달된다 (R2 크로스 화면 반응형).
  ///
  /// 같은 도메인이 이미 실행 중이면 새로 시작하지 않고 그 실행에 합류한다 —
  /// 도메인 단위 중첩 방지. 서로 다른 도메인은 병렬로 pull 한다.
  ///
  /// 등록되지 않은 도메인명은 [ArgumentError] — 조용히 no-op 이 되면 배선
  /// 누락(앱 DI 에서 도메인을 안 걸어 둔 것)이 "빈 목록" 으로만 보인다.
  Future<void> pull(Iterable<String> domains) async {
    final targets = domains.toSet();
    final unknown = targets.difference(_domains.keys.toSet());
    if (unknown.isNotEmpty) {
      throw ArgumentError.value(
        unknown,
        'domains',
        '등록되지 않은 replica 도메인 — 앱 DI 의 ReplicaPuller.domains 를 확인한다',
      );
    }
    await Future.wait(targets.map(_pullOrJoin));
  }

  Future<void> _pullOrJoin(String domain) {
    final running = _inFlightByDomain[domain];
    if (running != null) return running;
    // ⚠️ 블록 본문이어야 한다 — `=> _inFlightByDomain.remove(domain)` 은 제거된
    //    Future(= 이 task 자신)를 반환하고, whenComplete 는 콜백이 Future 를
    //    돌려주면 그것을 기다리므로 자기 완료를 기다리는 교착이 된다.
    final task = _pullDomainGuarded(domain).whenComplete(() {
      _inFlightByDomain.remove(domain);
    });
    _inFlightByDomain[domain] = task;
    return task;
  }

  Future<void> _pullDomainGuarded(String domain) async {
    final fetch = _domains[domain];
    if (fetch == null) {
      throw StateError('replica 도메인 미등록: $domain');
    }
    try {
      await _pullDomain(domain, fetch);
      _lastErrors.remove(domain);
    } on Object catch (error, stackTrace) {
      _lastErrors[domain] = error;
      onError?.call(domain, error, stackTrace);
    }
  }

  Future<void> _pullDomain(String domain, ReplicaDomainFetch fetch) async {
    var cursor = await _store.loadCursor(domain);
    for (var page = 0; page < maxPagesPerDomain; page++) {
      final result = await fetch(cursor);
      await _store.applyPage(
        domain: domain,
        rows: result.rows,
        nextCursor: result.nextCursor,
      );
      cursor = result.nextCursor;
      if (!result.hasMore) return;
    }
  }

  /// 온라인 여부 스트림을 구독해 **오프라인→온라인 전이마다** [pullAll] 을
  /// 실행한다 (첫 온라인 신호 포함 — 부팅 직후 증분 회수).
  void bindOnlineStream(Stream<bool> online) {
    _onlineSubscription?.cancel();
    _wasOnline = false;
    _onlineSubscription = online.listen((isOnline) {
      final becameOnline = isOnline && !_wasOnline;
      _wasOnline = isOnline;
      if (becameOnline) unawaited(pullAll());
    });
  }

  /// 구독 해제.
  Future<void> dispose() async {
    await _onlineSubscription?.cancel();
  }
}
