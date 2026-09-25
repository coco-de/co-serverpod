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
import 'dart:async' as _ida;
import 'package:serverpod/serverpod.dart' as _is;

/// A note's attachment. Deleting the note deletes it (fork, unibook#14251):
/// the batch budget tests need a cascading foreign key, whose delete the
/// recorder stamps right after its parent's as a cascade tombstone.
abstract class Attachment
    implements _is.TableRow<_is.UuidValue?>, _is.ProtocolSerialization {
  Attachment._({
    this.id,
    this.spaceId,
    required this.name,
    required this.noteId,
  });

  factory Attachment({
    _is.UuidValue? id,
    int? spaceId,
    required String name,
    required _is.UuidValue noteId,
  }) = _AttachmentImpl;

  factory Attachment.fromJson(Map<String, dynamic> jsonSerialization) {
    return Attachment(
      id: jsonSerialization['id'] == null
          ? null
          : _is.UuidValueJsonExtension.fromJson(jsonSerialization['id']),
      spaceId: jsonSerialization['spaceId'] as int?,
      name: jsonSerialization['name'] as String,
      noteId: _is.UuidValueJsonExtension.fromJson(jsonSerialization['noteId']),
    );
  }

  static final t = AttachmentTable();

  static const db = AttachmentRepository._();

  @override
  _is.UuidValue? id;

  /// The space owning this row. Maintained by the sync engine.
  int? spaceId;

  String name;

  _is.UuidValue noteId;

  @override
  _is.Table<_is.UuidValue?> get table => t;

  /// Returns a shallow copy of this [Attachment]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  Attachment copyWith({
    _is.UuidValue? id,
    int? spaceId,
    String? name,
    _is.UuidValue? noteId,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'Attachment',
      if (id != null) 'id': id?.toJson(),
      if (spaceId != null) 'spaceId': spaceId,
      'name': name,
      'noteId': noteId.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'Attachment',
      if (id != null) 'id': id?.toJson(),
      if (spaceId != null) 'spaceId': spaceId,
      'name': name,
      'noteId': noteId.toJson(),
    };
  }

  static AttachmentInclude include() {
    return AttachmentInclude._();
  }

  static AttachmentIncludeList includeList({
    _is.WhereExpressionBuilder<AttachmentTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<AttachmentTable>? orderBy,
    _is.OrderByListBuilder<AttachmentTable>? orderByList,
    AttachmentInclude? include,
  }) {
    return AttachmentIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Attachment.t),
      orderByList: orderByList?.call(Attachment.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _AttachmentImpl extends Attachment {
  _AttachmentImpl({
    _is.UuidValue? id,
    int? spaceId,
    required String name,
    required _is.UuidValue noteId,
  }) : super._(id: id, spaceId: spaceId, name: name, noteId: noteId);

  /// Returns a shallow copy of this [Attachment]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  Attachment copyWith({
    Object? id = _Undefined,
    Object? spaceId = _Undefined,
    String? name,
    _is.UuidValue? noteId,
  }) {
    return Attachment(
      id: id is _is.UuidValue? ? id : this.id,
      spaceId: spaceId is int? ? spaceId : this.spaceId,
      name: name ?? this.name,
      noteId: noteId ?? this.noteId,
    );
  }
}

class AttachmentUpdateTable extends _is.UpdateTable<AttachmentTable> {
  AttachmentUpdateTable(super.table);

  _is.ColumnValue<int, int> spaceId(int? value) =>
      _is.ColumnValue(table.spaceId, value);

  _is.ColumnValue<String, String> name(String value) =>
      _is.ColumnValue(table.name, value);

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> noteId(_is.UuidValue value) =>
      _is.ColumnValue(table.noteId, value);
}

class AttachmentTable extends _is.Table<_is.UuidValue?> {
  AttachmentTable({super.tableRelation}) : super(tableName: 'attachment') {
    updateTable = AttachmentUpdateTable(this);
    spaceId = _is.ColumnInt('spaceId', this);
    name = _is.ColumnString('name', this);
    noteId = _is.ColumnUuid('noteId', this);
  }

  late final AttachmentUpdateTable updateTable;

  /// The space owning this row. Maintained by the sync engine.
  late final _is.ColumnInt spaceId;

  late final _is.ColumnString name;

  late final _is.ColumnUuid noteId;

  @override
  List<_is.Column> get columns => [id, spaceId, name, noteId];
}

class AttachmentInclude extends _is.IncludeObject {
  AttachmentInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<_is.UuidValue?> get table => Attachment.t;
}

class AttachmentIncludeList extends _is.IncludeList {
  AttachmentIncludeList._({
    _is.WhereExpressionBuilder<AttachmentTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(Attachment.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<_is.UuidValue?> get table => Attachment.t;
}

class AttachmentRepository {
  const AttachmentRepository._();

  /// Returns a list of [Attachment]s matching the given query parameters.
  ///
  /// Use [where] to specify which items to include in the return value.
  /// If none is specified, all items will be returned.
  ///
  /// To specify the order of the items use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// The maximum number of items can be set by [limit]. If no limit is set,
  /// all items matching the query will be returned.
  ///
  /// [offset] defines how many items to skip, after which [limit] (or all)
  /// items are read from the database.
  ///
  /// ```dart
  /// var persons = await Persons.db.find(
  ///   session,
  ///   where: (t) => t.lastName.equals('Jones'),
  ///   orderBy: (t) => t.firstName,
  ///   limit: 100,
  /// );
  /// ```
  Future<List<Attachment>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<AttachmentTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<AttachmentTable>? orderBy,
    _is.OrderByListBuilder<AttachmentTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<Attachment>(
      where: where?.call(Attachment.t),
      orderBy: orderBy?.call(Attachment.t),
      orderByList: orderByList?.call(Attachment.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [Attachment]s matching the given query parameters every time the
  /// source tables are modified.
  ///
  /// Use [where] to specify which items to include in the return value.
  /// If none is specified, all items will be returned.
  ///
  /// To specify the order of the items use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// The maximum number of items can be set by [limit]. If no limit is set,
  /// all items matching the query will be returned.
  ///
  /// [offset] defines how many items to skip, after which [limit] (or all)
  /// items are read from the database.
  ///
  /// Use [throttle] to specify the minimum interval between queries. It can
  /// also be set to `null`, in which case the stream will only be throttled
  /// when its subscription is paused.
  ///
  /// Source tables are collected from the queried table, [where], [orderBy],
  /// [orderByList], and the [include] graph. [alsoTriggerOnTables] is added
  /// to that set. Pass [Table] instances such as `Attachment.t`.
  ///
  /// Raw [Expression] SQL is not inspected. Tables referenced only in raw
  /// SQL must be passed via [alsoTriggerOnTables].
  ///
  /// The stream always reads committed state and never joins an ambient
  /// [Transaction]. Emissions for a write fire after that write commits.
  ///
  /// Currently only supported on SQLite. Calling this method on PostgreSQL
  /// throws an [UnsupportedError].
  ///
  /// ```dart
  /// var subscription = Persons.db.watch(
  ///   session,
  ///   where: (t) => t.lastName.equals('Jones'),
  ///   orderBy: (t) => t.firstName,
  ///   limit: 100,
  /// ).listen((persons) {
  ///   // Handle the latest matching rows.
  /// });
  /// ```
  _ida.Stream<List<Attachment>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<AttachmentTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<AttachmentTable>? orderBy,
    _is.OrderByListBuilder<AttachmentTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<Attachment>(
      where: where?.call(Attachment.t),
      orderBy: orderBy?.call(Attachment.t),
      orderByList: orderByList?.call(Attachment.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [Attachment] matching the given query parameters.
  ///
  /// Use [where] to specify which items to include in the return value.
  /// If none is specified, all items will be returned.
  ///
  /// To specify the order use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// [offset] defines how many items to skip, after which the next one will be picked.
  ///
  /// ```dart
  /// var youngestPerson = await Persons.db.findFirstRow(
  ///   session,
  ///   where: (t) => t.lastName.equals('Jones'),
  ///   orderBy: (t) => t.age,
  /// );
  /// ```
  Future<Attachment?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<AttachmentTable>? where,
    int? offset,
    _is.OrderByBuilder<AttachmentTable>? orderBy,
    _is.OrderByListBuilder<AttachmentTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<Attachment>(
      where: where?.call(Attachment.t),
      orderBy: orderBy?.call(Attachment.t),
      orderByList: orderByList?.call(Attachment.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [Attachment] by its [id] or null if no such row exists.
  Future<Attachment?> findById(
    _is.DatabaseSession session,
    _is.UuidValue id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<Attachment>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [Attachment]s in the list and returns the inserted rows.
  ///
  /// The returned [Attachment]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// insert, none of the rows will be inserted.
  ///
  /// If [ignoreConflicts] is set to `true`, rows that conflict with existing
  /// rows are silently skipped, and only the successfully inserted rows are
  /// returned.
  ///
  /// If [noReturn] is set to `true`, the inserted rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Attachment>> insert(
    _is.DatabaseSession session,
    List<Attachment> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<Attachment>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [Attachment] and returns the inserted row.
  ///
  /// The returned [Attachment] will have its `id` field set.
  Future<Attachment> insertRow(
    _is.DatabaseSession session,
    Attachment row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<Attachment>(row, transaction: transaction);
  }

  /// Upserts all [Attachment]s in the list and returns the resulting rows.
  ///
  /// If a row conflicts on the given [conflictColumns], the existing row is
  /// updated with the new values. Otherwise, a new row is inserted.
  ///
  /// If [updateColumns] is provided, only those columns will be updated on
  /// conflict. If null, all non-conflict, non-id columns are updated.
  ///
  /// If [updateWhere] is provided, the update only applies to rows matching the
  /// given expression. Conflicting rows that don't match are skipped and not
  /// returned, so the resulting list may be shorter than [rows].
  ///
  /// The returned [Attachment]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Attachment>> upsert(
    _is.DatabaseSession session,
    List<Attachment> rows, {
    required _is.ColumnSelections<AttachmentTable> conflictColumns,
    _is.ColumnSelections<AttachmentTable>? updateColumns,
    _is.WhereExpressionBuilder<AttachmentTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<Attachment>(
      rows,
      conflictColumns: conflictColumns(Attachment.t),
      updateColumns: updateColumns?.call(Attachment.t),
      updateWhere: updateWhere?.call(Attachment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [Attachment] and returns the resulting row.
  ///
  /// If the row conflicts on the given [conflictColumns], the existing row is
  /// updated. Otherwise, a new row is inserted.
  ///
  /// If [updateColumns] is provided, only those columns will be updated on
  /// conflict. If null, all non-conflict, non-id columns are updated.
  ///
  /// If [updateWhere] is provided, the update only applies when the existing
  /// row matches the expression. Returns `null` if no row was affected — for
  /// example when [updateWhere] does not match the conflicting row.
  ///
  /// The returned [Attachment] will have its `id` field set.
  Future<Attachment?> upsertRow(
    _is.DatabaseSession session,
    Attachment row, {
    required _is.ColumnSelections<AttachmentTable> conflictColumns,
    _is.ColumnSelections<AttachmentTable>? updateColumns,
    _is.WhereExpressionBuilder<AttachmentTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<Attachment>(
      row,
      conflictColumns: conflictColumns(Attachment.t),
      updateColumns: updateColumns?.call(Attachment.t),
      updateWhere: updateWhere?.call(Attachment.t),
      transaction: transaction,
    );
  }

  /// Updates all [Attachment]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Attachment>> update(
    _is.DatabaseSession session,
    List<Attachment> rows, {
    _is.ColumnSelections<AttachmentTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<Attachment>(
      rows,
      columns: columns?.call(Attachment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [Attachment]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<Attachment> updateRow(
    _is.DatabaseSession session,
    Attachment row, {
    _is.ColumnSelections<AttachmentTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<Attachment>(
      row,
      columns: columns?.call(Attachment.t),
      transaction: transaction,
    );
  }

  /// Updates a single [Attachment] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<Attachment?> updateById(
    _is.DatabaseSession session,
    _is.UuidValue id, {
    required _is.ColumnValueListBuilder<AttachmentUpdateTable> columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<Attachment>(
      id,
      columnValues: columnValues(Attachment.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [Attachment]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Attachment>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<AttachmentUpdateTable> columnValues,
    required _is.WhereExpressionBuilder<AttachmentTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<AttachmentTable>? orderBy,
    _is.OrderByListBuilder<AttachmentTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<Attachment>(
      columnValues: columnValues(Attachment.t.updateTable),
      where: where(Attachment.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Attachment.t),
      orderByList: orderByList?.call(Attachment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [Attachment]s in the list and returns the deleted rows.
  ///
  /// To specify the order of the returned rows use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// This is an atomic operation, meaning that if one of the rows fail to
  /// be deleted, none of the rows will be deleted.
  ///
  /// If [noReturn] is set to `true`, the deleted rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Attachment>> delete(
    _is.DatabaseSession session,
    List<Attachment> rows, {
    _is.OrderByBuilder<AttachmentTable>? orderBy,
    _is.OrderByListBuilder<AttachmentTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<Attachment>(
      rows,
      orderBy: orderBy?.call(Attachment.t),
      orderByList: orderByList?.call(Attachment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [Attachment].
  Future<Attachment> deleteRow(
    _is.DatabaseSession session,
    Attachment row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<Attachment>(row, transaction: transaction);
  }

  /// Deletes all rows matching the [where] expression.
  ///
  /// To specify the order of the returned rows use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// If [noReturn] is set to `true`, the deleted rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Attachment>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<AttachmentTable> where,
    _is.OrderByBuilder<AttachmentTable>? orderBy,
    _is.OrderByListBuilder<AttachmentTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<Attachment>(
      where: where(Attachment.t),
      orderBy: orderBy?.call(Attachment.t),
      orderByList: orderByList?.call(Attachment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<AttachmentTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<Attachment>(
      where: where?.call(Attachment.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [Attachment] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<AttachmentTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<Attachment>(
      where: where(Attachment.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
