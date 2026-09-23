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
      message: error.toString(),
    ),
    _ => error,
  };
}

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
/// The server module applies it in `OfflineSyncSession.sync`. An app endpoint
/// that calls the engine directly (`session.db.offlineSyncDb.sync`) must apply
/// it too, or the device loses the failure type again.
StreamTransformer<OfflineSyncStreamEvent, OfflineSyncStreamEvent>
offlineSyncWireErrors() => StreamTransformer.fromHandlers(
  handleError: (error, stackTrace, sink) =>
      sink.addError(toOfflineSyncWireError(error), stackTrace),
);
