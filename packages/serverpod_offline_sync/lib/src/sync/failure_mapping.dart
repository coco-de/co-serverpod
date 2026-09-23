import 'dart:async';

import '../generated/protocol.dart';
import '../hlc/exceptions.dart';
import 'exceptions.dart';

/// Maps a sync failure observed **on the server** to the error the server
/// should send to the device.
///
/// Serverpod forwards only `SerializableException`s from a streaming endpoint;
/// any other exception reaches the device as a plain connection error. This
/// returns an [OfflineSyncRemoteException] for the sync failures that would be
/// lost that way, and [error] unchanged for everything else:
///
/// | Server-side failure | [OfflineSyncFailureCode] |
/// |---|---|
/// | [ClockDriftException] with [ClockDriftKind.remoteAhead] | [OfflineSyncFailureCode.clockDrift] |
/// | [ClockDriftException] with [ClockDriftKind.localAhead] | [OfflineSyncFailureCode.serverClockDrift] |
/// | [OverflowException] | [OfflineSyncFailureCode.hlcOverflow] |
/// | [DuplicateNodeException] | [OfflineSyncFailureCode.duplicateNode] |
/// | [OfflineSyncIntegrityViolationException] | [OfflineSyncFailureCode.integrityViolation] |
///
/// The clock drift codes describe the server's point of view: `remoteAhead`
/// on the server means a device timestamp was ahead of the server clock, and
/// `localAhead` means the server could not issue its own timestamp. Do not use
/// this for failures raised on a device, where the same kinds mean the
/// opposite.
///
/// [OfflineSyncTablesHashMismatchException] is passed through: each peer
/// verifies the other's schema hash itself and gets a typed exception anyway.
///
/// The message is the server exception's own, except for an integrity
/// violation. That message names the space that owns the row, which for a
/// personal space is another user's id, and the server's row id of the
/// persisted violation. The device gets a fixed text instead; the server keeps
/// the original in its log through [offlineSyncWireErrors].
Object toOfflineSyncWireError(Object error) {
  return switch (error) {
    ClockDriftException() => OfflineSyncRemoteException(
      code: switch (error.kind) {
        ClockDriftKind.remoteAhead => OfflineSyncFailureCode.clockDrift,
        ClockDriftKind.localAhead => OfflineSyncFailureCode.serverClockDrift,
      },
      message: error.toString(),
      driftMs: _millisecondsRoundedUp(error.drift),
      maxDriftMs: error.maxDrift.inMilliseconds,
    ),
    OverflowException() => OfflineSyncRemoteException(
      code: OfflineSyncFailureCode.hlcOverflow,
      message: error.toString(),
    ),
    DuplicateNodeException() => OfflineSyncRemoteException(
      code: OfflineSyncFailureCode.duplicateNode,
      message: error.toString(),
    ),
    OfflineSyncIntegrityViolationException() => OfflineSyncRemoteException(
      code: OfflineSyncFailureCode.integrityViolation,
      message: _integrityViolationWireMessage,
    ),
    _ => error,
  };
}

/// What the device reads for [OfflineSyncFailureCode.integrityViolation].
///
/// Carries no identifier: see [toOfflineSyncWireError].
const _integrityViolationWireMessage =
    'OfflineSyncIntegrityViolationException: sync stopped on a CRDT integrity '
    'violation. The server log has the details.';

/// [duration] in whole milliseconds, rounded up.
///
/// `Hlc.merge` compares against a wall clock with microsecond precision, so a
/// timestamp less than a millisecond over the limit is rejected with a drift
/// that [Duration.inMilliseconds] would truncate to the limit itself. Rounding
/// the drift up while the limit is truncated keeps `driftMs > maxDriftMs` for
/// every rejected timestamp.
int _millisecondsRoundedUp(Duration duration) {
  final microseconds = duration.inMicroseconds;
  final milliseconds = microseconds ~/ Duration.microsecondsPerMillisecond;
  return microseconds > milliseconds * Duration.microsecondsPerMillisecond
      ? milliseconds + 1
      : milliseconds;
}

/// A stream transformer that replaces each error with
/// [toOfflineSyncWireError] and keeps its stack trace.
///
/// When an error is replaced, [onMapped] receives the original error and its
/// stack trace. It runs after the replacement is emitted, so a callback that
/// throws cannot take the replacement's place. Serverpod logs only the error
/// the stream ends with, so without [onMapped] the server log keeps the
/// replacement alone, and for an integrity violation that drops the details.
///
/// The server module applies it in `OfflineSyncSession.sync` and logs the
/// original to the session. An app endpoint that calls the engine directly
/// (`session.offlineSyncDb.sync`) must apply it too, or the device loses the
/// failure type again.
StreamTransformer<OfflineSyncStreamEvent, OfflineSyncStreamEvent>
offlineSyncWireErrors({
  void Function(Object error, StackTrace stackTrace)? onMapped,
}) => StreamTransformer.fromHandlers(
  handleError: (error, stackTrace, sink) {
    final wireError = toOfflineSyncWireError(error);
    sink.addError(wireError, stackTrace);
    if (!identical(wireError, error)) onMapped?.call(error, stackTrace);
  },
);
