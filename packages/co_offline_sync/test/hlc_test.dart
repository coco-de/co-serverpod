import 'dart:math';

import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:test/test.dart';

void main() {
  group('Hlc codec', () {
    test('pack/parse 왕복이 항등이다', () {
      const hlc = Hlc(1725000000000, 42, 'node-abc');
      expect(Hlc.parse(hlc.pack()), hlc);
    });

    test('pack 은 고정폭이라 사전순 == compareTo 순서다 (무작위 500쌍)', () {
      final random = Random(7);
      // Random.nextInt 상한(2^32)을 피해 40비트 millis 를 두 번에 나눠 만든다.
      Hlc randomHlc() => Hlc(
        random.nextInt(1 << 20) * (1 << 20) + random.nextInt(1 << 20),
        random.nextInt(Hlc.maxCounter + 1),
        'n${random.nextInt(9)}',
      );
      for (var i = 0; i < 500; i++) {
        final a = randomHlc();
        final b = randomHlc();
        expect(
          a.pack().compareTo(b.pack()).sign,
          a.compareTo(b).sign,
          reason: '${a.pack()} vs ${b.pack()}',
        );
      }
    });

    test('형식이 어긋나면 FormatException', () {
      expect(() => Hlc.parse('garbage'), throwsFormatException);
      expect(() => Hlc.parse('zzzzzzzzzzzz-0001-node'), throwsFormatException);
      expect(() => Hlc.parse('000000000001x0001-node'), throwsFormatException);
    });

    test('[발견5] 관용 입력을 거부한다 — 공백·부호·대문자 hex', () {
      final valid = const Hlc(0xabc, 1, 'node').pack();
      expect(() => Hlc.parse(' ${valid.substring(1)}'), throwsFormatException);
      expect(() => Hlc.parse('-${valid.substring(1)}'), throwsFormatException);
      expect(() => Hlc.parse(valid.toUpperCase()), throwsFormatException);
      expect(Hlc.parse(valid), const Hlc(0xabc, 1, 'node'));
    });

    test('같은 (millis, counter) 는 nodeId 사전순으로 갈린다', () {
      const a = Hlc(100, 1, 'aaa');
      const b = Hlc(100, 1, 'bbb');
      expect(a < b, isTrue);
      expect(a == b, isFalse);
    });
  });

  group('HlcClock', () {
    test('now 는 벽시계가 역행해도 단조 증가한다', () {
      var wall = 1000;
      final clock = HlcClock(nodeId: 'n1', wallClock: () => wall);
      final first = clock.now();
      wall = 500; // 벽시계 역행
      final second = clock.now();
      final third = clock.now();
      expect(second > first, isTrue);
      expect(third > second, isTrue);
      expect(second.millis, first.millis); // 논리 카운터로 전진
    });

    test('receive 는 원격보다 항상 큰 스탬프를 만든다', () {
      final clock = HlcClock(nodeId: 'n1', wallClock: () => 1000);
      const remote = Hlc(5000, 7, 'n2');
      final received = clock.receive(remote);
      expect(received > remote, isTrue);
      expect(received.nodeId, 'n1');
      // 이후 now 도 원격 이후를 유지한다.
      expect(clock.now() > remote, isTrue);
    });

    test('벽시계가 원격·로컬보다 앞서면 벽시계를 채택한다', () {
      final clock = HlcClock(nodeId: 'n1', wallClock: () => 9000);
      final received = clock.receive(const Hlc(5000, 7, 'n2'));
      expect(received, const Hlc(9000, 0, 'n1'));
    });

    test('허용 한도 이상 미래의 원격 스탬프는 ClockDriftException', () {
      final clock = HlcClock(
        nodeId: 'n1',
        wallClock: () => 1000,
        maxDriftMs: 60000,
      );
      expect(
        () => clock.receive(const Hlc(1000 + 60001, 0, 'n2')),
        throwsA(isA<ClockDriftException>()),
      );
    });

    test('[발견2] seed 는 하한을 전진시키고, 이후 now 는 항상 그보다 크다', () {
      final clock = HlcClock(nodeId: 'aa', wallClock: () => 1000);
      const remoteFloor = Hlc(5000, 3, 'zz');
      clock.seed(remoteFloor);
      expect(clock.now() > remoteFloor, isTrue);
      // 더 낮은 하한 seed 는 no-op — 시계가 뒤로 가지 않는다.
      final beforeLow = clock.last;
      clock.seed(const Hlc(10, 0, 'zz'));
      expect(clock.last, beforeLow);
      // seed 는 드리프트 검사를 하지 않는다 (receive 는 던지는 값).
      final farFuture = Hlc(1000 + clock.maxDriftMs + 1, 0, 'zz');
      expect(
        () => clock.receive(farFuture),
        throwsA(isA<ClockDriftException>()),
      );
      clock.seed(farFuture); // 던지지 않는다
      expect(clock.now() > farFuture, isTrue);
    });

    test('initial 로 복원한 시계는 복원 하한보다 큰 스탬프를 발급한다', () {
      const saved = Hlc(9000, 7, 'aa');
      final clock = HlcClock(
        nodeId: 'aa',
        wallClock: () => 1000,
        initial: saved,
      );
      expect(clock.now() > saved, isTrue);
    });

    test('같은 밀리초에서 카운터가 상한을 넘으면 오버플로 예외', () {
      final clock = HlcClock(nodeId: 'n1', wallClock: () => 1000);
      expect(() {
        for (var i = 0; i <= Hlc.maxCounter + 1; i++) {
          clock.now();
        }
      }, throwsA(isA<HlcCounterOverflowException>()));
    });
  });
}
