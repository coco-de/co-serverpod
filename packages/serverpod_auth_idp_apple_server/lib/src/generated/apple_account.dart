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
import 'package:serverpod_auth_idp_apple_server/src/generated/protocol.dart'
    as _i3;

/// A fully configured "Sign in with Apple"-based account to be used for logins.
///
/// Ported from the official `serverpod_auth_idp_server` Apple provider, with the
/// coco-de provider adding nonce replay protection.
///
/// ⚠️ MIGRATION NOTE: the table/index names differ from the official provider
/// (`serverpod_auth_idp_apple_account`) because this package depends on
/// `serverpod_auth_idp_server`, which bundles the official Apple provider and
/// its identically-named table — a same-name table would collide. When
/// migrating kobic to this provider, copy existing rows from
/// `serverpod_auth_idp_apple_account` into `serverpod_auth_idp_apple_kr_account`
/// (keyed by `userIdentifier`) so existing Apple users keep their `AuthUser`.
abstract class AppleKrAccount
    implements _i1.TableRow<_i1.UuidValue?>, _i1.ProtocolSerialization {
  AppleKrAccount._({
    this.id,
    required this.userIdentifier,
    required this.refreshToken,
    required this.refreshTokenRequestedWithBundleIdentifier,
    DateTime? lastRefreshedAt,
    required this.authUserId,
    this.authUser,
    DateTime? createdAt,
    this.email,
    this.isEmailVerified,
    this.isPrivateEmail,
    this.firstName,
    this.lastName,
  }) : lastRefreshedAt = lastRefreshedAt ?? DateTime.now(),
       createdAt = createdAt ?? DateTime.now();

  factory AppleKrAccount({
    _i1.UuidValue? id,
    required String userIdentifier,
    required String refreshToken,
    required bool refreshTokenRequestedWithBundleIdentifier,
    DateTime? lastRefreshedAt,
    required _i1.UuidValue authUserId,
    _i2.AuthUser? authUser,
    DateTime? createdAt,
    String? email,
    bool? isEmailVerified,
    bool? isPrivateEmail,
    String? firstName,
    String? lastName,
  }) = _AppleKrAccountImpl;

  factory AppleKrAccount.fromJson(Map<String, dynamic> jsonSerialization) {
    return AppleKrAccount(
      id: jsonSerialization['id'] == null
          ? null
          : _i1.UuidValueJsonExtension.fromJson(jsonSerialization['id']),
      userIdentifier: jsonSerialization['userIdentifier'] as String,
      refreshToken: jsonSerialization['refreshToken'] as String,
      refreshTokenRequestedWithBundleIdentifier: _i1.BoolJsonExtension.fromJson(
        jsonSerialization['refreshTokenRequestedWithBundleIdentifier'],
      ),
      lastRefreshedAt: jsonSerialization['lastRefreshedAt'] == null
          ? null
          : _i1.DateTimeJsonExtension.fromJson(
              jsonSerialization['lastRefreshedAt'],
            ),
      authUserId: _i1.UuidValueJsonExtension.fromJson(
        jsonSerialization['authUserId'],
      ),
      authUser: jsonSerialization['authUser'] == null
          ? null
          : _i3.Protocol().deserialize<_i2.AuthUser>(
              jsonSerialization['authUser'],
            ),
      createdAt: jsonSerialization['createdAt'] == null
          ? null
          : _i1.DateTimeJsonExtension.fromJson(jsonSerialization['createdAt']),
      email: jsonSerialization['email'] as String?,
      isEmailVerified: jsonSerialization['isEmailVerified'] == null
          ? null
          : _i1.BoolJsonExtension.fromJson(
              jsonSerialization['isEmailVerified'],
            ),
      isPrivateEmail: jsonSerialization['isPrivateEmail'] == null
          ? null
          : _i1.BoolJsonExtension.fromJson(jsonSerialization['isPrivateEmail']),
      firstName: jsonSerialization['firstName'] as String?,
      lastName: jsonSerialization['lastName'] as String?,
    );
  }

  static final t = AppleKrAccountTable();

  static const db = AppleKrAccountRepository._();

  @override
  _i1.UuidValue? id;

  /// The Apple-provided user identifier
  String userIdentifier;

  /// Refresh token for this user, to sync the account details with Apple.
  ///
  /// Only the first one is stored per user.
  String refreshToken;

  /// Whether the refresh token was created on an Apple OS.
  ///
  /// The source of the initial registration needs to be retained throughout
  /// the lifecycle of the account.
  bool refreshTokenRequestedWithBundleIdentifier;

  /// Time when the account data was last received from Apple's servers.
  DateTime lastRefreshedAt;

  _i1.UuidValue authUserId;

  /// The [AuthUser] this profile belongs to
  _i2.AuthUser? authUser;

  /// The time when this authentication was created.
  DateTime createdAt;

  /// The email of the user.
  ///
  /// Stored in lower-case.
  ///
  /// Presence depends on whether this was requested with the initial sign-up.
  String? email;

  /// Whether the email has been verified by Apple.
  bool? isEmailVerified;

  /// Whether this email address is a private "relay" email address.
  bool? isPrivateEmail;

  /// The first name given during the initial registration.
  ///
  /// Will only be set if it was requested on sign-up.
  /// The user is free to put in whatever they want here, and this is not
  /// verified by or known to Apple.
  String? firstName;

  /// The last name given during the initial registration.
  ///
  /// Will only be set if it was requested on sign-up.
  /// The user is free to put in whatever they want here, and this is not
  /// verified by or known to Apple.
  String? lastName;

  @override
  _i1.Table<_i1.UuidValue?> get table => t;

  /// Returns a shallow copy of this [AppleKrAccount]
  /// with some or all fields replaced by the given arguments.
  @_i1.useResult
  AppleKrAccount copyWith({
    _i1.UuidValue? id,
    String? userIdentifier,
    String? refreshToken,
    bool? refreshTokenRequestedWithBundleIdentifier,
    DateTime? lastRefreshedAt,
    _i1.UuidValue? authUserId,
    _i2.AuthUser? authUser,
    DateTime? createdAt,
    String? email,
    bool? isEmailVerified,
    bool? isPrivateEmail,
    String? firstName,
    String? lastName,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'serverpod_auth_idp_apple.AppleKrAccount',
      if (id != null) 'id': id?.toJson(),
      'userIdentifier': userIdentifier,
      'refreshToken': refreshToken,
      'refreshTokenRequestedWithBundleIdentifier':
          refreshTokenRequestedWithBundleIdentifier,
      'lastRefreshedAt': lastRefreshedAt.toJson(),
      'authUserId': authUserId.toJson(),
      if (authUser != null) 'authUser': authUser?.toJson(),
      'createdAt': createdAt.toJson(),
      if (email != null) 'email': email,
      if (isEmailVerified != null) 'isEmailVerified': isEmailVerified,
      if (isPrivateEmail != null) 'isPrivateEmail': isPrivateEmail,
      if (firstName != null) 'firstName': firstName,
      if (lastName != null) 'lastName': lastName,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static AppleKrAccountInclude include({_i2.AuthUserInclude? authUser}) {
    return AppleKrAccountInclude._(authUser: authUser);
  }

  static AppleKrAccountIncludeList includeList({
    _i1.WhereExpressionBuilder<AppleKrAccountTable>? where,
    int? limit,
    int? offset,
    _i1.OrderByBuilder<AppleKrAccountTable>? orderBy,
    _i1.OrderByListBuilder<AppleKrAccountTable>? orderByList,
    AppleKrAccountInclude? include,
  }) {
    return AppleKrAccountIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(AppleKrAccount.t),
      orderByList: orderByList?.call(AppleKrAccount.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _i1.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _AppleKrAccountImpl extends AppleKrAccount {
  _AppleKrAccountImpl({
    _i1.UuidValue? id,
    required String userIdentifier,
    required String refreshToken,
    required bool refreshTokenRequestedWithBundleIdentifier,
    DateTime? lastRefreshedAt,
    required _i1.UuidValue authUserId,
    _i2.AuthUser? authUser,
    DateTime? createdAt,
    String? email,
    bool? isEmailVerified,
    bool? isPrivateEmail,
    String? firstName,
    String? lastName,
  }) : super._(
         id: id,
         userIdentifier: userIdentifier,
         refreshToken: refreshToken,
         refreshTokenRequestedWithBundleIdentifier:
             refreshTokenRequestedWithBundleIdentifier,
         lastRefreshedAt: lastRefreshedAt,
         authUserId: authUserId,
         authUser: authUser,
         createdAt: createdAt,
         email: email,
         isEmailVerified: isEmailVerified,
         isPrivateEmail: isPrivateEmail,
         firstName: firstName,
         lastName: lastName,
       );

  /// Returns a shallow copy of this [AppleKrAccount]
  /// with some or all fields replaced by the given arguments.
  @_i1.useResult
  @override
  AppleKrAccount copyWith({
    Object? id = _Undefined,
    String? userIdentifier,
    String? refreshToken,
    bool? refreshTokenRequestedWithBundleIdentifier,
    DateTime? lastRefreshedAt,
    _i1.UuidValue? authUserId,
    Object? authUser = _Undefined,
    DateTime? createdAt,
    Object? email = _Undefined,
    Object? isEmailVerified = _Undefined,
    Object? isPrivateEmail = _Undefined,
    Object? firstName = _Undefined,
    Object? lastName = _Undefined,
  }) {
    return AppleKrAccount(
      id: id is _i1.UuidValue? ? id : this.id,
      userIdentifier: userIdentifier ?? this.userIdentifier,
      refreshToken: refreshToken ?? this.refreshToken,
      refreshTokenRequestedWithBundleIdentifier:
          refreshTokenRequestedWithBundleIdentifier ??
          this.refreshTokenRequestedWithBundleIdentifier,
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
      authUserId: authUserId ?? this.authUserId,
      authUser: authUser is _i2.AuthUser?
          ? authUser
          : this.authUser?.copyWith(),
      createdAt: createdAt ?? this.createdAt,
      email: email is String? ? email : this.email,
      isEmailVerified: isEmailVerified is bool?
          ? isEmailVerified
          : this.isEmailVerified,
      isPrivateEmail: isPrivateEmail is bool?
          ? isPrivateEmail
          : this.isPrivateEmail,
      firstName: firstName is String? ? firstName : this.firstName,
      lastName: lastName is String? ? lastName : this.lastName,
    );
  }
}

class AppleKrAccountUpdateTable extends _i1.UpdateTable<AppleKrAccountTable> {
  AppleKrAccountUpdateTable(super.table);

  _i1.ColumnValue<String, String> userIdentifier(String value) =>
      _i1.ColumnValue(
        table.userIdentifier,
        value,
      );

  _i1.ColumnValue<String, String> refreshToken(String value) => _i1.ColumnValue(
    table.refreshToken,
    value,
  );

  _i1.ColumnValue<bool, bool> refreshTokenRequestedWithBundleIdentifier(
    bool value,
  ) => _i1.ColumnValue(
    table.refreshTokenRequestedWithBundleIdentifier,
    value,
  );

  _i1.ColumnValue<DateTime, DateTime> lastRefreshedAt(DateTime value) =>
      _i1.ColumnValue(
        table.lastRefreshedAt,
        value,
      );

  _i1.ColumnValue<_i1.UuidValue, _i1.UuidValue> authUserId(
    _i1.UuidValue value,
  ) => _i1.ColumnValue(
    table.authUserId,
    value,
  );

  _i1.ColumnValue<DateTime, DateTime> createdAt(DateTime value) =>
      _i1.ColumnValue(
        table.createdAt,
        value,
      );

  _i1.ColumnValue<String, String> email(String? value) => _i1.ColumnValue(
    table.email,
    value,
  );

  _i1.ColumnValue<bool, bool> isEmailVerified(bool? value) => _i1.ColumnValue(
    table.isEmailVerified,
    value,
  );

  _i1.ColumnValue<bool, bool> isPrivateEmail(bool? value) => _i1.ColumnValue(
    table.isPrivateEmail,
    value,
  );

  _i1.ColumnValue<String, String> firstName(String? value) => _i1.ColumnValue(
    table.firstName,
    value,
  );

  _i1.ColumnValue<String, String> lastName(String? value) => _i1.ColumnValue(
    table.lastName,
    value,
  );
}

class AppleKrAccountTable extends _i1.Table<_i1.UuidValue?> {
  AppleKrAccountTable({super.tableRelation})
    : super(tableName: 'serverpod_auth_idp_apple_kr_account') {
    updateTable = AppleKrAccountUpdateTable(this);
    userIdentifier = _i1.ColumnString(
      'userIdentifier',
      this,
    );
    refreshToken = _i1.ColumnString(
      'refreshToken',
      this,
    );
    refreshTokenRequestedWithBundleIdentifier = _i1.ColumnBool(
      'refreshTokenRequestedWithBundleIdentifier',
      this,
    );
    lastRefreshedAt = _i1.ColumnDateTime(
      'lastRefreshedAt',
      this,
      hasDefault: true,
    );
    authUserId = _i1.ColumnUuid(
      'authUserId',
      this,
    );
    createdAt = _i1.ColumnDateTime(
      'createdAt',
      this,
    );
    email = _i1.ColumnString(
      'email',
      this,
    );
    isEmailVerified = _i1.ColumnBool(
      'isEmailVerified',
      this,
    );
    isPrivateEmail = _i1.ColumnBool(
      'isPrivateEmail',
      this,
    );
    firstName = _i1.ColumnString(
      'firstName',
      this,
    );
    lastName = _i1.ColumnString(
      'lastName',
      this,
    );
  }

  late final AppleKrAccountUpdateTable updateTable;

  /// The Apple-provided user identifier
  late final _i1.ColumnString userIdentifier;

  /// Refresh token for this user, to sync the account details with Apple.
  ///
  /// Only the first one is stored per user.
  late final _i1.ColumnString refreshToken;

  /// Whether the refresh token was created on an Apple OS.
  ///
  /// The source of the initial registration needs to be retained throughout
  /// the lifecycle of the account.
  late final _i1.ColumnBool refreshTokenRequestedWithBundleIdentifier;

  /// Time when the account data was last received from Apple's servers.
  late final _i1.ColumnDateTime lastRefreshedAt;

  late final _i1.ColumnUuid authUserId;

  /// The [AuthUser] this profile belongs to
  _i2.AuthUserTable? _authUser;

  /// The time when this authentication was created.
  late final _i1.ColumnDateTime createdAt;

  /// The email of the user.
  ///
  /// Stored in lower-case.
  ///
  /// Presence depends on whether this was requested with the initial sign-up.
  late final _i1.ColumnString email;

  /// Whether the email has been verified by Apple.
  late final _i1.ColumnBool isEmailVerified;

  /// Whether this email address is a private "relay" email address.
  late final _i1.ColumnBool isPrivateEmail;

  /// The first name given during the initial registration.
  ///
  /// Will only be set if it was requested on sign-up.
  /// The user is free to put in whatever they want here, and this is not
  /// verified by or known to Apple.
  late final _i1.ColumnString firstName;

  /// The last name given during the initial registration.
  ///
  /// Will only be set if it was requested on sign-up.
  /// The user is free to put in whatever they want here, and this is not
  /// verified by or known to Apple.
  late final _i1.ColumnString lastName;

  _i2.AuthUserTable get authUser {
    if (_authUser != null) return _authUser!;
    _authUser = _i1.createRelationTable(
      relationFieldName: 'authUser',
      field: AppleKrAccount.t.authUserId,
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
    userIdentifier,
    refreshToken,
    refreshTokenRequestedWithBundleIdentifier,
    lastRefreshedAt,
    authUserId,
    createdAt,
    email,
    isEmailVerified,
    isPrivateEmail,
    firstName,
    lastName,
  ];

  @override
  _i1.Table? getRelationTable(String relationField) {
    if (relationField == 'authUser') {
      return authUser;
    }
    return null;
  }
}

class AppleKrAccountInclude extends _i1.IncludeObject {
  AppleKrAccountInclude._({_i2.AuthUserInclude? authUser}) {
    _authUser = authUser;
  }

  _i2.AuthUserInclude? _authUser;

  @override
  Map<String, _i1.Include?> get includes => {'authUser': _authUser};

  @override
  _i1.Table<_i1.UuidValue?> get table => AppleKrAccount.t;
}

class AppleKrAccountIncludeList extends _i1.IncludeList {
  AppleKrAccountIncludeList._({
    _i1.WhereExpressionBuilder<AppleKrAccountTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(AppleKrAccount.t);
  }

  @override
  Map<String, _i1.Include?> get includes => include?.includes ?? {};

  @override
  _i1.Table<_i1.UuidValue?> get table => AppleKrAccount.t;
}

class AppleKrAccountRepository {
  const AppleKrAccountRepository._();

  final attachRow = const AppleKrAccountAttachRowRepository._();

  /// Returns a list of [AppleKrAccount]s matching the given query parameters.
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
  Future<List<AppleKrAccount>> find(
    _i1.DatabaseSession session, {
    _i1.WhereExpressionBuilder<AppleKrAccountTable>? where,
    int? limit,
    int? offset,
    _i1.OrderByBuilder<AppleKrAccountTable>? orderBy,
    _i1.OrderByListBuilder<AppleKrAccountTable>? orderByList,
    _i1.Transaction? transaction,
    AppleKrAccountInclude? include,
    _i1.LockMode? lockMode,
    _i1.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<AppleKrAccount>(
      where: where?.call(AppleKrAccount.t),
      orderBy: orderBy?.call(AppleKrAccount.t),
      orderByList: orderByList?.call(AppleKrAccount.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Returns the first matching [AppleKrAccount] matching the given query parameters.
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
  Future<AppleKrAccount?> findFirstRow(
    _i1.DatabaseSession session, {
    _i1.WhereExpressionBuilder<AppleKrAccountTable>? where,
    int? offset,
    _i1.OrderByBuilder<AppleKrAccountTable>? orderBy,
    _i1.OrderByListBuilder<AppleKrAccountTable>? orderByList,
    _i1.Transaction? transaction,
    AppleKrAccountInclude? include,
    _i1.LockMode? lockMode,
    _i1.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<AppleKrAccount>(
      where: where?.call(AppleKrAccount.t),
      orderBy: orderBy?.call(AppleKrAccount.t),
      orderByList: orderByList?.call(AppleKrAccount.t),
      offset: offset,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [AppleKrAccount] by its [id] or null if no such row exists.
  Future<AppleKrAccount?> findById(
    _i1.DatabaseSession session,
    _i1.UuidValue id, {
    _i1.Transaction? transaction,
    AppleKrAccountInclude? include,
    _i1.LockMode? lockMode,
    _i1.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<AppleKrAccount>(
      id,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [AppleKrAccount]s in the list and returns the inserted rows.
  ///
  /// The returned [AppleKrAccount]s will have their `id` fields set.
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
  Future<List<AppleKrAccount>> insert(
    _i1.DatabaseSession session,
    List<AppleKrAccount> rows, {
    _i1.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<AppleKrAccount>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [AppleKrAccount] and returns the inserted row.
  ///
  /// The returned [AppleKrAccount] will have its `id` field set.
  Future<AppleKrAccount> insertRow(
    _i1.DatabaseSession session,
    AppleKrAccount row, {
    _i1.Transaction? transaction,
  }) async {
    return session.db.insertRow<AppleKrAccount>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [AppleKrAccount]s in the list and returns the resulting rows.
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
  /// The returned [AppleKrAccount]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<AppleKrAccount>> upsert(
    _i1.DatabaseSession session,
    List<AppleKrAccount> rows, {
    required _i1.ColumnSelections<AppleKrAccountTable> conflictColumns,
    _i1.ColumnSelections<AppleKrAccountTable>? updateColumns,
    _i1.WhereExpressionBuilder<AppleKrAccountTable>? updateWhere,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<AppleKrAccount>(
      rows,
      conflictColumns: conflictColumns(AppleKrAccount.t),
      updateColumns: updateColumns?.call(AppleKrAccount.t),
      updateWhere: updateWhere?.call(AppleKrAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [AppleKrAccount] and returns the resulting row.
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
  /// The returned [AppleKrAccount] will have its `id` field set.
  Future<AppleKrAccount?> upsertRow(
    _i1.DatabaseSession session,
    AppleKrAccount row, {
    required _i1.ColumnSelections<AppleKrAccountTable> conflictColumns,
    _i1.ColumnSelections<AppleKrAccountTable>? updateColumns,
    _i1.WhereExpressionBuilder<AppleKrAccountTable>? updateWhere,
    _i1.Transaction? transaction,
  }) async {
    return session.db.upsertRow<AppleKrAccount>(
      row,
      conflictColumns: conflictColumns(AppleKrAccount.t),
      updateColumns: updateColumns?.call(AppleKrAccount.t),
      updateWhere: updateWhere?.call(AppleKrAccount.t),
      transaction: transaction,
    );
  }

  /// Updates all [AppleKrAccount]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<AppleKrAccount>> update(
    _i1.DatabaseSession session,
    List<AppleKrAccount> rows, {
    _i1.ColumnSelections<AppleKrAccountTable>? columns,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<AppleKrAccount>(
      rows,
      columns: columns?.call(AppleKrAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [AppleKrAccount]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<AppleKrAccount> updateRow(
    _i1.DatabaseSession session,
    AppleKrAccount row, {
    _i1.ColumnSelections<AppleKrAccountTable>? columns,
    _i1.Transaction? transaction,
  }) async {
    return session.db.updateRow<AppleKrAccount>(
      row,
      columns: columns?.call(AppleKrAccount.t),
      transaction: transaction,
    );
  }

  /// Updates a single [AppleKrAccount] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<AppleKrAccount?> updateById(
    _i1.DatabaseSession session,
    _i1.UuidValue id, {
    required _i1.ColumnValueListBuilder<AppleKrAccountUpdateTable> columnValues,
    _i1.Transaction? transaction,
  }) async {
    return session.db.updateById<AppleKrAccount>(
      id,
      columnValues: columnValues(AppleKrAccount.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [AppleKrAccount]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<AppleKrAccount>> updateWhere(
    _i1.DatabaseSession session, {
    required _i1.ColumnValueListBuilder<AppleKrAccountUpdateTable> columnValues,
    required _i1.WhereExpressionBuilder<AppleKrAccountTable> where,
    int? limit,
    int? offset,
    _i1.OrderByBuilder<AppleKrAccountTable>? orderBy,
    _i1.OrderByListBuilder<AppleKrAccountTable>? orderByList,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<AppleKrAccount>(
      columnValues: columnValues(AppleKrAccount.t.updateTable),
      where: where(AppleKrAccount.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(AppleKrAccount.t),
      orderByList: orderByList?.call(AppleKrAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [AppleKrAccount]s in the list and returns the deleted rows.
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
  Future<List<AppleKrAccount>> delete(
    _i1.DatabaseSession session,
    List<AppleKrAccount> rows, {
    _i1.OrderByBuilder<AppleKrAccountTable>? orderBy,
    _i1.OrderByListBuilder<AppleKrAccountTable>? orderByList,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<AppleKrAccount>(
      rows,
      orderBy: orderBy?.call(AppleKrAccount.t),
      orderByList: orderByList?.call(AppleKrAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [AppleKrAccount].
  Future<AppleKrAccount> deleteRow(
    _i1.DatabaseSession session,
    AppleKrAccount row, {
    _i1.Transaction? transaction,
  }) async {
    return session.db.deleteRow<AppleKrAccount>(
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
  Future<List<AppleKrAccount>> deleteWhere(
    _i1.DatabaseSession session, {
    required _i1.WhereExpressionBuilder<AppleKrAccountTable> where,
    _i1.OrderByBuilder<AppleKrAccountTable>? orderBy,
    _i1.OrderByListBuilder<AppleKrAccountTable>? orderByList,
    _i1.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<AppleKrAccount>(
      where: where(AppleKrAccount.t),
      orderBy: orderBy?.call(AppleKrAccount.t),
      orderByList: orderByList?.call(AppleKrAccount.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _i1.DatabaseSession session, {
    _i1.WhereExpressionBuilder<AppleKrAccountTable>? where,
    int? limit,
    _i1.Transaction? transaction,
  }) async {
    return session.db.count<AppleKrAccount>(
      where: where?.call(AppleKrAccount.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [AppleKrAccount] rows matching the [where] expression.
  Future<void> lockRows(
    _i1.DatabaseSession session, {
    required _i1.WhereExpressionBuilder<AppleKrAccountTable> where,
    required _i1.LockMode lockMode,
    required _i1.Transaction transaction,
    _i1.LockBehavior lockBehavior = _i1.LockBehavior.wait,
  }) async {
    return session.db.lockRows<AppleKrAccount>(
      where: where(AppleKrAccount.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}

class AppleKrAccountAttachRowRepository {
  const AppleKrAccountAttachRowRepository._();

  /// Creates a relation between the given [AppleKrAccount] and [AuthUser]
  /// by setting the [AppleKrAccount]'s foreign key `authUserId` to refer to the [AuthUser].
  Future<void> authUser(
    _i1.DatabaseSession session,
    AppleKrAccount appleKrAccount,
    _i2.AuthUser authUser, {
    _i1.Transaction? transaction,
  }) async {
    if (appleKrAccount.id == null) {
      throw ArgumentError.notNull('appleKrAccount.id');
    }
    if (authUser.id == null) {
      throw ArgumentError.notNull('authUser.id');
    }

    var $appleKrAccount = appleKrAccount.copyWith(authUserId: authUser.id);
    await session.db.updateRow<AppleKrAccount>(
      $appleKrAccount,
      columns: [AppleKrAccount.t.authUserId],
      transaction: transaction,
    );
  }
}
