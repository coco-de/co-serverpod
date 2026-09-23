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
import 'package:serverpod/serverpod.dart' as _is;

abstract class LocalDraft
    implements _is.SerializableModel, _is.ProtocolSerialization {
  LocalDraft._({this.id, required this.body});

  factory LocalDraft({int? id, required String body}) = _LocalDraftImpl;

  factory LocalDraft.fromJson(Map<String, dynamic> jsonSerialization) {
    return LocalDraft(
      id: jsonSerialization['id'] as int?,
      body: jsonSerialization['body'] as String,
    );
  }

  /// The database id, set if the object has been inserted into the
  /// database or if it has been fetched from the database. Otherwise,
  /// the id will be null.
  int? id;

  String body;

  /// Returns a shallow copy of this [LocalDraft]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  LocalDraft copyWith({int? id, String? body});
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'LocalDraft',
      if (id != null) 'id': id,
      'body': body,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'LocalDraft',
      if (id != null) 'id': id,
      'body': body,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _LocalDraftImpl extends LocalDraft {
  _LocalDraftImpl({int? id, required String body})
    : super._(id: id, body: body);

  /// Returns a shallow copy of this [LocalDraft]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  LocalDraft copyWith({Object? id = _Undefined, String? body}) {
    return LocalDraft(id: id is int? ? id : this.id, body: body ?? this.body);
  }
}
