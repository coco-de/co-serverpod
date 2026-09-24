import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:test/test.dart';

import 'hlc_fixtures.dart';

/// [Hlc.increment] derives its result from `clock.now()`, so every increment
/// here runs with the wall clock pinned to an explicit instant.
void main() {
  group('Given an HLC with lower canonical time than wall time', () {
    final hlc = Hlc(hlcTime, 17, hlcNodeId);
    final wallTime = hlcTime.advance();

    test('when incrementing then dateTime becomes wall time and counter resets.', () {
      atWallTime(wallTime, () {
        final sendHlc = hlc.increment();

        expect(sendHlc, isNot(hlc));
        expect(sendHlc.datetime, wallTime);
        expect(sendHlc.counter, 0);
        expect(sendHlc.nodeId, hlc.nodeId);
      });
    });
  });

  group('Given an HLC with equal canonical time and wall time', () {
    final hlc = Hlc(hlcTime, 17, hlcNodeId);
    final wallTime = hlcTime;

    test('when incrementing then counter increments and dateTime is unchanged.', () {
      atWallTime(wallTime, () {
        final sendHlc = hlc.increment();

        expect(sendHlc, isNot(hlc));
        expect(sendHlc.datetime, hlc.datetime);
        expect(sendHlc.counter, 18);
        expect(sendHlc.nodeId, hlc.nodeId);
      });
    });
  });

  group('Given an HLC with higher canonical time than wall time', () {
    final hlc = Hlc(hlcTime, 17, hlcNodeId);
    final wallTime = hlcTime.retreat();

    test('when incrementing then counter increments and dateTime is unchanged.', () {
      atWallTime(wallTime, () {
        final sendHlc = hlc.increment();

        expect(sendHlc, isNot(hlc));
        expect(sendHlc.datetime, hlc.datetime);
        expect(sendHlc.counter, 18);
        expect(sendHlc.nodeId, hlc.nodeId);
      });
    });
  });

  // Upstream rejected this HLC: its limit was one minute. The fork defaults to
  // Hlc.defaultMaxDrift (one hour), so the upstream case now succeeds and the
  // rejection moves to the one-hour edge below.
  group(
    'Given an HLC with canonical time one minute and five seconds ahead of wall time',
    () {
      final hlc = Hlc(
        hlcTime.add(const Duration(minutes: 1, seconds: 5)),
        0,
        hlcNodeId,
      );
      final wallTime = hlcTime;

      test(
        'when incrementing with the default drift then the counter increments '
        '(upstream threw ClockDriftException).',
        () {
          atWallTime(wallTime, () {
            final sendHlc = hlc.increment();

            expect(sendHlc.datetime, hlc.datetime);
            expect(sendHlc.counter, 1);
          });
        },
      );
    },
  );

  group('Given an HLC with canonical time more than one hour ahead of wall time', () {
    final hlc = Hlc(hlcTime.add(Hlc.defaultMaxDrift).advance(), 0, hlcNodeId);
    final wallTime = hlcTime;

    test('when incrementing then ClockDriftException is thrown.', () {
      atWallTime(wallTime, () {
        expect(
          hlc.increment,
          throwsA(
            isA<ClockDriftException>().having(
              (e) => e.kind,
              'kind',
              ClockDriftKind.localAhead,
            ),
          ),
        );
      });
    });
  });

  group('Given an HLC with counter at maximum and canonical time at wall time', () {
    final hlc = Hlc(hlcTime, 0xFFFF, hlcNodeId);
    final wallTime = hlcTime;

    test('when incrementing at same time then OverflowException is thrown.', () {
      atWallTime(wallTime, () {
        expect(hlc.increment, throwsA(isA<OverflowException>()));
      });
    });
  });
}
