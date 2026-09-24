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
import 'package:serverpod_offline_sync/serverpod_offline_sync.dart'
    as _icw2tu00;
import 'package:serverpod_serialization/serverpod_serialization.dart' as _iss;

/// A sync failure the server sends to the device in place of an exception
/// whose type Serverpod would drop on the wire.
///
/// Serverpod forwards only `SerializableException`s thrown by a streaming
/// endpoint. Any other exception closes the stream and reaches the device as a
/// plain connection error, indistinguishable from a network failure. The
/// server facade `OfflineSyncSession.sync` maps known sync failures to this
/// exception, see `toOfflineSyncWireError`.
abstract class OfflineSyncRemoteException
    implements
        _iss.SerializableException,
        _iss.SerializableModel,
        _iss.ProtocolSerialization {
  OfflineSyncRemoteException._({
    required this.code,
    required this.message,
    this.driftMs,
    this.maxDriftMs,
  });

  factory OfflineSyncRemoteException({
    required _icw2tu00.OfflineSyncFailureCode code,
    required String message,
    int? driftMs,
    int? maxDriftMs,
  }) = _OfflineSyncRemoteExceptionImpl;

  factory OfflineSyncRemoteException.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return OfflineSyncRemoteException(
      code: _icw2tu00.OfflineSyncFailureCode.fromJson(
        (jsonSerialization['code'] as String),
      ),
      message: jsonSerialization['message'] as String,
      driftMs: jsonSerialization['driftMs'] as int?,
      maxDriftMs: jsonSerialization['maxDriftMs'] as int?,
    );
  }

  /// Why the round failed.
  _icw2tu00.OfflineSyncFailureCode code;

  /// The server-side exception message, for logs and diagnostics. For
  /// `integrityViolation` it is a fixed text without identifiers: the original
  /// names the space that owns the row, which can be another user's. The server
  /// log keeps the original.
  String message;

  /// How far the rejected clock was ahead of the server wall clock, in
  /// milliseconds. Set for the clock drift codes.
  int? driftMs;

  /// The server's maxClockDrift in milliseconds. Set for the clock drift codes.
  int? maxDriftMs;

  /// Returns a shallow copy of this [OfflineSyncRemoteException]
  /// with some or all fields replaced by the given arguments.
  @_iss.useResult
  OfflineSyncRemoteException copyWith({
    _icw2tu00.OfflineSyncFailureCode? code,
    String? message,
    int? driftMs,
    int? maxDriftMs,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'serverpod_offline_sync.OfflineSyncRemoteException',
      'code': code.toJson(),
      'message': message,
      if (driftMs != null) 'driftMs': driftMs,
      if (maxDriftMs != null) 'maxDriftMs': maxDriftMs,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'serverpod_offline_sync.OfflineSyncRemoteException',
      'code': code.toJson(),
      'message': message,
      if (driftMs != null) 'driftMs': driftMs,
      if (maxDriftMs != null) 'maxDriftMs': maxDriftMs,
    };
  }

  @override
  String toString() {
    return 'OfflineSyncRemoteException(code: $code, message: $message, driftMs: $driftMs, maxDriftMs: $maxDriftMs)';
  }
}

class _Undefined {}

class _OfflineSyncRemoteExceptionImpl extends OfflineSyncRemoteException {
  _OfflineSyncRemoteExceptionImpl({
    required _icw2tu00.OfflineSyncFailureCode code,
    required String message,
    int? driftMs,
    int? maxDriftMs,
  }) : super._(
         code: code,
         message: message,
         driftMs: driftMs,
         maxDriftMs: maxDriftMs,
       );

  /// Returns a shallow copy of this [OfflineSyncRemoteException]
  /// with some or all fields replaced by the given arguments.
  @_iss.useResult
  @override
  OfflineSyncRemoteException copyWith({
    _icw2tu00.OfflineSyncFailureCode? code,
    String? message,
    Object? driftMs = _Undefined,
    Object? maxDriftMs = _Undefined,
  }) {
    return OfflineSyncRemoteException(
      code: code ?? this.code,
      message: message ?? this.message,
      driftMs: driftMs is int? ? driftMs : this.driftMs,
      maxDriftMs: maxDriftMs is int? ? maxDriftMs : this.maxDriftMs,
    );
  }
}
