/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters
// ignore_for_file: invalid_use_of_internal_member
// ignore_for_file: dead_code, unnecessary_null_comparison

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'dart:async' as _ida;
import 'package:offline_sync_watch_test_client/src/protocol/protocol.dart'
    as _ighle6sp;
import 'package:serverpod_client/serverpod_client.dart' as _isc;
import 'package:serverpod_database/serverpod_database.dart' as _isd;
import 'note.dart' as _io8vvye9;

abstract class Folder
    implements _isd.TableRow<_isc.UuidValue?>, _isc.ProtocolSerialization {
  Folder._({this.id, this.spaceId, required this.name, this.notes});

  factory Folder({
    _isc.UuidValue? id,
    int? spaceId,
    required String name,
    List<_io8vvye9.Note>? notes,
  }) = _FolderImpl;

  factory Folder.fromJson(Map<String, dynamic> jsonSerialization) {
    return Folder(
      id: jsonSerialization['id'] == null
          ? null
          : _isc.UuidValueJsonExtension.fromJson(jsonSerialization['id']),
      spaceId: jsonSerialization['spaceId'] as int?,
      name: jsonSerialization['name'] as String,
      notes: jsonSerialization['notes'] == null
          ? null
          : _ighle6sp.Protocol().deserialize<List<_io8vvye9.Note>>(
              jsonSerialization['notes'],
            ),
    );
  }

  static final t = FolderTable();

  static const db = FolderRepository._();

  @override
  _isc.UuidValue? id;

  /// The space owning this row. Maintained by the sync engine.
  int? spaceId;

  String name;

  List<_io8vvye9.Note>? notes;

  @override
  _isd.Table<_isc.UuidValue?> get table => t;

  /// Returns a shallow copy of this [Folder]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  Folder copyWith({
    _isc.UuidValue? id,
    int? spaceId,
    String? name,
    List<_io8vvye9.Note>? notes,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'Folder',
      if (id != null) 'id': id?.toJson(),
      if (spaceId != null) 'spaceId': spaceId,
      'name': name,
      if (notes != null) 'notes': notes?.toJson(valueToJson: (v) => v.toJson()),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'Folder',
      if (id != null) 'id': id?.toJson(),
      if (spaceId != null) 'spaceId': spaceId,
      'name': name,
      if (notes != null)
        'notes': notes?.toJson(valueToJson: (v) => v.toJsonForProtocol()),
    };
  }

  static FolderInclude include({_io8vvye9.NoteIncludeList? notes}) {
    return FolderInclude._(notes: notes);
  }

  static FolderIncludeList includeList({
    _isd.WhereExpressionBuilder<FolderTable>? where,
    int? limit,
    int? offset,
    _isd.OrderByBuilder<FolderTable>? orderBy,
    _isd.OrderByListBuilder<FolderTable>? orderByList,
    FolderInclude? include,
  }) {
    return FolderIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Folder.t),
      orderByList: orderByList?.call(Folder.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _FolderImpl extends Folder {
  _FolderImpl({
    _isc.UuidValue? id,
    int? spaceId,
    required String name,
    List<_io8vvye9.Note>? notes,
  }) : super._(id: id, spaceId: spaceId, name: name, notes: notes);

  /// Returns a shallow copy of this [Folder]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
  @override
  Folder copyWith({
    Object? id = _Undefined,
    Object? spaceId = _Undefined,
    String? name,
    Object? notes = _Undefined,
  }) {
    return Folder(
      id: id is _isc.UuidValue? ? id : this.id,
      spaceId: spaceId is int? ? spaceId : this.spaceId,
      name: name ?? this.name,
      notes: notes is List<_io8vvye9.Note>?
          ? notes
          : this.notes?.map((e0) => e0.copyWith()).toList(),
    );
  }
}

class FolderUpdateTable extends _isd.UpdateTable<FolderTable> {
  FolderUpdateTable(super.table);

  _isd.ColumnValue<int, int> spaceId(int? value) =>
      _isd.ColumnValue(table.spaceId, value);

  _isd.ColumnValue<String, String> name(String value) =>
      _isd.ColumnValue(table.name, value);
}

class FolderTable extends _isd.Table<_isc.UuidValue?> {
  FolderTable({super.tableRelation}) : super(tableName: 'folder') {
    updateTable = FolderUpdateTable(this);
    spaceId = _isd.ColumnInt('spaceId', this);
    name = _isd.ColumnString('name', this);
  }

  late final FolderUpdateTable updateTable;

  /// The space owning this row. Maintained by the sync engine.
  late final _isd.ColumnInt spaceId;

  late final _isd.ColumnString name;

  _io8vvye9.NoteTable? ___notes;

  _isd.ManyRelation<_io8vvye9.NoteTable>? _notes;

  _io8vvye9.NoteTable get __notes {
    if (___notes != null) return ___notes!;
    ___notes = _isd.createRelationTable(
      relationFieldName: '__notes',
      field: Folder.t.id,
      foreignField: _io8vvye9.Note.t.folderId,
      tableRelation: tableRelation,
      createTable: (foreignTableRelation) =>
          _io8vvye9.NoteTable(tableRelation: foreignTableRelation),
    );
    return ___notes!;
  }

  _isd.ManyRelation<_io8vvye9.NoteTable> get notes {
    if (_notes != null) return _notes!;
    var relationTable = _isd.createRelationTable(
      relationFieldName: 'notes',
      field: Folder.t.id,
      foreignField: _io8vvye9.Note.t.folderId,
      tableRelation: tableRelation,
      createTable: (foreignTableRelation) =>
          _io8vvye9.NoteTable(tableRelation: foreignTableRelation),
    );
    _notes = _isd.ManyRelation<_io8vvye9.NoteTable>(
      tableWithRelations: relationTable,
      table: _io8vvye9.NoteTable(
        tableRelation: relationTable.tableRelation!.lastRelation,
      ),
    );
    return _notes!;
  }

  @override
  List<_isd.Column> get columns => [id, spaceId, name];

  @override
  _isd.Table? getRelationTable(String relationField) {
    if (relationField == 'notes') {
      return __notes;
    }
    return null;
  }
}

class FolderInclude extends _isd.IncludeObject {
  FolderInclude._({_io8vvye9.NoteIncludeList? notes}) {
    _notes = notes;
  }

  _io8vvye9.NoteIncludeList? _notes;

  @override
  Map<String, _isd.Include?> get includes => {'notes': _notes};

  @override
  _isd.Table<_isc.UuidValue?> get table => Folder.t;
}

class FolderIncludeList extends _isd.IncludeList {
  FolderIncludeList._({
    _isd.WhereExpressionBuilder<FolderTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(Folder.t);
  }

  @override
  Map<String, _isd.Include?> get includes => include?.includes ?? {};

  @override
  _isd.Table<_isc.UuidValue?> get table => Folder.t;
}

class FolderRepository {
  const FolderRepository._();

  final attach = const FolderAttachRepository._();

  final attachRow = const FolderAttachRowRepository._();

  final detach = const FolderDetachRepository._();

  final detachRow = const FolderDetachRowRepository._();

  /// Returns a list of [Folder]s matching the given query parameters.
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
  Future<List<Folder>> find(
    _isd.DatabaseSession session, {
    _isd.WhereExpressionBuilder<FolderTable>? where,
    int? limit,
    int? offset,
    _isd.OrderByBuilder<FolderTable>? orderBy,
    _isd.OrderByListBuilder<FolderTable>? orderByList,
    _isd.Transaction? transaction,
    FolderInclude? include,
    _isd.LockMode? lockMode,
    _isd.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<Folder>(
      where: where?.call(Folder.t),
      orderBy: orderBy?.call(Folder.t),
      orderByList: orderByList?.call(Folder.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [Folder]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `Folder.t`.
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
  _ida.Stream<List<Folder>> watch(
    _isd.DatabaseSession session, {
    _isd.WhereExpressionBuilder<FolderTable>? where,
    int? limit,
    int? offset,
    _isd.OrderByBuilder<FolderTable>? orderBy,
    _isd.OrderByListBuilder<FolderTable>? orderByList,
    FolderInclude? include,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_isd.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<Folder>(
      where: where?.call(Folder.t),
      orderBy: orderBy?.call(Folder.t),
      orderByList: orderByList?.call(Folder.t),
      limit: limit,
      offset: offset,
      include: include,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [Folder] matching the given query parameters.
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
  Future<Folder?> findFirstRow(
    _isd.DatabaseSession session, {
    _isd.WhereExpressionBuilder<FolderTable>? where,
    int? offset,
    _isd.OrderByBuilder<FolderTable>? orderBy,
    _isd.OrderByListBuilder<FolderTable>? orderByList,
    _isd.Transaction? transaction,
    FolderInclude? include,
    _isd.LockMode? lockMode,
    _isd.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<Folder>(
      where: where?.call(Folder.t),
      orderBy: orderBy?.call(Folder.t),
      orderByList: orderByList?.call(Folder.t),
      offset: offset,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [Folder] by its [id] or null if no such row exists.
  Future<Folder?> findById(
    _isd.DatabaseSession session,
    _isc.UuidValue id, {
    _isd.Transaction? transaction,
    FolderInclude? include,
    _isd.LockMode? lockMode,
    _isd.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<Folder>(
      id,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [Folder]s in the list and returns the inserted rows.
  ///
  /// The returned [Folder]s will have their `id` fields set.
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
  Future<List<Folder>> insert(
    _isd.DatabaseSession session,
    List<Folder> rows, {
    _isd.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<Folder>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [Folder] and returns the inserted row.
  ///
  /// The returned [Folder] will have its `id` field set.
  Future<Folder> insertRow(
    _isd.DatabaseSession session,
    Folder row, {
    _isd.Transaction? transaction,
  }) async {
    return session.db.insertRow<Folder>(row, transaction: transaction);
  }

  /// Upserts all [Folder]s in the list and returns the resulting rows.
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
  /// The returned [Folder]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Folder>> upsert(
    _isd.DatabaseSession session,
    List<Folder> rows, {
    required _isd.ColumnSelections<FolderTable> conflictColumns,
    _isd.ColumnSelections<FolderTable>? updateColumns,
    _isd.WhereExpressionBuilder<FolderTable>? updateWhere,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<Folder>(
      rows,
      conflictColumns: conflictColumns(Folder.t),
      updateColumns: updateColumns?.call(Folder.t),
      updateWhere: updateWhere?.call(Folder.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [Folder] and returns the resulting row.
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
  /// The returned [Folder] will have its `id` field set.
  Future<Folder?> upsertRow(
    _isd.DatabaseSession session,
    Folder row, {
    required _isd.ColumnSelections<FolderTable> conflictColumns,
    _isd.ColumnSelections<FolderTable>? updateColumns,
    _isd.WhereExpressionBuilder<FolderTable>? updateWhere,
    _isd.Transaction? transaction,
  }) async {
    return session.db.upsertRow<Folder>(
      row,
      conflictColumns: conflictColumns(Folder.t),
      updateColumns: updateColumns?.call(Folder.t),
      updateWhere: updateWhere?.call(Folder.t),
      transaction: transaction,
    );
  }

  /// Updates all [Folder]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Folder>> update(
    _isd.DatabaseSession session,
    List<Folder> rows, {
    _isd.ColumnSelections<FolderTable>? columns,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<Folder>(
      rows,
      columns: columns?.call(Folder.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [Folder]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<Folder> updateRow(
    _isd.DatabaseSession session,
    Folder row, {
    _isd.ColumnSelections<FolderTable>? columns,
    _isd.Transaction? transaction,
  }) async {
    return session.db.updateRow<Folder>(
      row,
      columns: columns?.call(Folder.t),
      transaction: transaction,
    );
  }

  /// Updates a single [Folder] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<Folder?> updateById(
    _isd.DatabaseSession session,
    _isc.UuidValue id, {
    required _isd.ColumnValueListBuilder<FolderUpdateTable> columnValues,
    _isd.Transaction? transaction,
  }) async {
    return session.db.updateById<Folder>(
      id,
      columnValues: columnValues(Folder.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [Folder]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Folder>> updateWhere(
    _isd.DatabaseSession session, {
    required _isd.ColumnValueListBuilder<FolderUpdateTable> columnValues,
    required _isd.WhereExpressionBuilder<FolderTable> where,
    int? limit,
    int? offset,
    _isd.OrderByBuilder<FolderTable>? orderBy,
    _isd.OrderByListBuilder<FolderTable>? orderByList,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<Folder>(
      columnValues: columnValues(Folder.t.updateTable),
      where: where(Folder.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Folder.t),
      orderByList: orderByList?.call(Folder.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [Folder]s in the list and returns the deleted rows.
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
  Future<List<Folder>> delete(
    _isd.DatabaseSession session,
    List<Folder> rows, {
    _isd.OrderByBuilder<FolderTable>? orderBy,
    _isd.OrderByListBuilder<FolderTable>? orderByList,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<Folder>(
      rows,
      orderBy: orderBy?.call(Folder.t),
      orderByList: orderByList?.call(Folder.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [Folder].
  Future<Folder> deleteRow(
    _isd.DatabaseSession session,
    Folder row, {
    _isd.Transaction? transaction,
  }) async {
    return session.db.deleteRow<Folder>(row, transaction: transaction);
  }

  /// Deletes all rows matching the [where] expression.
  ///
  /// To specify the order of the returned rows use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// If [noReturn] is set to `true`, the deleted rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Folder>> deleteWhere(
    _isd.DatabaseSession session, {
    required _isd.WhereExpressionBuilder<FolderTable> where,
    _isd.OrderByBuilder<FolderTable>? orderBy,
    _isd.OrderByListBuilder<FolderTable>? orderByList,
    _isd.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<Folder>(
      where: where(Folder.t),
      orderBy: orderBy?.call(Folder.t),
      orderByList: orderByList?.call(Folder.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _isd.DatabaseSession session, {
    _isd.WhereExpressionBuilder<FolderTable>? where,
    int? limit,
    _isd.Transaction? transaction,
  }) async {
    return session.db.count<Folder>(
      where: where?.call(Folder.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [Folder] rows matching the [where] expression.
  Future<void> lockRows(
    _isd.DatabaseSession session, {
    required _isd.WhereExpressionBuilder<FolderTable> where,
    required _isd.LockMode lockMode,
    required _isd.Transaction transaction,
    _isd.LockBehavior lockBehavior = _isd.LockBehavior.wait,
  }) async {
    return session.db.lockRows<Folder>(
      where: where(Folder.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}

class FolderAttachRepository {
  const FolderAttachRepository._();

  /// Creates a relation between this [Folder] and the given [Note]s
  /// by setting each [Note]'s foreign key `folderId` to refer to this [Folder].
  Future<void> notes(
    _isd.DatabaseSession session,
    Folder folder,
    List<_io8vvye9.Note> note, {
    _isd.Transaction? transaction,
  }) async {
    if (note.any((e) => e.id == null)) {
      throw ArgumentError.notNull('note.id');
    }
    if (folder.id == null) {
      throw ArgumentError.notNull('folder.id');
    }

    var $note = note.map((e) => e.copyWith(folderId: folder.id)).toList();
    await session.db.update<_io8vvye9.Note>(
      $note,
      columns: [_io8vvye9.Note.t.folderId],
      transaction: transaction,
    );
  }
}

class FolderAttachRowRepository {
  const FolderAttachRowRepository._();

  /// Creates a relation between this [Folder] and the given [Note]
  /// by setting the [Note]'s foreign key `folderId` to refer to this [Folder].
  Future<void> notes(
    _isd.DatabaseSession session,
    Folder folder,
    _io8vvye9.Note note, {
    _isd.Transaction? transaction,
  }) async {
    if (note.id == null) {
      throw ArgumentError.notNull('note.id');
    }
    if (folder.id == null) {
      throw ArgumentError.notNull('folder.id');
    }

    var $note = note.copyWith(folderId: folder.id);
    await session.db.updateRow<_io8vvye9.Note>(
      $note,
      columns: [_io8vvye9.Note.t.folderId],
      transaction: transaction,
    );
  }
}

class FolderDetachRepository {
  const FolderDetachRepository._();

  /// Detaches the relation between this [Folder] and the given [Note]
  /// by setting the [Note]'s foreign key `folderId` to `null`.
  ///
  /// This removes the association between the two models without deleting
  /// the related record.
  Future<void> notes(
    _isd.DatabaseSession session,
    List<_io8vvye9.Note> note, {
    _isd.Transaction? transaction,
  }) async {
    if (note.any((e) => e.id == null)) {
      throw ArgumentError.notNull('note.id');
    }

    var $note = note.map((e) => e.copyWith(folderId: null)).toList();
    await session.db.update<_io8vvye9.Note>(
      $note,
      columns: [_io8vvye9.Note.t.folderId],
      transaction: transaction,
    );
  }
}

class FolderDetachRowRepository {
  const FolderDetachRowRepository._();

  /// Detaches the relation between this [Folder] and the given [Note]
  /// by setting the [Note]'s foreign key `folderId` to `null`.
  ///
  /// This removes the association between the two models without deleting
  /// the related record.
  Future<void> notes(
    _isd.DatabaseSession session,
    _io8vvye9.Note note, {
    _isd.Transaction? transaction,
  }) async {
    if (note.id == null) {
      throw ArgumentError.notNull('note.id');
    }

    var $note = note.copyWith(folderId: null);
    await session.db.updateRow<_io8vvye9.Note>(
      $note,
      columns: [_io8vvye9.Note.t.folderId],
      transaction: transaction,
    );
  }
}
