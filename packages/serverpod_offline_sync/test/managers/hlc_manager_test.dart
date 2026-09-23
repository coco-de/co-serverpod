import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:test/test.dart';

import '../hlc/hlc_fixtures.dart';

/// [HlcManager] holds one drift limit and applies it to every timestamp it
/// issues or merges. These cases use a five-minute limit, so a manager that
/// dropped it and fell back to the one-hour default would accept every
/// "over the limit" case below.
void main() {
  const fiveMinutes = Duration(minutes: 5);
  const oneMillisecond = Duration(milliseconds: 1);

  HlcManager managerAt(Hlc lastHlc, {Duration? maxDrift}) {
    final space = OfflineSyncSpace(
      id: 42,
      uuidSpaceId: hlcSecondNodeId,
      currentNodeId: 9,
      currentNode: CrdtNode(id: 9, uuidNodeId: hlcNodeId, lastHlc: lastHlc),
    );
    return maxDrift == null
        ? HlcManager.forSpace(space)
        : HlcManager.forSpace(space, maxDrift: maxDrift);
  }

  Matcher throwsDrift(ClockDriftKind kind) => throwsA(
    isA<ClockDriftException>()
        .having((e) => e.kind, 'kind', kind)
        .having((e) => e.maxDrift, 'maxDrift', fiveMinutes),
  );

  group('Given an HlcManager created without a drift,', () {
    test('when reading its drift, then it is the one-hour default.', () {
      expect(managerAt(Hlc(hlcTime, 0, hlcNodeId)).maxDrift, Hlc.defaultMaxDrift);
    });
  });

  group('Given an HlcManager with a five-minute drift,', () {
    test(
      'when its clock is exactly five minutes ahead, '
      'then increment and peekNext succeed and only increment advances it.',
      () {
        final manager = managerAt(
          Hlc(hlcTime.add(fiveMinutes), 2, hlcNodeId),
          maxDrift: fiveMinutes,
        );

        atWallTime(hlcTime, () {
          expect(manager.peekNext().counter, 3);
          expect(manager.lastHlc.counter, 2);
          expect(manager.increment().counter, 3);
          expect(manager.lastHlc.counter, 3);
        });
      },
    );

    test(
      'when its clock is one millisecond past five minutes ahead, '
      'then increment and peekNext throw localAhead and the clock is unchanged.',
      () {
        final lastHlc = Hlc(hlcTime.add(fiveMinutes + oneMillisecond), 2, hlcNodeId);
        final manager = managerAt(lastHlc, maxDrift: fiveMinutes);

        atWallTime(hlcTime, () {
          expect(manager.increment, throwsDrift(ClockDriftKind.localAhead));
          expect(manager.peekNext, throwsDrift(ClockDriftKind.localAhead));
        });
        expect(manager.lastHlc, lastHlc);
      },
    );

    test(
      'when merging a remote exactly five minutes ahead, then the clock adopts it.',
      () {
        final manager = managerAt(Hlc(hlcTime, 0, hlcNodeId), maxDrift: fiveMinutes);
        final remote = Hlc(hlcTime.add(fiveMinutes), 7, hlcSecondNodeId);

        atWallTime(hlcTime, () => manager.merge(remote));

        expect(manager.lastHlc, Hlc(remote.datetime, 7, hlcNodeId));
      },
    );

    test(
      'when merging a remote one millisecond past five minutes ahead, '
      'then merge throws remoteAhead and the clock is unchanged.',
      () {
        final lastHlc = Hlc(hlcTime, 0, hlcNodeId);
        final manager = managerAt(lastHlc, maxDrift: fiveMinutes);
        final remote = Hlc(
          hlcTime.add(fiveMinutes + oneMillisecond),
          7,
          hlcSecondNodeId,
        );

        expect(
          () => atWallTime(hlcTime, () => manager.merge(remote)),
          throwsDrift(ClockDriftKind.remoteAhead),
        );
        expect(manager.lastHlc, lastHlc);
      },
    );
  });

  group('Given a drift that is not positive,', () {
    for (final maxDrift in [Duration.zero, const Duration(seconds: -1)]) {
      test('when creating a manager with $maxDrift, then it throws ArgumentError.', () {
        expect(
          () => managerAt(Hlc(hlcTime, 0, hlcNodeId), maxDrift: maxDrift),
          throwsArgumentError,
        );
      });
    }
  });
}
