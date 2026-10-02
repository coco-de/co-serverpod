import '../hlc/hlc.dart';
import 'outbound_batch.dart';

/// All engine settings in one validated value, shared by server and client.
///
/// [boundedServer] and [boundedClient] are opt-in paired presets. They bound
/// outbound batches and keep the server's accepted clock drift below the
/// client's. The existing constructors retain their upstream defaults.
/// These are local settings, not limits negotiated with or enforced on a peer.
final class OfflineSyncSettings {
  /// Creates settings using the legacy defaults unless explicitly overridden.
  factory OfflineSyncSettings({
    int syncBatchSize = defaultSyncBatchSize,
    Duration continuousSyncInterval = defaultContinuousSyncInterval,
    Duration? maxContinuousSyncInterval,
    Duration maxClockDrift = Hlc.defaultMaxDrift,
    OfflineSyncBatchBudget batchBudget = OfflineSyncBatchBudget.unlimited,
  }) {
    if (syncBatchSize < 1) {
      throw ArgumentError.value(syncBatchSize, 'syncBatchSize', 'Must be >= 1');
    }
    if (continuousSyncInterval.isNegative) {
      throw ArgumentError.value(
        continuousSyncInterval,
        'continuousSyncInterval',
        'Must be >= 0',
      );
    }
    if (maxClockDrift <= Duration.zero) {
      throw ArgumentError.value(maxClockDrift, 'maxClockDrift', 'Must be > 0');
    }
    return OfflineSyncSettings._(
      syncBatchSize,
      continuousSyncInterval,
      resolveMaxContinuousSyncInterval(
        continuousSyncInterval,
        maxContinuousSyncInterval,
      ),
      maxClockDrift,
      batchBudget,
    );
  }

  const OfflineSyncSettings._(
    this.syncBatchSize,
    this.continuousSyncInterval,
    this.maxContinuousSyncInterval,
    this.maxClockDrift,
    this.batchBudget,
  );

  /// Legacy maximum changes in one stream chunk.
  static const defaultSyncBatchSize = 100;

  /// Legacy continuous sync round interval.
  static const defaultContinuousSyncInterval = Duration(milliseconds: 200);

  /// Legacy maximum requested continuous sync interval.
  static const defaultMaxContinuousSyncInterval = Duration(seconds: 30);

  /// Opt-in server preset: 30-minute drift, one-second rounds, JSON-bounded
  /// batches of at most 5,000 changes / 7 Mi characters (except indivisible
  /// units that the planner must send together to make progress).
  static final boundedServer = OfflineSyncSettings(
    maxClockDrift: const Duration(minutes: 30),
    continuousSyncInterval: const Duration(seconds: 1),
    batchBudget: OfflineSyncBatchBudget.json(
      maxChanges: 5000,
      maxPayloadChars: 7 * 1024 * 1024,
    ),
  );

  /// Opt-in client preset: one-hour drift and the same outbound batch budget
  /// as [boundedServer], with the legacy client round interval.
  static final boundedClient = OfflineSyncSettings(
    batchBudget: boundedServer.batchBudget,
  );

  /// Maximum changes per stream chunk, distinct from a whole batch's budget.
  final int syncBatchSize;

  /// Minimum continuous round interval.
  final Duration continuousSyncInterval;

  /// Maximum requested continuous round interval.
  final Duration maxContinuousSyncInterval;

  /// Accepted local and remote clock drift.
  final Duration maxClockDrift;

  /// Outbound batch budget.
  final OfflineSyncBatchBudget batchBudget;

  /// Resolves the legacy implicit maximum without changing its behavior.
  static Duration resolveMaxContinuousSyncInterval(
    Duration continuousSyncInterval,
    Duration? maxContinuousSyncInterval,
  ) {
    if (maxContinuousSyncInterval == null) {
      return continuousSyncInterval > defaultMaxContinuousSyncInterval
          ? continuousSyncInterval
          : defaultMaxContinuousSyncInterval;
    }
    if (maxContinuousSyncInterval < continuousSyncInterval) {
      throw ArgumentError.value(
        maxContinuousSyncInterval,
        'maxContinuousSyncInterval',
        'Must be >= continuousSyncInterval ($continuousSyncInterval)',
      );
    }
    return maxContinuousSyncInterval;
  }

  /// Overrides selected settings while retaining every other setting.
  OfflineSyncSettings copyWith({
    int? syncBatchSize,
    Duration? continuousSyncInterval,
    Duration? maxContinuousSyncInterval,
    Duration? maxClockDrift,
    OfflineSyncBatchBudget? batchBudget,
  }) => OfflineSyncSettings(
    syncBatchSize: syncBatchSize ?? this.syncBatchSize,
    continuousSyncInterval: continuousSyncInterval ?? this.continuousSyncInterval,
    maxContinuousSyncInterval:
        maxContinuousSyncInterval ?? this.maxContinuousSyncInterval,
    maxClockDrift: maxClockDrift ?? this.maxClockDrift,
    batchBudget: batchBudget ?? this.batchBudget,
  );

  /// Checks that an already wrapped DB will not silently ignore new settings.
  void requireMatches(OfflineSyncSettings actual) {
    final requestedBudget = batchBudget;
    final actualBudget = actual.batchBudget;
    if (syncBatchSize != actual.syncBatchSize ||
        continuousSyncInterval != actual.continuousSyncInterval ||
        maxContinuousSyncInterval != actual.maxContinuousSyncInterval ||
        maxClockDrift != actual.maxClockDrift ||
        requestedBudget.maxChanges != actualBudget.maxChanges ||
        requestedBudget.maxPayloadChars != actualBudget.maxPayloadChars ||
        requestedBudget.measurePayload != actualBudget.measurePayload) {
      throw ArgumentError(
        'Settings conflict with the already wrapped OfflineSyncDatabase. Open a raw client session before applying new settings.',
      );
    }
  }
}
