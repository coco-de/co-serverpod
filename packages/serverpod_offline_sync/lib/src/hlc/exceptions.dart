import 'package:serverpod_serialization/serverpod_serialization.dart';

/// Which timestamp a [ClockDriftException] rejected.
enum ClockDriftKind {
  /// A remote timestamp was more than the allowed drift ahead of the local wall
  /// clock. Thrown by `Hlc.merge` while merging changes from another node.
  remoteAhead,

  /// This node's own last timestamp was more than the allowed drift ahead of
  /// the local wall clock, so no new local timestamp could be issued. Thrown by
  /// `Hlc.increment`, which every local CRDT write goes through. It means the
  /// wall clock moved back, or a timestamp merged earlier pulled this clock
  /// ahead of it.
  localAhead,
}

/// Exception thrown when the clock drift exceeds the maximum allowed.
class ClockDriftException implements Exception {
  /// Creates a new instance of [ClockDriftException].
  ///
  /// The [drift] is how far [dateTime] is ahead of [wallTime].
  ClockDriftException(
    DateTime dateTime,
    DateTime wallTime,
    this.maxDrift, {
    required this.kind,
    this.remoteNodeId,
  }) : drift = dateTime.difference(wallTime);

  /// The duration of the clock drift.
  final Duration drift;

  /// The maximum allowed clock drift.
  final Duration maxDrift;

  /// Which timestamp was rejected.
  final ClockDriftKind kind;

  /// The node that authored the rejected remote timestamp, for
  /// [ClockDriftKind.remoteAhead]. Null for [ClockDriftKind.localAhead].
  final UuidValue? remoteNodeId;

  @override
  String toString() {
    final node = remoteNodeId == null ? '' : ' from node $remoteNodeId';
    return 'ClockDriftException(${kind.name}): clock drift of '
        '${drift.inMilliseconds} ms$node exceeds the maximum of '
        '${maxDrift.inMilliseconds} ms';
  }
}

/// Exception thrown when the timestamp counter overflows.
class OverflowException implements Exception {
  /// Creates a new instance of [OverflowException].
  OverflowException(this.counter);

  /// The counter that overflowed.
  final int counter;

  @override
  String toString() => 'Timestamp counter overflow: $counter';
}

/// Exception thrown when a duplicate node is detected.
class DuplicateNodeException implements Exception {
  /// Creates a new instance of [DuplicateNodeException].
  DuplicateNodeException(this.nodeId);

  /// The node ID that is duplicated.
  final UuidValue nodeId;

  @override
  String toString() => 'Duplicate node: $nodeId';
}
