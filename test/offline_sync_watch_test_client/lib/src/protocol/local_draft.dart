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
import 'package:serverpod_client/serverpod_client.dart' as _isc;
import 'package:serverpod_database/serverpod_database.dart' as _isd;

abstract class LocalDraft
    implements _isd.TableRow<int?>, _isc.ProtocolSerialization {
  LocalDraft._({this.id, required this.body});

  factory LocalDraft({int? id, required String body}) = _LocalDraftImpl;

  factory LocalDraft.fromJson(Map<String, dynamic> jsonSerialization) {
    return LocalDraft(
      id: jsonSerialization['id'] as int?,
      body: jsonSerialization['body'] as String,
    );
  }

  static final t = LocalDraftTable();

  static const db = LocalDraftRepository._();

  @override
  int? id;

  String body;

  @override
  _isd.Table<int?> get table => t;

  /// Returns a shallow copy of this [LocalDraft]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
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

  static LocalDraftInclude include() {
    return LocalDraftInclude._();
  }

  static LocalDraftIncludeList includeList({
    _isd.WhereExpressionBuilder<LocalDraftTable>? where,
    int? limit,
    int? offset,
    _isd.OrderByBuilder<LocalDraftTable>? orderBy,
    _isd.OrderByListBuilder<LocalDraftTable>? orderByList,
    LocalDraftInclude? include,
  }) {
    return LocalDraftIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(LocalDraft.t),
      orderByList: orderByList?.call(LocalDraft.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _LocalDraftImpl extends LocalDraft {
  _LocalDraftImpl({int? id, required String body})
    : super._(id: id, body: body);

  /// Returns a shallow copy of this [LocalDraft]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  LocalDraft copyWith({Object? id = _Undefined, String? body}) {
    return LocalDraft(id: id is int? ? id : this.id, body: body ?? this.body);
  }
}

class LocalDraftUpdateTable extends _isd.UpdateTable<LocalDraftTable> {
  LocalDraftUpdateTable(super.table);

  _isd.ColumnValue<String, String> body(String value) =>
      _isd.ColumnValue(table.body, value);
}

class LocalDraftTable extends _isd.Table<int?> {
  LocalDraftTable({super.tableRelation}) : super(tableName: 'local_draft') {
    updateTable = LocalDraftUpdateTable(this);
    body = _isd.ColumnString('body', this);
  }

  late final LocalDraftUpdateTable updateTable;

  late final _isd.ColumnString body;

  @override
  List<_isd.Column> get columns => [id, body];
}

class LocalDraftInclude extends _isd.IncludeObject {
  LocalDraftInclude._();

  @override
  Map<String, _isd.Include?> get includes => {};

  @override
  _isd.Table<int?> get table => LocalDraft.t;
}

class LocalDraftIncludeList extends _isd.IncludeList {
  LocalDraftIncludeList._({
    _isd.WhereExpressionBuilder<LocalDraftTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(LocalDraft.t);
  }

  @override
  Map<String, _isd.Include?> get includes => include?.includes ?? {};

  @override
  _isd.Table<int?> get table => LocalDraft.t;
}

class LocalDraftRepository {
  const LocalDraftRepository._();

  /// Returns a list of [LocalDraft]s matching the given query parameters.
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
  Future<List<LocalDraft>> find(
    _isd.DatabaseSession session, {
    _isd.WhereExpressionBuilder<LocalDraftTable>? where,
    int? limit,
    int? offset,
    _isd.OrderByBuilder<LocalDraftTable>? orderBy,
    _isd.OrderByListBuilder<LocalDraftTable>? orderByList,
    _isd.Transaction? transaction,
    _isd.LockMode? lockMode,
    _isd.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<LocalDraft>(
      where: where?.call(LocalDraft.t),
      orderBy: orderBy?.call(LocalDraft.t),
      orderByList: orderByList?.call(LocalDraft.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [LocalDraft]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `LocalDraft.t`.
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
  _ida.Stream<List<LocalDraft>> watch(
    _isd.DatabaseSession session, {
    _isd.WhereExpressionBuilder<LocalDraftTable>? where,
    int? limit,
    int? offset,
    _isd.OrderByBuilder<LocalDraftTable>? orderBy,
    _isd.OrderByListBuilder<LocalDraftTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_isd.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<LocalDraft>(
      where: where?.call(LocalDraft.t),
      orderBy: orderBy?.call(LocalDraft.t),
      orderByList: orderByList?.call(LocalDraft.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [LocalDraft] matching the given query parameters.
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
  Future<LocalDraft?> findFirstRow(
    _isd.DatabaseSession session, {
    _isd.WhereExpressionBuilder<LocalDraftTable>? where,
    int? offset,
    _isd.OrderByBuilder<LocalDraftTable>? orderBy,
    _isd.OrderByListBuilder<LocalDraftTable>? orderByList,
    _isd.Transaction? transaction,
    _isd.LockMode? lockMode,
    _isd.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<LocalDraft>(
      where: where?.call(LocalDraft.t),
      orderBy: orderBy?.call(LocalDraft.t),
      orderByList: orderByList?.call(LocalDraft.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [LocalDraft] by its [id] or null if no such row exists.
  Future<LocalDraft?> findById(
    _isd.DatabaseSession session,
    int id, {
    _isd.Transaction? transaction,
    _isd.LockMode? lockMode,
    _isd.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<LocalDraft>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [LocalDraft]s in the list and returns the inserted rows.
  ///
  /// The returned [LocalDraft]s will have their `id` fields set.
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
  Future<List<LocalDraft>> insert(
    _isd.DatabaseSession session,
    List<LocalDraft> rows, {
    _isd.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<LocalDraft>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [LocalDraft] and returns the inserted row.
  ///
  /// The returned [LocalDraft] will have its `id` field set.
  Future<LocalDraft> insertRow(
    _isd.DatabaseSession session,
    LocalDraft row, {
    _isd.Transaction? transaction,
  }) async {
    return session.db.insertRow<LocalDraft>(row, transaction: transaction);
  }

  /// Upserts all [LocalDraft]s in the list and returns the resulting rows.
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
  /// The returned [LocalDraft]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<LocalDraft>> upsert(
    _isd.DatabaseSession session,
    List<LocalDraft> rows, {
    required _isd.ColumnSelections<LocalDraftTable> conflictColumns,
    _isd.ColumnSelections<LocalDraftTable>? updateColumns,
    _isd.WhereExpressionBuilder<LocalDraftTable>? updateWhere,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<LocalDraft>(
      rows,
      conflictColumns: conflictColumns(LocalDraft.t),
      updateColumns: updateColumns?.call(LocalDraft.t),
      updateWhere: updateWhere?.call(LocalDraft.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [LocalDraft] and returns the resulting row.
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
  /// The returned [LocalDraft] will have its `id` field set.
  Future<LocalDraft?> upsertRow(
    _isd.DatabaseSession session,
    LocalDraft row, {
    required _isd.ColumnSelections<LocalDraftTable> conflictColumns,
    _isd.ColumnSelections<LocalDraftTable>? updateColumns,
    _isd.WhereExpressionBuilder<LocalDraftTable>? updateWhere,
    _isd.Transaction? transaction,
  }) async {
    return session.db.upsertRow<LocalDraft>(
      row,
      conflictColumns: conflictColumns(LocalDraft.t),
      updateColumns: updateColumns?.call(LocalDraft.t),
      updateWhere: updateWhere?.call(LocalDraft.t),
      transaction: transaction,
    );
  }

  /// Updates all [LocalDraft]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<LocalDraft>> update(
    _isd.DatabaseSession session,
    List<LocalDraft> rows, {
    _isd.ColumnSelections<LocalDraftTable>? columns,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<LocalDraft>(
      rows,
      columns: columns?.call(LocalDraft.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [LocalDraft]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<LocalDraft> updateRow(
    _isd.DatabaseSession session,
    LocalDraft row, {
    _isd.ColumnSelections<LocalDraftTable>? columns,
    _isd.Transaction? transaction,
  }) async {
    return session.db.updateRow<LocalDraft>(
      row,
      columns: columns?.call(LocalDraft.t),
      transaction: transaction,
    );
  }

  /// Updates a single [LocalDraft] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<LocalDraft?> updateById(
    _isd.DatabaseSession session,
    int id, {
    required _isd.ColumnValueListBuilder<LocalDraftUpdateTable> columnValues,
    _isd.Transaction? transaction,
  }) async {
    return session.db.updateById<LocalDraft>(
      id,
      columnValues: columnValues(LocalDraft.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [LocalDraft]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<LocalDraft>> updateWhere(
    _isd.DatabaseSession session, {
    required _isd.ColumnValueListBuilder<LocalDraftUpdateTable> columnValues,
    required _isd.WhereExpressionBuilder<LocalDraftTable> where,
    int? limit,
    int? offset,
    _isd.OrderByBuilder<LocalDraftTable>? orderBy,
    _isd.OrderByListBuilder<LocalDraftTable>? orderByList,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<LocalDraft>(
      columnValues: columnValues(LocalDraft.t.updateTable),
      where: where(LocalDraft.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(LocalDraft.t),
      orderByList: orderByList?.call(LocalDraft.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [LocalDraft]s in the list and returns the deleted rows.
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
  Future<List<LocalDraft>> delete(
    _isd.DatabaseSession session,
    List<LocalDraft> rows, {
    _isd.OrderByBuilder<LocalDraftTable>? orderBy,
    _isd.OrderByListBuilder<LocalDraftTable>? orderByList,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<LocalDraft>(
      rows,
      orderBy: orderBy?.call(LocalDraft.t),
      orderByList: orderByList?.call(LocalDraft.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [LocalDraft].
  Future<LocalDraft> deleteRow(
    _isd.DatabaseSession session,
    LocalDraft row, {
    _isd.Transaction? transaction,
  }) async {
    return session.db.deleteRow<LocalDraft>(row, transaction: transaction);
  }

  /// Deletes all rows matching the [where] expression.
  ///
  /// To specify the order of the returned rows use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// If [noReturn] is set to `true`, the deleted rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<LocalDraft>> deleteWhere(
    _isd.DatabaseSession session, {
    required _isd.WhereExpressionBuilder<LocalDraftTable> where,
    _isd.OrderByBuilder<LocalDraftTable>? orderBy,
    _isd.OrderByListBuilder<LocalDraftTable>? orderByList,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<LocalDraft>(
      where: where(LocalDraft.t),
      orderBy: orderBy?.call(LocalDraft.t),
      orderByList: orderByList?.call(LocalDraft.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _isd.DatabaseSession session, {
    _isd.WhereExpressionBuilder<LocalDraftTable>? where,
    int? limit,
    _isd.Transaction? transaction,
  }) async {
    return session.db.count<LocalDraft>(
      where: where?.call(LocalDraft.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [LocalDraft] rows matching the [where] expression.
  Future<void> lockRows(
    _isd.DatabaseSession session, {
    required _isd.WhereExpressionBuilder<LocalDraftTable> where,
    required _isd.LockMode lockMode,
    required _isd.Transaction transaction,
    _isd.LockBehavior lockBehavior = _isd.LockBehavior.wait,
  }) async {
    return session.db.lockRows<LocalDraft>(
      where: where(LocalDraft.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
