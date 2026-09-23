import 'dart:async';

import 'package:serverpod_client/serverpod_client.dart';
import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';

/// Why a sync round failed, as seen by this device.
///
/// The first five values mirror [OfflineSyncFailureCode], the codes the server
/// sends. The rest are failures this device observes itself.
enum OfflineSyncFailureReason {
  /// The server rejected this device's timestamps: this device's clock is
  /// ahead. Same meaning as co_sync's `clock_drift`.
  clockDrift,

  /// The server could not issue its own timestamp: its node clock is ahead of
  /// its wall clock. Not this device's fault.
  serverClockDrift,

  /// A timestamp counter overflowed while its clock stayed ahead of the wall
  /// clock. Clears once the wall clock catches up.
  hlcOverflow,

  /// Two nodes share one node id.
  duplicateNode,

  /// A terminal CRDT integrity violation, such as a write to a space this user
  /// may only read.
  integrityViolation,

  /// This device rejected a server timestamp too far ahead of its own clock:
  /// this device's clock is behind. Same meaning as co_sync's
  /// `clock_drift_behind`. It can also mean another device pulled the shared
  /// server clock ahead; the device cannot tell the two apart.
  clockDriftBehind,

  /// This device could not issue a local timestamp because its wall clock
  /// moved back behind its last timestamp by more than the allowed drift.
  /// Local writes fail the same way until the wall clock catches up.
  clockRollback,

  /// The peers disagree on the synchronized schema hash. The direction (this
  /// app is outdated, or the server is behind during a rolling deploy) is not
  /// decided here; the app owns that call.
  schemaMismatch,

  /// The connection failed or closed before the round finished.
  transport,

  /// Anything else.
  unknown;

  /// Whether retrying cannot succeed without outside action.
  ///
  /// Clock, overflow, transport and unknown failures can clear on their own,
  /// so they are not permanent. [schemaMismatch] is not permanent either,
  /// because a server that is behind catches up; an app that decides the app
  /// itself is outdated should treat it as permanent.
  bool get isPermanent => switch (this) {
    duplicateNode || integrityViolation => true,
    clockDrift ||
    serverClockDrift ||
    hlcOverflow ||
    clockDriftBehind ||
    clockRollback ||
    schemaMismatch ||
    transport ||
    unknown => false,
  };

  /// Whether the fix is to check this device's clock: [clockDrift] (ahead),
  /// [clockDriftBehind] (behind) or [clockRollback] (moved back).
  bool get isClockDrift => switch (this) {
    clockDrift || clockDriftBehind || clockRollback => true,
    serverClockDrift ||
    hlcOverflow ||
    duplicateNode ||
    integrityViolation ||
    schemaMismatch ||
    transport ||
    unknown => false,
  };
}

/// A sync failure classified for the app, from the error a sync call threw.
///
/// ```dart
/// try {
///   await client.offlineSync.syncOnce(session);
/// } on Object catch (error) {
///   final failure = OfflineSyncFailure.from(error);
///   if (failure.isClockDrift) showCheckClockHint();
/// }
/// ```
@immutable
class OfflineSyncFailure {
  /// Creates a classified failure.
  const OfflineSyncFailure({
    required this.code,
    required this.error,
    this.drift,
    this.maxDrift,
  });

  /// Classifies [error].
  ///
  /// | Error | [code] |
  /// |---|---|
  /// | [OfflineSyncRemoteException] | its [OfflineSyncFailureCode] |
  /// | [ClockDriftException] with [ClockDriftKind.remoteAhead] | [OfflineSyncFailureReason.clockDriftBehind] |
  /// | [ClockDriftException] with [ClockDriftKind.localAhead] | [OfflineSyncFailureReason.clockRollback] |
  /// | [OverflowException] | [OfflineSyncFailureReason.hlcOverflow] |
  /// | [DuplicateNodeException] | [OfflineSyncFailureReason.duplicateNode] |
  /// | [OfflineSyncIntegrityViolationException] | [OfflineSyncFailureReason.integrityViolation] |
  /// | [OfflineSyncTablesHashMismatchException] | [OfflineSyncFailureReason.schemaMismatch] |
  /// | [MethodStreamException], [OfflineSyncStreamClosedException], [TimeoutException] | [OfflineSyncFailureReason.transport] |
  /// | anything else | [OfflineSyncFailureReason.unknown] |
  ///
  /// A [ClockDriftException] reaching this device was raised by this device's
  /// own clock, because the server sends its drift failures as an
  /// [OfflineSyncRemoteException]. That is why `remoteAhead` here means this
  /// device is behind.
  factory OfflineSyncFailure.from(Object error) {
    return switch (error) {
      OfflineSyncRemoteException() => OfflineSyncFailure(
        code: switch (error.code) {
          OfflineSyncFailureCode.clockDrift => OfflineSyncFailureReason.clockDrift,
          OfflineSyncFailureCode.serverClockDrift =>
            OfflineSyncFailureReason.serverClockDrift,
          OfflineSyncFailureCode.hlcOverflow => OfflineSyncFailureReason.hlcOverflow,
          OfflineSyncFailureCode.duplicateNode =>
            OfflineSyncFailureReason.duplicateNode,
          OfflineSyncFailureCode.integrityViolation =>
            OfflineSyncFailureReason.integrityViolation,
        },
        error: error,
        drift: _millisecondsOrNull(error.driftMs),
        maxDrift: _millisecondsOrNull(error.maxDriftMs),
      ),
      ClockDriftException() => OfflineSyncFailure(
        code: switch (error.kind) {
          ClockDriftKind.remoteAhead => OfflineSyncFailureReason.clockDriftBehind,
          ClockDriftKind.localAhead => OfflineSyncFailureReason.clockRollback,
        },
        error: error,
        drift: error.drift,
        maxDrift: error.maxDrift,
      ),
      OverflowException() => OfflineSyncFailure(
        code: OfflineSyncFailureReason.hlcOverflow,
        error: error,
      ),
      DuplicateNodeException() => OfflineSyncFailure(
        code: OfflineSyncFailureReason.duplicateNode,
        error: error,
      ),
      OfflineSyncIntegrityViolationException() => OfflineSyncFailure(
        code: OfflineSyncFailureReason.integrityViolation,
        error: error,
      ),
      OfflineSyncTablesHashMismatchException() => OfflineSyncFailure(
        code: OfflineSyncFailureReason.schemaMismatch,
        error: error,
      ),
      MethodStreamException() ||
      OfflineSyncStreamClosedException() ||
      TimeoutException() => OfflineSyncFailure(
        code: OfflineSyncFailureReason.transport,
        error: error,
      ),
      _ => OfflineSyncFailure(code: OfflineSyncFailureReason.unknown, error: error),
    };
  }

  /// Why the round failed.
  final OfflineSyncFailureReason code;

  /// The error the sync call threw, for logs.
  final Object error;

  /// How far the rejected clock was ahead of the wall clock that checked it,
  /// for the clock drift reasons.
  final Duration? drift;

  /// The drift limit that rejected it, for the clock drift reasons. For
  /// [OfflineSyncFailureReason.clockDrift] this is the server's limit.
  final Duration? maxDrift;

  /// Whether retrying cannot succeed without outside action, see
  /// [OfflineSyncFailureReason.isPermanent].
  bool get isPermanent => code.isPermanent;

  /// Whether the fix is to check this device's clock, see
  /// [OfflineSyncFailureReason.isClockDrift].
  bool get isClockDrift => code.isClockDrift;

  static Duration? _millisecondsOrNull(int? milliseconds) =>
      milliseconds == null ? null : Duration(milliseconds: milliseconds);

  @override
  String toString() =>
      'OfflineSyncFailure(${code.name}, permanent=$isPermanent, '
      'clockDrift=$isClockDrift, error=$error)';
}
