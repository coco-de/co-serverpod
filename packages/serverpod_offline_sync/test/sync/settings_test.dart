import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:test/test.dart';

void main() {
  test('legacy defaults remain unbounded and use the original intervals', () {
    final engine = OfflineSyncEngine(syncTables: [], serializationManager: Protocol());
    final defaults = OfflineSyncSettings();
    expect(engine.batchBudget.isUnlimited, isTrue);
    expect(engine.continuousSyncInterval, const Duration(milliseconds: 200));
    expect(engine.maxContinuousSyncInterval, const Duration(seconds: 30));
    expect(engine.maxClockDrift, const Duration(hours: 1));
    expect(() => defaults.requireMatches(engine.settings), returnsNormally);
  });

  test('paired presets leave clock headroom and bound the same batch measure', () {
    final server = OfflineSyncSettings.boundedServer;
    final client = OfflineSyncSettings.boundedClient;
    expect(server.maxClockDrift, lessThan(client.maxClockDrift));
    expect(server.batchBudget.maxChanges, 5000);
    expect(server.batchBudget.maxPayloadChars, 7 * 1024 * 1024);
    expect(client.batchBudget, same(server.batchBudget));
    expect(
      server.batchBudget.measurePayload,
      OfflineSyncBatchBudget.measureJsonPayload,
    );
  });

  test('one settings value reaches the engine, including both interval bounds', () {
    final settings = OfflineSyncSettings.boundedServer.copyWith(
      syncBatchSize: 3,
      continuousSyncInterval: const Duration(seconds: 2),
      maxContinuousSyncInterval: const Duration(seconds: 7),
      maxClockDrift: const Duration(minutes: 4),
    );
    final engine = OfflineSyncEngine.withSettings(
      syncTables: [],
      serializationManager: Protocol(),
      settings: settings,
    );
    expect(engine.maxClockDrift, const Duration(minutes: 4));
    expect(
      engine.resolveContinuousSyncInterval(local: Duration.zero),
      const Duration(seconds: 2),
    );
    expect(
      engine.resolveContinuousSyncInterval(peer: const Duration(seconds: 99)),
      const Duration(seconds: 7),
    );
    expect(engine.settings.syncBatchSize, 3);
    expect(engine.batchBudget, same(OfflineSyncSettings.boundedServer.batchBudget));
  });

  test('invalid settings fail when constructed, without needing a database', () {
    for (final build in <OfflineSyncSettings Function()>[
      () => OfflineSyncSettings(syncBatchSize: 0),
      () =>
          OfflineSyncSettings(continuousSyncInterval: const Duration(milliseconds: -1)),
      () => OfflineSyncSettings(maxClockDrift: Duration.zero),
      () => OfflineSyncSettings(
        continuousSyncInterval: const Duration(seconds: 5),
        maxContinuousSyncInterval: const Duration(seconds: 4),
      ),
    ]) {
      expect(build, throwsArgumentError);
    }
    final long = OfflineSyncSettings(
      continuousSyncInterval: const Duration(seconds: 40),
    );
    expect(long.maxContinuousSyncInterval, const Duration(seconds: 40));
  });

  test('rewrapping detects differing chunks, intervals, drift and batch budgets', () {
    final original = OfflineSyncSettings.boundedClient;
    for (final other in [
      original.copyWith(syncBatchSize: 1),
      original.copyWith(continuousSyncInterval: const Duration(seconds: 1)),
      original.copyWith(maxContinuousSyncInterval: const Duration(seconds: 40)),
      original.copyWith(maxClockDrift: const Duration(minutes: 5)),
      original.copyWith(batchBudget: OfflineSyncBatchBudget.json(maxChanges: 4)),
      original.copyWith(
        batchBudget: OfflineSyncBatchBudget(
          maxPayloadChars: 10,
          measurePayload: (_) => 1,
        ),
      ),
    ]) {
      expect(() => original.requireMatches(other), throwsArgumentError);
    }
    expect(() => original.requireMatches(original.copyWith()), returnsNormally);
  });
}
