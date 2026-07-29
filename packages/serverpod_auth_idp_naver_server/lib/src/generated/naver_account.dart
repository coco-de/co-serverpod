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
import 'package:serverpod/serverpod.dart' as _i1;
import 'package:serverpod_auth_core_server/serverpod_auth_core_server.dart'
    as _i2;
import 'package:serverpod_auth_idp_naver_server/src/generated/protocol.dart'
    as _i3;

/// A fully configured Naver account to be used for logins.
abstract class NaverAccount
    implements _i1.TableRow<_i1.UuidValue?>, _i1.ProtocolSerialization {
  NaverAccount._({
    this.id,
    required this.authUserId,
    this.authUser,
    required this.userIdentifier,
    this.email,
    DateTime? created,
  }) : created = created ?? DateTime.now();

  factory NaverAccount({
    _i1.UuidValue? id,
    required _i1.UuidValue authUserId,
    _i2.AuthUser? authUser,
    required String userIdentifier,
    String? email,
    DateTime? created,
  }) = _NaverAccountImpl;

  factory NaverAccount.fromJson(Map<String, dynamic> jsonSerialization) {
    return NaverAccount(
      id: jsonSerialization['id'] == null
          ? null
          : _i1.UuidValueJsonExtension.fromJson(jsonSerialization['id']),
      authUserId: _i1.UuidValueJsonExtension.fromJson(
        jsonSerialization['authUserId'],
      ),
      authUser: jsonSerialization['authUser'] == null
          ? null
          : _i3.Protocol().deserialize<_i2.AuthUser>(
              jsonSerialization['authUser'],
            ),
      userIdentifier: jsonSerialization['userIdentifier'] as String,
      email: jsonSerialization['email'] as String?,
      created: jsonSerialization['created'] == null
          ? null
          : _i1.DateTimeJsonExtension.fromJson(jsonSerialization['created']),
    );
  }

  static final t = NaverAccountTable();

  static const db = NaverAccountRepository._();

  @override
  _i1.UuidValue? id;

  _i1.UuidValue authUserId;

  /// The [AuthUser] this profile belongs to
  _i2.AuthUser? authUser;

  /// The user identifier given by Naver for this account.
  String userIdentifier;

  /// The verified email of the user, as received from Naver.
  ///
  /// Logins all work through the [userIdentifier], but the email is retained
  /// for consolidation look-ups.
  ///
  /// Stored in lower-case.
  ///
  /// This may be null if the user did not consent to share their email.
  String? email;

  /// The time when this authentication was created.
  DateTime created;

  @override
  _i1.Table<_i1.UuidValue?> get table => t;

  /// Returns a shallow copy of this [NaverAccount]
  /// with some or all fields replaced by the given arguments.
  @_i1.useResult
  NaverAccount copyWith({
    _i1.UuidValue? id,
    _i1.UuidValue? authUserId,
    _i2.AuthUser? authUser,
    String? userIdentifier,
    String? email,
    DateTime? created,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'serverpod_auth_idp_naver.NaverAccount',
      if (id != null) 'id': id?.toJson(),
      'authUserId': authUserId.toJson(),
      if (authUser != null) 'authUser': authUser?.toJson(),
      'userIdentifier': userIdentifier,
      if (email != null) 'email': email,
      'created': created.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static NaverAccountInclude include({_i2.AuthUserInclude? authUser}) {
    return NaverAccountInclude._(authUser: authUser);
  }

  static NaverAccountIncludeList includeList({
    _i1.WhereExpressionBuilder<NaverAccountTable>? where,
    int? limit,
    int? offset,
    _i1.OrderByBuilder<NaverAccountTable>? orderBy,
    _i1.OrderByListBuilder<NaverAccountTable>? orderByList,
    NaverAccountInclude? include,
  }) {
    return NaverAccountIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(NaverAccount.t),
      orderByList: orderByList?.call(NaverAccount.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _i1.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _NaverAccountImpl extends NaverAccount {
  _NaverAccountImpl({
    _i1.UuidValue? id,
    required _i1.UuidValue authUserId,
    _i2.AuthUser? authUser,
    required String userIdentifier,
    String? email,
    DateTime? created,
  }) : super._(
         id: id,
         authUserId: authUserId,
         authUser: authUser,
         userIdentifier: userIdentifier,
         email: email,
         created: created,
       );

  /// Returns a shallow copy of this [NaverAccount]
  /// with some or all fields replaced by the given arguments.
  @_i1.useResult
  @override
  NaverAccount copyWith({
    Object? id = _Undefined,
    _i1.UuidValue? authUserId,
    Object? authUser = _Undefined,
    String? userIdentifier,
    Object? email = _Undefined,
    DateTime? created,
  }) {
    return NaverAccount(
      id: id is _i1.UuidValue? ? id : this.id,
      authUserId: authUserId ?? this.authUserId,
      authUser: authUser is _i2.AuthUser?
          ? authUser
          : this.authUser?.copyWith(),
      userIdentifier: userIdentifier ?? this.userIdentifier,
      email: email is String? ? email : this.email,
      created: created ?? this.created,
    );
  }
}

class NaverAccountUpdateTable extends _i1.UpdateTable<NaverAccountTable> {
  NaverAccountUpdateTable(super.table);

  _i1.ColumnValue<_i1.UuidValue, _i1.UuidValue> authUserId(
    _i1.UuidValue value,
  ) => _i1.ColumnValue(
    table.authUserId,
    value,
  );

  _i1.ColumnValue<String, String> userIdentifier(String value) =>
      _i1.ColumnValue(
        table.userIdentifier,
        value,
      );

  _i1.ColumnValue<String, String> email(String? value) => _i1.ColumnValue(
    table.email,
    value,
  );

  _i1.ColumnValue<DateTime, DateTime> created(DateTime value) =>
      _i1.ColumnValue(
        table.created,
        value,
      );
}

class NaverAccountTable extends _i1.Table<_i1.UuidValue?> {
  NaverAccountTable({super.tableRelation})
    : super(tableName: 'serverpod_auth_idp_naver_account') {
    updateTable = NaverAccountUpdateTable(this);
    authUserId = _i1.ColumnUuid(
      'authUserId',
      this,
    );
    userIdentifier = _i1.ColumnString(
      'userIdentifier',
      this,
    );
    email = _i1.ColumnString(
      'email',
      this,
    );
    created = _i1.ColumnDateTime(
      'created',
      this,
    );
  }

  late final NaverAccountUpdateTable updateTable;

  late final _i1.ColumnUuid authUserId;

  /// The [AuthUser] this profile belongs to
  _i2.AuthUserTable? _authUser;

  /// The user identifier given by Naver for this account.
  late final _i1.ColumnString userIdentifier;

  /// The verified email of the user, as received from Naver.
  ///
  /// Logins all work through the [userIdentifier], but the email is retained
  /// for consolidation look-ups.
  ///
  /// Stored in lower-case.
  ///
  /// This may be null if the user did not consent to share their email.
  late final _i1.ColumnString email;

  /// The time when this authentication was created.
  late final _i1.ColumnDateTime created;

  _i2.AuthUserTable get authUser {
    if (_authUser != null) return _authUser!;
    _authUser = _i1.createRelationTable(
      relationFieldName: 'authUser',
      field: NaverAccount.t.authUserId,
      foreignField: _i2.AuthUser.t.id,
      tableRelation: tableRelation,
      createTable: (foreignTableRelation) =>
          _i2.AuthUserTable(tableRelation: foreignTableRelation),
    );
    return _authUser!;
  }

  @override
  List<_i1.Column> get columns => [
    id,
    authUserId,
    userIdentifier,
    email,
    created,
  ];

  @override
  _i1.Table? getRelationTable(String relationField) {
    if (relationField == 'authUser') {
      return authUser;
    }
    return null;
  }
}

class NaverAccountInclude extends _i1.IncludeObject {
  NaverAccountInclude._({_i2.AuthUserInclude? authUser}) {
    _authUser = authUser;
  }

  _i2.AuthUserInclude? _authUser;

  @override
  Map<String, _i1.Include?> get includes => {'authUser': _authUser};

  @override
  _i1.Table<_i1.UuidValue?> get table => NaverAccount.t;
}

class NaverAccountIncludeList extends _i1.IncludeList {
  NaverAccountIncludeList._({
    _i1.WhereExpressionBuilder<NaverAccountTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(NaverAccount.t);
  }

  @override
  Map<String, _i1.Include?> get includes => include?.includes ?? {};

  @override
  _i1.Table<_i1.UuidValue?> get table => NaverAccount.t;
}

class NaverAccountRepository {
  const NaverAccountRepository._();

  final attachRow = const NaverAccountAttachRowRepository._();

  /// Returns a list of [NaverAccount]s matching the given query parameters.
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
  Future<List<NaverAccount>> find(
    _i1.DatabaseSession session, {
    _i1.WhereExpressionBuilder<NaverAccountTable>? where,
    int? limit,
    int? offset,
    _i1.OrderByBuilder<NaverAccountTable>? orderBy,
    _i1.OrderByListBuilder<NaverAccountTable>? orderByList,
    _i1.Transaction? transaction,
    NaverAccountInclude? include,
    _i1.LockMode? lockMode,
    _i1.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<NaverAccount>(
      where: where?.call(NaverAccount.t),
      orderBy: orderBy?.call(NaverAccount.t),
      orderByList: orderByList?.call(NaverAccount.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Returns the first matching [NaverAccount] matching the given query parameters.
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
  Future<NaverAccount?> findFirstRow(
    _i1.DatabaseSession session, {
    _i1.WhereExpressionBuilder<NaverAccountTable>? where,
    int? offset,
    _i1.OrderByBuilder<NaverAccountTable>? orderBy,
    _i1.OrderByListBuilder<NaverAccountTable>? orderByList,
    _i1.Transaction? transaction,
    NaverAccountInclude? include,
    _i1.LockMode? lockMode,
    _i1.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<NaverAccount>(
      where: where?.call(NaverAccount.t),
      orderBy: orderBy?.call(NaverAccount.t),
      orderByList: orderByList?.call(NaverAccount.t),
      offset: offset,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [NaverAccount] by its [id] or null if no such row exists.
  Future<NaverAccount?> findById(
    _i1.DatabaseSession session,
    _i1.UuidValue id, {
    _i1.Transaction? transaction,
    NaverAccountInclude? include,
    _i1.LockMode? lockMode,
    _i1.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<NaverAccount>(
      id,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [NaverAccount]s in the list and returns the inserted rows.
  ///
  /// The returned [NaverAccount]s will have their `id` fields set.
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
  Future<List<NaverAccount>> insert(
    _i1.DatabaseSession session,
    List<NaverAccount> rows, {
    _i1.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<NaverAccount>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [NaverAccount] and returns the inserted row.
  ///
  /// The returned [NaverAccount] will have its `id` field set.
  Future<NaverAccount> insertRow(
    _i1.DatabaseSession session,
    NaverAccount row, {
    _i1.Transaction? transaction,
  }) async {
    return session.db.insertRow<NaverAccount>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [NaverAccount]s in the list and returns the resulting rows.
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
  /// The returned [NaverAccount]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<NaverAccount>> upsert(
    _i1.DatabaseSession session,
    List<NaverAccount> rows, {
    required _i1.ColumnSelections<NaverAccountTable> conflictColumns,
    _i1.ColumnSelections<NaverAccountTable>? updateColumns,
    _i1.WhereExpressionBuilder<NaverAccountTable>? updateWhere,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<NaverAccount>(
      rows,
      conflictColumns: conflictColumns(NaverAccount.t),
      updateColumns: updateColumns?.call(NaverAccount.t),
      updateWhere: updateWhere?.call(NaverAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [NaverAccount] and returns the resulting row.
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
  /// The returned [NaverAccount] will have its `id` field set.
  Future<NaverAccount?> upsertRow(
    _i1.DatabaseSession session,
    NaverAccount row, {
    required _i1.ColumnSelections<NaverAccountTable> conflictColumns,
    _i1.ColumnSelections<NaverAccountTable>? updateColumns,
    _i1.WhereExpressionBuilder<NaverAccountTable>? updateWhere,
    _i1.Transaction? transaction,
  }) async {
    return session.db.upsertRow<NaverAccount>(
      row,
      conflictColumns: conflictColumns(NaverAccount.t),
      updateColumns: updateColumns?.call(NaverAccount.t),
      updateWhere: updateWhere?.call(NaverAccount.t),
      transaction: transaction,
    );
  }

  /// Updates all [NaverAccount]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<NaverAccount>> update(
    _i1.DatabaseSession session,
    List<NaverAccount> rows, {
    _i1.ColumnSelections<NaverAccountTable>? columns,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<NaverAccount>(
      rows,
      columns: columns?.call(NaverAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [NaverAccount]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<NaverAccount> updateRow(
    _i1.DatabaseSession session,
    NaverAccount row, {
    _i1.ColumnSelections<NaverAccountTable>? columns,
    _i1.Transaction? transaction,
  }) async {
    return session.db.updateRow<NaverAccount>(
      row,
      columns: columns?.call(NaverAccount.t),
      transaction: transaction,
    );
  }

  /// Updates a single [NaverAccount] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<NaverAccount?> updateById(
    _i1.DatabaseSession session,
    _i1.UuidValue id, {
    required _i1.ColumnValueListBuilder<NaverAccountUpdateTable> columnValues,
    _i1.Transaction? transaction,
  }) async {
    return session.db.updateById<NaverAccount>(
      id,
      columnValues: columnValues(NaverAccount.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [NaverAccount]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<NaverAccount>> updateWhere(
    _i1.DatabaseSession session, {
    required _i1.ColumnValueListBuilder<NaverAccountUpdateTable> columnValues,
    required _i1.WhereExpressionBuilder<NaverAccountTable> where,
    int? limit,
    int? offset,
    _i1.OrderByBuilder<NaverAccountTable>? orderBy,
    _i1.OrderByListBuilder<NaverAccountTable>? orderByList,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<NaverAccount>(
      columnValues: columnValues(NaverAccount.t.updateTable),
      where: where(NaverAccount.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(NaverAccount.t),
      orderByList: orderByList?.call(NaverAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [NaverAccount]s in the list and returns the deleted rows.
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
  Future<List<NaverAccount>> delete(
    _i1.DatabaseSession session,
    List<NaverAccount> rows, {
    _i1.OrderByBuilder<NaverAccountTable>? orderBy,
    _i1.OrderByListBuilder<NaverAccountTable>? orderByList,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<NaverAccount>(
      rows,
      orderBy: orderBy?.call(NaverAccount.t),
      orderByList: orderByList?.call(NaverAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [NaverAccount].
  Future<NaverAccount> deleteRow(
    _i1.DatabaseSession session,
    NaverAccount row, {
    _i1.Transaction? transaction,
  }) async {
    return session.db.deleteRow<NaverAccount>(
      row,
      transaction: transaction,
    );
  }

  /// Deletes all rows matching the [where] expression.
  ///
  /// To specify the order of the returned rows use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// If [noReturn] is set to `true`, the deleted rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<NaverAccount>> deleteWhere(
    _i1.DatabaseSession session, {
    required _i1.WhereExpressionBuilder<NaverAccountTable> where,
    _i1.OrderByBuilder<NaverAccountTable>? orderBy,
    _i1.OrderByListBuilder<NaverAccountTable>? orderByList,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<NaverAccount>(
      where: where(NaverAccount.t),
      orderBy: orderBy?.call(NaverAccount.t),
      orderByList: orderByList?.call(NaverAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _i1.DatabaseSession session, {
    _i1.WhereExpressionBuilder<NaverAccountTable>? where,
    int? limit,
    _i1.Transaction? transaction,
  }) async {
    return session.db.count<NaverAccount>(
      where: where?.call(NaverAccount.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [NaverAccount] rows matching the [where] expression.
  Future<void> lockRows(
    _i1.DatabaseSession session, {
    required _i1.WhereExpressionBuilder<NaverAccountTable> where,
    required _i1.LockMode lockMode,
    required _i1.Transaction transaction,
    _i1.LockBehavior lockBehavior = _i1.LockBehavior.wait,
  }) async {
    return session.db.lockRows<NaverAccount>(
      where: where(NaverAccount.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}

class NaverAccountAttachRowRepository {
  const NaverAccountAttachRowRepository._();

  /// Creates a relation between the given [NaverAccount] and [AuthUser]
  /// by setting the [NaverAccount]'s foreign key `authUserId` to refer to the [AuthUser].
  Future<void> authUser(
    _i1.DatabaseSession session,
    NaverAccount naverAccount,
    _i2.AuthUser authUser, {
    _i1.Transaction? transaction,
  }) async {
    if (naverAccount.id == null) {
      throw ArgumentError.notNull('naverAccount.id');
    }
    if (authUser.id == null) {
      throw ArgumentError.notNull('authUser.id');
    }

    var $naverAccount = naverAccount.copyWith(authUserId: authUser.id);
    await session.db.updateRow<NaverAccount>(
      $naverAccount,
      columns: [NaverAccount.t.authUserId],
      transaction: transaction,
    );
  }
}
