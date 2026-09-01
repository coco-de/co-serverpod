import 'exceptions.dart';

/// 하이브리드 논리 시계(Hybrid Logical Clock) 타임스탬프.
///
/// `(millis, counter, nodeId)` 3요소의 전순서(total order)다. 서로 다른
/// [nodeId] 를 가진 두 노드가 같은 `(millis, counter)` 를 만들어도 [nodeId]
/// 사전순 비교로 순서가 갈리므로, **서로 다른 노드의 Hlc 는 절대 동률이 되지
/// 않는다** — 이 성질이 LWW 병합의 결정성을 보장한다.
///
/// [pack] 인코딩은 고정폭이라 **문자열 사전순 == [compareTo] 순서**다. DB
/// 컬럼에 packed 문자열로 저장하고 문자열 비교/인덱스를 그대로 쓸 수 있다.
class Hlc implements Comparable<Hlc> {
  /// 각 요소를 직접 지정해 생성한다.
  const Hlc(this.millis, this.counter, this.nodeId)
    : assert(millis >= 0, 'millis must be >= 0'),
      assert(counter >= 0 && counter <= maxCounter, 'counter out of range'),
      assert(nodeId != '', 'nodeId must not be empty');

  /// 해당 노드의 0 시각 (모든 실제 스탬프보다 과거).
  const Hlc.zero(this.nodeId) : millis = 0, counter = 0;

  /// Unix epoch 밀리초 벽시계 성분.
  final int millis;

  /// 같은 밀리초 안에서의 논리 카운터 (0 ~ [maxCounter]).
  final int counter;

  /// 이 스탬프를 만든 노드의 식별자 (기기/설치 단위 고유 문자열).
  final String nodeId;

  /// [counter] 의 상한 (16비트).
  static const int maxCounter = 0xFFFF;

  static const int _millisWidth = 12;
  static const int _counterWidth = 4;

  // 소문자 hex 만 — int.tryParse 의 관용(공백·'+'·대문자)을 차단한다.
  // 대문자를 허용하면 외부 생산 packed 문자열의 사전순이 수치 순서와 어긋난다.
  static final RegExp _lowerHex = RegExp(r'^[0-9a-f]+$');

  /// 고정폭 문자열 인코딩: `{millis:12hex}-{counter:4hex}-{nodeId}`.
  ///
  /// 사전순 비교가 [compareTo] 와 일치한다.
  String pack() {
    final m = millis.toRadixString(16).padLeft(_millisWidth, '0');
    final c = counter.toRadixString(16).padLeft(_counterWidth, '0');
    return '$m-$c-$nodeId';
  }

  /// [pack] 의 역연산. 형식이 어긋나면 [FormatException].
  ///
  /// 소문자 hex 고정폭만 허용한다 — 공백·부호·대문자가 섞인 입력은 사전순
  /// 계약을 깨뜨리므로 거부한다.
  factory Hlc.parse(String packed) {
    if (packed.length < _millisWidth + 1 + _counterWidth + 2 ||
        packed[_millisWidth] != '-' ||
        packed[_millisWidth + 1 + _counterWidth] != '-') {
      throw FormatException('invalid Hlc encoding', packed);
    }
    final millisHex = packed.substring(0, _millisWidth);
    final counterHex = packed.substring(
      _millisWidth + 1,
      _millisWidth + 1 + _counterWidth,
    );
    final node = packed.substring(_millisWidth + 1 + _counterWidth + 1);
    if (!_lowerHex.hasMatch(millisHex) ||
        !_lowerHex.hasMatch(counterHex) ||
        node.isEmpty) {
      throw FormatException('invalid Hlc encoding', packed);
    }
    return Hlc(
      int.parse(millisHex, radix: 16),
      int.parse(counterHex, radix: 16),
      node,
    );
  }

  @override
  int compareTo(Hlc other) {
    if (millis != other.millis) return millis.compareTo(other.millis);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return nodeId.compareTo(other.nodeId);
  }

  /// `this` 가 [other] 보다 이후인가.
  bool operator >(Hlc other) => compareTo(other) > 0;

  /// `this` 가 [other] 보다 이전인가.
  bool operator <(Hlc other) => compareTo(other) < 0;

  /// `this` 가 [other] 이후이거나 같은가.
  bool operator >=(Hlc other) => compareTo(other) >= 0;

  /// `this` 가 [other] 이전이거나 같은가.
  bool operator <=(Hlc other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.millis == millis &&
      other.counter == counter &&
      other.nodeId == nodeId;

  @override
  int get hashCode => Object.hash(millis, counter, nodeId);

  @override
  String toString() => pack();
}

/// 한 노드의 HLC 상태 기계.
///
/// [now] 는 로컬 이벤트(쓰기)마다, [receive] 는 원격 스탬프를 관찰할 때마다
/// 호출한다. 두 메서드 모두 이 노드가 이전에 발급/관찰한 어떤 스탬프보다도
/// 큰 값을 유지한다 (단조 증가).
///
/// ⚠️ **단조성은 시계 상태가 유지될 때만 성립한다.** 프로세스 재시작으로 새
/// [HlcClock] 을 만들면 이전에 관찰한 스탬프를 잊고, 재시작 직후의 로컬
/// 편집이 저장된 원격 스탬프보다 과거로 찍혀 **LWW 에서 조용히 패배**할 수
/// 있다. 저장소의 최대 HLC 로 [seed] 하거나 [HlcClock.new] 의 `initial` 로
/// 복원하라 — `CoSyncClient` 는 저장소 `maxHlc()` 로 이를 자동 수행한다.
///
/// 벽시계는 [wallClock] 로 주입 가능해 테스트에서 결정적으로 제어할 수 있다.
class HlcClock {
  /// [nodeId] 는 기기/설치 단위 고유 문자열(예: UUID v4)이어야 한다.
  ///
  /// [initial] 은 재시작 복원용 하한 (저장해 둔 [last] 또는 저장소 최대 HLC).
  HlcClock({
    required this.nodeId,
    int Function()? wallClock,
    this.maxDriftMs = Duration.millisecondsPerHour,
    Hlc? initial,
  }) : _wallClock = wallClock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _last = initial ?? Hlc.zero(nodeId);

  /// 이 시계가 스탬프에 새길 노드 식별자.
  final String nodeId;

  /// 원격 스탬프가 로컬 벽시계보다 이만큼 이상 미래면 [ClockDriftException].
  final int maxDriftMs;

  final int Function() _wallClock;
  Hlc _last;

  /// 마지막으로 발급/관찰된 스탬프 (읽기 전용 — 영속 복원용으로 저장 가능).
  Hlc get last => _last;

  /// 저장소에서 복원한 하한 [floor] 로 시계를 전진시킨다.
  ///
  /// [receive] 와 달리 **드리프트 검사를 하지 않는다** — 이미 저장소에 수용된
  /// 스탬프는 다시 거부할 수 없기 때문이다. 시드 후의 [now] 는 [floor] 보다
  /// 항상 큰 스탬프를 발급한다.
  void seed(Hlc floor) {
    if (floor > _last) {
      _last = Hlc(floor.millis, floor.counter, nodeId);
    }
  }

  /// 로컬 이벤트용 새 스탬프를 발급한다.
  Hlc now() {
    final wall = _wallClock();
    if (wall > _last.millis) {
      _last = Hlc(wall, 0, nodeId);
    } else {
      _last = _bump(_last.millis, _last.counter + 1);
    }
    return _last;
  }

  /// 원격 스탬프 [remote] 를 관찰하고, 그것보다 큰 로컬 스탬프를 발급한다.
  Hlc receive(Hlc remote) {
    final wall = _wallClock();
    if (remote.millis - wall > maxDriftMs) {
      throw ClockDriftException(
        remoteMillis: remote.millis,
        wallMillis: wall,
        maxDriftMs: maxDriftMs,
      );
    }
    if (wall > _last.millis && wall > remote.millis) {
      _last = Hlc(wall, 0, nodeId);
    } else if (remote.millis > _last.millis) {
      _last = _bump(remote.millis, remote.counter + 1);
    } else if (remote.millis == _last.millis) {
      final c =
          (remote.counter > _last.counter ? remote.counter : _last.counter) + 1;
      _last = _bump(_last.millis, c);
    } else {
      _last = _bump(_last.millis, _last.counter + 1);
    }
    return _last;
  }

  /// 상한 검사를 **생성 전에** 수행한다 — 생성자 assert 가 먼저 걸리면
  /// 디버그 모드에서 [HlcCounterOverflowException] 대신 AssertionError 가 난다.
  Hlc _bump(int millis, int counter) {
    if (counter > Hlc.maxCounter) {
      throw HlcCounterOverflowException(millis: millis);
    }
    return Hlc(millis, counter, nodeId);
  }
}
