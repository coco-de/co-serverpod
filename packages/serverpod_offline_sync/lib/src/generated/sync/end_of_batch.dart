/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters
// ignore_for_file: invalid_use_of_internal_member

part of 'stream_event.dart';

/// Marks the end of a framed sync batch.
abstract class OfflineSyncEndOfBatch extends _icw2tu00.OfflineSyncStreamEvent
    implements _iss.SerializableModel, _iss.ProtocolSerialization {
  OfflineSyncEndOfBatch._({this.hasMore});

  factory OfflineSyncEndOfBatch({bool? hasMore}) = _OfflineSyncEndOfBatchImpl;

  factory OfflineSyncEndOfBatch.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return OfflineSyncEndOfBatch(
      hasMore: jsonSerialization['hasMore'] == null
          ? null
          : _iss.BoolJsonExtension.fromJson(jsonSerialization['hasMore']),
    );
  }

  /// Whether this peer has more changes to send in this session than the
  /// batch it just closed (fork, unibook#14251).
  ///
  /// A peer with a batch budget ends its batch before the budget is exceeded
  /// and sends the rest in the next rounds. A `once` session then runs another
  /// round when either peer set it. A peer built with the field always sets
  /// it, true or false. Null comes from a peer built before the field existed,
  /// which ignores it (generated `fromJson` reads known keys only) and would
  /// close the session instead: a peer that reads null closes too and sends
  /// the rest in its next session.
  bool? hasMore;

  /// Returns a shallow copy of this [OfflineSyncEndOfBatch]
  /// with some or all fields replaced by the given arguments.
  @override
  @_iss.useResult
  OfflineSyncEndOfBatch copyWith({bool? hasMore});
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'serverpod_offline_sync.OfflineSyncEndOfBatch',
      if (hasMore != null) 'hasMore': hasMore,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'serverpod_offline_sync.OfflineSyncEndOfBatch',
      if (hasMore != null) 'hasMore': hasMore,
    };
  }

  @override
  String toString() {
    return _iss.SerializationManager.encode(this);
  }
}

class _OfflineSyncEndOfBatchImpl extends OfflineSyncEndOfBatch {
  _OfflineSyncEndOfBatchImpl({bool? hasMore}) : super._(hasMore: hasMore);

  /// Returns a shallow copy of this [OfflineSyncEndOfBatch]
  /// with some or all fields replaced by the given arguments.
  @_iss.useResult
  @override
  OfflineSyncEndOfBatch copyWith({Object? hasMore = _Undefined}) {
    return OfflineSyncEndOfBatch(
      hasMore: hasMore is bool? ? hasMore : this.hasMore,
    );
  }
}
