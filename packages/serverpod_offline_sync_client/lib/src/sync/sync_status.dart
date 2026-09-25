import 'dart:async';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:serverpod_client/serverpod_client.dart';
import 'package:serverpod_database/serverpod_database.dart' show DatabaseDialect;
import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';

import 'failure.dart';

/// Whether an [OfflineSyncStatusTracker.syncOnce] round is running.
enum OfflineSyncPhase {
  /// No [OfflineSyncStatusTracker.syncOnce] round is running. A continuous
  /// session may still be.
  idle,

  /// An [OfflineSyncStatusTracker.syncOnce] round is running.
  syncing,
}

/// A snapshot of a device's sync state, published by
/// [OfflineSyncStatusTracker] as one value so the fields never disagree
/// within a frame.
///
/// Mirrors co_sync's `CoSyncStatus`: [unsentRowCount] is its `pendingCount`,
/// [phase] its `inFlight`. The fork has no quarantine, so a permanent refusal
/// shows as a permanent [lastFailure] instead.
@immutable
class OfflineSyncStatus {
  /// Creates a status snapshot.
  const OfflineSyncStatus({
    this.phase = OfflineSyncPhase.idle,
    this.unsentRowCount,
    this.lastSuccessAt,
    this.lastFailure,
    this.lastFailureAt,
  });

  /// Whether a [OfflineSyncStatusTracker.syncOnce] round is running.
  final OfflineSyncPhase phase;

  /// The rows holding a change this device wrote that the server has not
  /// confirmed yet, see [OfflineSyncDatabase.unsentRowCount].
  ///
  /// Null means unknown: not counted yet, or the last count failed. It is not
  /// zero, so never read null as "nothing to send".
  final int? unsentRowCount;

  /// When the last [OfflineSyncStatusTracker.syncOnce] round succeeded, or null
  /// if none has.
  final DateTime? lastSuccessAt;

  /// The last failure, cleared by the next successful
  /// [OfflineSyncStatusTracker.syncOnce] round.
  final OfflineSyncFailure? lastFailure;

  /// When [lastFailure] happened. Null exactly when [lastFailure] is.
  final DateTime? lastFailureAt;

  /// Whether nothing is left to do: no round running, no failure, and nothing
  /// unsent. False while [unsentRowCount] is unknown.
  bool get isIdle =>
      phase == OfflineSyncPhase.idle && lastFailure == null && unsentRowCount == 0;

  /// Whether the user has to act: the last failure is permanent (see
  /// [OfflineSyncFailure.isPermanent]). A transient failure, such as a lost
  /// connection, does not count: the next round retries it.
  bool get needsAttention => lastFailure?.isPermanent ?? false;

  /// A copy with the given fields replaced.
  ///
  /// [clearUnsentRowCount] sets [unsentRowCount] to null (unknown).
  /// [clearLastFailure] clears [lastFailure] and [lastFailureAt].
  OfflineSyncStatus copyWith({
    OfflineSyncPhase? phase,
    int? unsentRowCount,
    DateTime? lastSuccessAt,
    OfflineSyncFailure? lastFailure,
    DateTime? lastFailureAt,
    bool clearUnsentRowCount = false,
    bool clearLastFailure = false,
  }) => OfflineSyncStatus(
    phase: phase ?? this.phase,
    unsentRowCount: clearUnsentRowCount
        ? null
        : (unsentRowCount ?? this.unsentRowCount),
    lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    lastFailure: clearLastFailure ? null : (lastFailure ?? this.lastFailure),
    lastFailureAt: clearLastFailure ? null : (lastFailureAt ?? this.lastFailureAt),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OfflineSyncStatus &&
          other.phase == phase &&
          other.unsentRowCount == unsentRowCount &&
          other.lastSuccessAt == lastSuccessAt &&
          other.lastFailure == lastFailure &&
          other.lastFailureAt == lastFailureAt;

  @override
  int get hashCode =>
      Object.hash(phase, unsentRowCount, lastSuccessAt, lastFailure, lastFailureAt);

  @override
  String toString() =>
      'OfflineSyncStatus(${phase.name}, unsent=$unsentRowCount, '
      'lastSuccessAt=$lastSuccessAt, lastFailure=$lastFailure, '
      'lastFailureAt=$lastFailureAt)';
}

/// Runs a device's sync rounds and publishes their [OfflineSyncStatus].
///
/// Keep one tracker per sync session: [OfflineSyncClient] is created anew on
/// every `client.offlineSync` access and holds no state.
///
/// ```dart
/// final tracker = OfflineSyncStatusTracker(client.offlineSync, session);
/// tracker.statusChanges.listen(render);
/// await tracker.syncOnce();
/// ```
///
/// [OfflineSyncStatus.unsentRowCount] is counted from the database, one count
/// at a time, each started after what triggered it: a commit that can change it
/// (SQLite only, so offline writes show up without a sync), the end of a round,
/// or [refreshUnsentRowCount]. The end of a [syncOnce] round is published
/// together with the count read after it, in one [statusChanges] event.
class OfflineSyncStatusTracker {
  /// Creates a tracker that syncs a session through a client's sync helpers.
  ///
  /// With [watchUnsentRows], commits that can change the unsent row count
  /// trigger a recount, at most once per [unsentRowsThrottle]. Where the
  /// database cannot watch (not SQLite), the count is read on creation, after
  /// rounds, and on [refreshUnsentRowCount] only.
  ///
  /// `unsentRowCounter` replaces [OfflineSyncDatabase.unsentRowCount] as the
  /// count, so a test can hold or fail one.
  OfflineSyncStatusTracker(
    this._client,
    this._session, {
    bool watchUnsentRows = true,
    Duration unsentRowsThrottle = const Duration(milliseconds: 250),
    @visibleForTesting this._unsentRowCounter,
  }) {
    if (watchUnsentRows) _watchUnsentRows(unsentRowsThrottle);
    // The watch emits on listen, which counts. Without it, count once now.
    if (_triggers == null) unawaited(_recount());
  }

  final OfflineSyncClient _client;
  final OfflineSyncDatabaseSession _session;
  final Future<int> Function()? _unsentRowCounter;

  final _statusChanges = StreamController<OfflineSyncStatus>.broadcast();
  var _status = const OfflineSyncStatus();
  var _disposed = false;

  StreamSubscription<void>? _triggers;
  Future<void>? _syncOnce;

  _CountRound? _nextCountRound;
  Future<void>? _counting;

  /// The current status.
  OfflineSyncStatus get status => _status;

  /// Emits each new status. Only emits when the status changed.
  ///
  /// A broadcast stream: read [status] for the current value when listening.
  Stream<OfflineSyncStatus> get statusChanges => _statusChanges.stream;

  /// Runs one sync round, see [OfflineSyncClient.syncOnce].
  ///
  /// Publishes [OfflineSyncPhase.syncing], then, in one event, the outcome
  /// (phase back to idle, [OfflineSyncStatus.lastSuccessAt] or
  /// [OfflineSyncStatus.lastFailure] classified by [OfflineSyncFailure.from])
  /// with the unsent row count read after the round. A failure is also thrown.
  ///
  /// A call while a round runs joins it instead of starting another: it
  /// completes with that round, and its [onMergeSuccess] is not called. Writes
  /// made during a round may not be sent by it; check the count afterwards.
  Future<void> syncOnce({OfflineSyncOnMergeSuccess? onMergeSuccess}) {
    if (_disposed) {
      return Future.error(StateError('The OfflineSyncStatusTracker is disposed.'));
    }
    return _syncOnce ??= _runSyncOnce(onMergeSuccess).whenComplete(() {
      _syncOnce = null;
    });
  }

  Future<void> _runSyncOnce(OfflineSyncOnMergeSuccess? onMergeSuccess) async {
    _publish(_status.copyWith(phase: OfflineSyncPhase.syncing));
    try {
      await _client.syncOnce(_session, onMergeSuccess: onMergeSuccess);
    } on Object catch (error) {
      final failure = OfflineSyncFailure.from(error);
      final failedAt = clock.now();
      await _recount(
        outcome: (status) => status.copyWith(
          phase: OfflineSyncPhase.idle,
          lastFailure: failure,
          lastFailureAt: failedAt,
        ),
      );
      rethrow;
    }
    final succeededAt = clock.now();
    await _recount(
      outcome: (status) => status.copyWith(
        phase: OfflineSyncPhase.idle,
        lastSuccessAt: succeededAt,
        clearLastFailure: true,
      ),
    );
  }

  /// Starts a continuous sync session, see
  /// [OfflineSyncClient.syncContinuously].
  ///
  /// It leaves [OfflineSyncStatus.phase] and [OfflineSyncStatus.lastSuccessAt]
  /// alone: its rounds have no end the server confirms. When it ends with an
  /// error, the error becomes [OfflineSyncStatus.lastFailure] and counts as
  /// handled; [OfflineSyncSubscription.done] still completes with it. The count
  /// is read again when it ends.
  ///
  /// [continuousSyncInterval] asks for a longer wait between rounds, see
  /// [OfflineSyncClient.syncContinuously] (unibook#14207).
  OfflineSyncSubscription syncContinuously({
    OfflineSyncOnMergeSuccess? onMergeSuccess,
    Duration? continuousSyncInterval,
  }) {
    final OfflineSyncSubscription subscription;
    try {
      subscription = _client.syncContinuously(
        _session,
        onMergeSuccess: onMergeSuccess,
        continuousSyncInterval: continuousSyncInterval,
      );
    } on Object catch (error) {
      unawaited(_recordContinuousFailure(error));
      rethrow;
    }
    unawaited(
      subscription.done.then(
        (_) => _recount(),
        onError: _recordContinuousFailure,
      ),
    );
    return subscription;
  }

  Future<void> _recordContinuousFailure(Object error) {
    final failure = OfflineSyncFailure.from(error);
    final failedAt = clock.now();
    return _recount(
      outcome: (status) =>
          status.copyWith(lastFailure: failure, lastFailureAt: failedAt),
    );
  }

  /// Reads the unsent row count from the database now, for a decision that
  /// must not use a stale value, such as a sign-out warning. Throws when the
  /// count fails. Does not change [status].
  Future<int> countUnsentRows() => _countUnsentRows();

  Future<int> _countUnsentRows() =>
      _unsentRowCounter?.call() ?? _session.db.unsentRowCount();

  /// Counts the unsent rows again and publishes the result. A failed count
  /// publishes null (unknown) instead of throwing.
  Future<void> refreshUnsentRowCount() => _recount();

  /// Stops watching the database and closes [statusChanges]. A round still
  /// running finishes without publishing.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _triggers?.cancel();
    _triggers = null;
    await _statusChanges.close();
  }

  void _watchUnsentRows(Duration throttle) {
    // Only SQLite can watch; any other database throws UnsupportedError.
    if (_session.db.dialect != DatabaseDialect.sqlite) return;
    _triggers = _session.db
        .watchUnsentRowCountTriggers(throttle: throttle)
        .listen(
          (_) => unawaited(_recount()),
          onError: (Object _) {
            // The watch is gone (for example, the database closed). Keep counting
            // on rounds and requests only.
            _triggers = null;
            unawaited(_recount());
          },
          cancelOnError: true,
        );
  }

  /// Counts in a round that starts after this call, applying [outcome] to the
  /// status together with the count.
  ///
  /// Rounds run one at a time. Calls made while a round runs share the next
  /// round, so every published count was read after whatever asked for it,
  /// and an older count never replaces a newer one.
  Future<void> _recount({_StatusUpdate? outcome}) {
    if (_disposed) return Future.value();
    final round = _nextCountRound ??= _CountRound();
    if (outcome != null) round.outcomes.add(outcome);
    _counting ??= _runCountRounds();
    return round.done.future;
  }

  Future<void> _runCountRounds() async {
    try {
      for (var round = _nextCountRound; round != null; round = _nextCountRound) {
        _nextCountRound = null;
        int? count;
        try {
          count = await _countUnsentRows();
        } on Object catch (_) {
          // Unknown, not zero: the status must not claim nothing is unsent.
          count = null;
        }
        var next = _status.copyWith(
          unsentRowCount: count,
          clearUnsentRowCount: count == null,
        );
        for (final outcome in round.outcomes) {
          next = outcome(next);
        }
        _publish(next);
        round.done.complete();
      }
    } finally {
      _counting = null;
    }
  }

  void _publish(OfflineSyncStatus next) {
    if (_disposed || next == _status) return;
    _status = next;
    _statusChanges.add(next);
  }
}

typedef _StatusUpdate = OfflineSyncStatus Function(OfflineSyncStatus status);

/// One unsent row count and the status updates published with it.
class _CountRound {
  final outcomes = <_StatusUpdate>[];
  final done = Completer<void>();
}
