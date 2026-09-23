/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters
// ignore_for_file: invalid_use_of_internal_member

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:serverpod_serialization/serverpod_serialization.dart' as _iss;

/// Why a sync peer stopped a round, carried to the other peer inside an
/// [OfflineSyncRemoteException].
///
/// Only failures whose type Serverpod would otherwise lose on the wire are
/// listed. A schema hash mismatch is not: each peer verifies the other's hash
/// itself and already gets a typed exception. New values break exhaustive
/// switches in consumers, so add them deliberately.
enum OfflineSyncFailureCode implements _iss.SerializableModel {
  /// The server rejected a device timestamp that is further ahead of the
  /// server clock than its maxClockDrift: the device clock is ahead. Same
  /// meaning as co_sync's `clock_drift`.
  clockDrift,

  /// The server could not issue its own timestamp because its node clock is
  /// further ahead of the server wall clock than its maxClockDrift. The shared
  /// server node was pulled ahead, or the server clock went back. Not the
  /// device's fault.
  serverClockDrift,

  /// The server's timestamp counter overflowed while its node clock stayed
  /// ahead of the wall clock.
  hlcOverflow,

  /// Two nodes share one node id.
  duplicateNode,

  /// The server observed a terminal CRDT integrity violation, such as a write
  /// to a space the user may only read.
  integrityViolation;

  static OfflineSyncFailureCode fromJson(String name) {
    switch (name) {
      case 'clockDrift':
        return OfflineSyncFailureCode.clockDrift;
      case 'serverClockDrift':
        return OfflineSyncFailureCode.serverClockDrift;
      case 'hlcOverflow':
        return OfflineSyncFailureCode.hlcOverflow;
      case 'duplicateNode':
        return OfflineSyncFailureCode.duplicateNode;
      case 'integrityViolation':
        return OfflineSyncFailureCode.integrityViolation;
      default:
        throw ArgumentError(
          'Value "$name" cannot be converted to "OfflineSyncFailureCode"',
        );
    }
  }

  @override
  String toJson() => name;

  @override
  String toString() => name;
}
