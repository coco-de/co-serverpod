import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:test/test.dart';

/// How the drift limit travels from the configuration entry points to the
/// shared [OfflineSyncDatabaseContext]. The context is what the per-transaction
/// [HlcManager] reads, so a value that stops here never reaches a timestamp.
void main() {
  const fiveMinutes = Duration(minutes: 5);
  final serializationManager = Protocol();

  OfflineSyncDatabaseContext contextWith({Duration? maxClockDrift}) =>
      maxClockDrift == null
      ? OfflineSyncDatabaseContext(
          syncTables: const [],
          serializationManager: serializationManager,
        )
      : OfflineSyncDatabaseContext(
          syncTables: const [],
          serializationManager: serializationManager,
          maxClockDrift: maxClockDrift,
        );

  group('Given an OfflineSyncDatabaseContext,', () {
    test('when no drift is passed, then it uses the one-hour default.', () {
      expect(contextWith().maxClockDrift, Hlc.defaultMaxDrift);
    });

    test('when a drift is passed, then it keeps that drift.', () {
      expect(contextWith(maxClockDrift: fiveMinutes).maxClockDrift, fiveMinutes);
    });

    for (final maxClockDrift in [Duration.zero, const Duration(minutes: -1)]) {
      test('when the drift is $maxClockDrift, then it throws ArgumentError.', () {
        expect(() => contextWith(maxClockDrift: maxClockDrift), throwsArgumentError);
      });
    }
  });

  group('Given an OfflineSyncEngine,', () {
    test('when created without a drift or a context, then it uses the default.', () {
      final engine = OfflineSyncEngine(
        syncTables: const [],
        serializationManager: serializationManager,
      );

      expect(engine.maxClockDrift, Hlc.defaultMaxDrift);
    });

    test('when created with a drift and no context, then its context uses it.', () {
      final engine = OfflineSyncEngine(
        syncTables: const [],
        serializationManager: serializationManager,
        maxClockDrift: fiveMinutes,
      );

      expect(engine.maxClockDrift, fiveMinutes);
    });

    test('when created with a context, then it uses the context drift.', () {
      final engine = OfflineSyncEngine(
        syncTables: const [],
        serializationManager: serializationManager,
        databaseContext: contextWith(maxClockDrift: fiveMinutes),
      );

      expect(engine.maxClockDrift, fiveMinutes);
    });

    test('when created with a context and the same drift, then it is accepted.', () {
      final engine = OfflineSyncEngine(
        syncTables: const [],
        serializationManager: serializationManager,
        databaseContext: contextWith(maxClockDrift: fiveMinutes),
        maxClockDrift: fiveMinutes,
      );

      expect(engine.maxClockDrift, fiveMinutes);
    });

    test(
      'when created with a context and a different drift, '
      'then it throws ArgumentError instead of ignoring the drift.',
      () {
        expect(
          () => OfflineSyncEngine(
            syncTables: const [],
            serializationManager: serializationManager,
            databaseContext: contextWith(maxClockDrift: fiveMinutes),
            maxClockDrift: Hlc.defaultMaxDrift,
          ),
          throwsArgumentError,
        );
      },
    );
  });
}
