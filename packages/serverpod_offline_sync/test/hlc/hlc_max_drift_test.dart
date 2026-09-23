import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:test/test.dart';

import 'hlc_fixtures.dart';

/// Exact edges of the drift allowance. Every case pins the wall clock to
/// [hlcTime], which is aligned to a whole millisecond, so "exactly the limit"
/// and "one millisecond over" are the same instants for `merge` (microsecond
/// wall clock) and `increment` (millisecond wall clock).
void main() {
  const oneMillisecond = Duration(milliseconds: 1);
  const fiveMinutes = Duration(minutes: 5);

  test('Given the fork, when reading the default drift, then it is one hour.', () {
    expect(Hlc.defaultMaxDrift, const Duration(hours: 1));
  });

  group('Given a remote HLC ahead of the wall clock,', () {
    final canonical = Hlc(hlcTime, 17, hlcNodeId);

    Hlc remoteAhead(Duration drift) => Hlc(hlcTime.add(drift), 3, hlcSecondNodeId);

    test(
      'when it is 59 minutes ahead, '
      'then merge accepts it with the default drift (upstream rejected it).',
      () {
        final remote = remoteAhead(const Duration(minutes: 59));

        final merged = atWallTime(hlcTime, () => canonical.merge(remote));

        expect(merged, Hlc(remote.datetime, remote.counter, hlcNodeId));
      },
    );

    test(
      'when it is exactly the default drift ahead, then merge accepts it.',
      () {
        final remote = remoteAhead(Hlc.defaultMaxDrift);

        final merged = atWallTime(hlcTime, () => canonical.merge(remote));

        expect(merged.datetime, remote.datetime);
      },
    );

    test(
      'when it is one millisecond past the default drift, '
      'then merge throws remoteAhead with the remote node and both durations.',
      () {
        final remote = remoteAhead(Hlc.defaultMaxDrift + oneMillisecond);

        expect(
          () => atWallTime(hlcTime, () => canonical.merge(remote)),
          throwsA(
            isA<ClockDriftException>()
                .having((e) => e.kind, 'kind', ClockDriftKind.remoteAhead)
                .having((e) => e.remoteNodeId, 'remoteNodeId', hlcSecondNodeId)
                .having((e) => e.maxDrift, 'maxDrift', Hlc.defaultMaxDrift)
                .having(
                  (e) => e.drift,
                  'drift',
                  Hlc.defaultMaxDrift + oneMillisecond,
                ),
          ),
        );
      },
    );

    test(
      'when a five-minute limit is passed, then five minutes is accepted '
      'and one millisecond more is rejected with that limit.',
      () {
        final atLimit = remoteAhead(fiveMinutes);
        final overLimit = remoteAhead(fiveMinutes + oneMillisecond);

        final merged = atWallTime(
          hlcTime,
          () => canonical.merge(atLimit, maxDrift: fiveMinutes),
        );
        expect(merged.datetime, atLimit.datetime);

        expect(
          () => atWallTime(
            hlcTime,
            () => canonical.merge(overLimit, maxDrift: fiveMinutes),
          ),
          throwsA(
            isA<ClockDriftException>()
                .having((e) => e.kind, 'kind', ClockDriftKind.remoteAhead)
                .having((e) => e.maxDrift, 'maxDrift', fiveMinutes),
          ),
        );
      },
    );
  });

  group('Given a local HLC ahead of the wall clock (the wall clock went back),', () {
    Hlc localAhead(Duration drift) => Hlc(hlcTime.add(drift), 4, hlcNodeId);

    test(
      'when it is exactly the default drift ahead, '
      'then increment keeps its time and bumps the counter.',
      () {
        final hlc = localAhead(Hlc.defaultMaxDrift);

        final next = atWallTime(hlcTime, hlc.increment);

        expect(next.datetime, hlc.datetime);
        expect(next.counter, 5);
      },
    );

    test(
      'when it is one millisecond past the default drift, '
      'then increment throws localAhead without a remote node.',
      () {
        final hlc = localAhead(Hlc.defaultMaxDrift + oneMillisecond);

        expect(
          () => atWallTime(hlcTime, hlc.increment),
          throwsA(
            isA<ClockDriftException>()
                .having((e) => e.kind, 'kind', ClockDriftKind.localAhead)
                .having((e) => e.remoteNodeId, 'remoteNodeId', isNull)
                .having((e) => e.maxDrift, 'maxDrift', Hlc.defaultMaxDrift)
                .having(
                  (e) => e.drift,
                  'drift',
                  Hlc.defaultMaxDrift + oneMillisecond,
                ),
          ),
        );
      },
    );

    test(
      'when a five-minute limit is passed, then five minutes is accepted '
      'and one millisecond more is rejected with that limit.',
      () {
        final atLimit = atWallTime(
          hlcTime,
          () => localAhead(fiveMinutes).increment(maxDrift: fiveMinutes),
        );
        expect(atLimit.counter, 5);

        expect(
          () => atWallTime(
            hlcTime,
            () => localAhead(
              fiveMinutes + oneMillisecond,
            ).increment(maxDrift: fiveMinutes),
          ),
          throwsA(
            isA<ClockDriftException>()
                .having((e) => e.kind, 'kind', ClockDriftKind.localAhead)
                .having((e) => e.maxDrift, 'maxDrift', fiveMinutes),
          ),
        );
      },
    );
  });

  // merge and increment must share one limit. If increment kept a smaller one
  // (upstream hard-coded one minute there), a remote timestamp merge just
  // accepted would make the very next local write fail.
  group('Given a remote HLC exactly at the drift limit,', () {
    for (final maxDrift in [Hlc.defaultMaxDrift, fiveMinutes]) {
      test(
        'when merge accepts it with $maxDrift, '
        'then the next increment with the same limit succeeds.',
        () {
          final canonical = Hlc(hlcTime, 0, hlcNodeId);
          final remote = Hlc(hlcTime.add(maxDrift), 9, hlcSecondNodeId);

          final next = atWallTime(hlcTime, () {
            final merged = canonical.merge(remote, maxDrift: maxDrift);
            return merged.increment(maxDrift: maxDrift);
          });

          expect(next.datetime, remote.datetime);
          expect(next.counter, 10);
          expect(next.nodeId, hlcNodeId);
        },
      );
    }
  });

  group('Given a ClockDriftException,', () {
    test(
      'when formatting a remote rejection, '
      'then the drift is in milliseconds and names the remote node.',
      () {
        final exception = ClockDriftException(
          hlcTime.add(Hlc.defaultMaxDrift + oneMillisecond),
          hlcTime,
          Hlc.defaultMaxDrift,
          kind: ClockDriftKind.remoteAhead,
          remoteNodeId: hlcSecondNodeId,
        );

        expect(
          exception.toString(),
          'ClockDriftException(remoteAhead): clock drift of 3600001 ms from node '
          '$hlcSecondNodeId exceeds the maximum of 3600000 ms',
        );
      },
    );

    test(
      'when formatting a local rejection, then no node is named.',
      () {
        final exception = ClockDriftException(
          hlcTime.add(const Duration(minutes: 2)),
          hlcTime,
          const Duration(minutes: 1),
          kind: ClockDriftKind.localAhead,
        );

        expect(
          exception.toString(),
          'ClockDriftException(localAhead): clock drift of 120000 ms exceeds '
          'the maximum of 60000 ms',
        );
      },
    );
  });
}
