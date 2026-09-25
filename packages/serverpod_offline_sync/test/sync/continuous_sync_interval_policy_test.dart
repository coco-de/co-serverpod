import 'dart:convert';

import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// The wait a continuous session asks for (fork, unibook#14207).
///
/// Each peer waits the slower of the two requests, bounded by its own
/// configured interval (floor) and maximum (cap). No request means the
/// configured interval, as before sessions could ask. The request travels in
/// [OfflineSyncConnect.continuousSyncInterval], a nullable field that a peer
/// built before it existed neither sends nor reads.
///
/// Every value below differs from every other one (floor 200 ms, cap 2 s,
/// requests 50/100/700/1500 ms, 10 min) so no case passes because two values
/// happen to match.
void main() {
  final serializationManager = Protocol();
  const floor = OfflineSyncEngine.defaultContinuousSyncInterval;
  const cap = Duration(seconds: 2);

  OfflineSyncEngine engineWith({
    Duration continuousSyncInterval = floor,
    Duration? maxContinuousSyncInterval,
  }) => maxContinuousSyncInterval == null
      ? OfflineSyncEngine(
          syncTables: const [],
          serializationManager: serializationManager,
          continuousSyncInterval: continuousSyncInterval,
        )
      : OfflineSyncEngine(
          syncTables: const [],
          serializationManager: serializationManager,
          continuousSyncInterval: continuousSyncInterval,
          maxContinuousSyncInterval: maxContinuousSyncInterval,
        );

  group(
    'Given resolveContinuousSyncInterval with a floor of 200 ms and a cap of 2 s,',
    () {
      final engine = engineWith(maxContinuousSyncInterval: cap);
      const ms = Duration(milliseconds: 1);

      final cases = <(String, Duration?, Duration?, Duration)>[
        ('no peer asks', null, null, floor),
        ('this peer asks within the bounds', ms * 1500, null, ms * 1500),
        ('the other peer asks within the bounds', null, ms * 1500, ms * 1500),
        ('this peer asks exactly the floor', floor, null, floor),
        ('this peer asks exactly the cap', cap, null, cap),
        ('this peer asks below the floor', ms * 50, null, floor),
        ('both peers ask below the floor', ms * 50, ms * 100, floor),
        ('both peers ask for no wait at all', Duration.zero, -ms * 5, floor),
        ('this peer asks above the cap', const Duration(minutes: 10), null, cap),
        ('this peer asks just above the cap', cap + ms, null, cap),
        (
          'both peers ask above the cap',
          const Duration(minutes: 10),
          const Duration(minutes: 11),
          cap,
        ),
        ('this peer asks slower than the other', ms * 1500, ms * 700, ms * 1500),
        ('the other peer asks slower than this one', ms * 700, ms * 1500, ms * 1500),
      ];

      for (final (name, local, peer, expected) in cases) {
        test('when $name, then it waits $expected.', () {
          final resolved = engine.resolveContinuousSyncInterval(
            local: local,
            peer: peer,
          );

          expect(resolved, expected);
          expect(resolved >= floor && resolved <= cap, isTrue);
        });
      }
    },
  );

  group('Given the maximum a session can ask for,', () {
    test(
      'when none is configured, then it is 30 s above a shorter interval.',
      () {
        final engine = engineWith();

        expect(
          OfflineSyncEngine.defaultMaxContinuousSyncInterval,
          const Duration(seconds: 30),
        );
        expect(engine.continuousSyncInterval, floor);
        expect(engine.maxContinuousSyncInterval, const Duration(seconds: 30));
        expect(
          engine.resolveContinuousSyncInterval(local: const Duration(minutes: 10)),
          const Duration(seconds: 30),
        );
      },
    );

    test(
      'when none is configured and the interval is longer than 30 s, '
      'then the interval is the maximum and still applies unchanged.',
      () {
        const interval = Duration(seconds: 45);
        final engine = engineWith(continuousSyncInterval: interval);

        expect(engine.maxContinuousSyncInterval, interval);
        expect(engine.resolveContinuousSyncInterval(), interval);
        expect(
          engine.resolveContinuousSyncInterval(local: const Duration(minutes: 10)),
          interval,
        );
      },
    );

    test('when it equals the interval, then it is accepted.', () {
      final engine = engineWith(
        continuousSyncInterval: cap,
        maxContinuousSyncInterval: cap,
      );

      expect(engine.maxContinuousSyncInterval, cap);
      expect(
        engine.resolveContinuousSyncInterval(local: const Duration(minutes: 10)),
        cap,
      );
    });

    test(
      'when it is below the interval, '
      'then the engine throws ArgumentError instead of raising it.',
      () {
        expect(
          () => engineWith(
            continuousSyncInterval: cap,
            maxContinuousSyncInterval: cap - const Duration(milliseconds: 1),
          ),
          throwsArgumentError,
        );
        expect(
          () => OfflineSyncEngine.resolveMaxContinuousSyncInterval(
            cap,
            cap - const Duration(milliseconds: 1),
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('Given the connect frame on the wire,', () {
    final localNodeId = const Uuid().v7obj();
    OfflineSyncConnect overTheWire(OfflineSyncConnect event) =>
        serializationManager.decodeWithType(
              serializationManager.encodeWithTypeForProtocol(event),
            )!
            as OfflineSyncConnect;

    test('when it carries a request, then the request arrives.', () {
      final received = overTheWire(
        OfflineSyncConnect(
          localNodeId: localNodeId,
          syncTablesHash: 'hash',
          continuousSyncInterval: const Duration(milliseconds: 1500),
        ),
      );

      expect(received.continuousSyncInterval, const Duration(milliseconds: 1500));
      expect(received.localNodeId, localNodeId);
    });

    test(
      'when it carries no request, then the key is left out and it arrives as null.',
      () {
        final event = OfflineSyncConnect(
          localNodeId: localNodeId,
          syncTablesHash: 'hash',
        );

        expect(event.toJsonForProtocol(), isNot(contains('continuousSyncInterval')));
        expect(overTheWire(event).continuousSyncInterval, isNull);
      },
    );

    test(
      'when it has a key this build does not know, '
      'then it still decodes, as a peer built before the request decodes one '
      'that carries it.',
      () {
        final wire =
            jsonDecode(
                  serializationManager.encodeWithTypeForProtocol(
                    OfflineSyncConnect(
                      localNodeId: localNodeId,
                      syncTablesHash: 'hash',
                    ),
                  ),
                )
                as Map<String, dynamic>;
        (wire['data'] as Map<String, dynamic>)['someLaterField'] = 1500;

        final received =
            serializationManager.deserializeByClassName(wire) as OfflineSyncConnect;

        expect(received.localNodeId, localNodeId);
        expect(received.syncTablesHash, 'hash');
        expect(received.continuousSyncInterval, isNull);
      },
    );
  });
}
