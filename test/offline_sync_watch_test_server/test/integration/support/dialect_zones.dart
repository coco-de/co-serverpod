import 'dart:async';

import 'package:serverpod/serverpod.dart';

/// Lets one isolate hold a PostgreSQL server and SQLite devices.
///
/// `serverpod_database` encodes query values through one process-wide
/// [ValueEncoder], the one of the last [Database] created. A SQLite device
/// opened after the PostgreSQL server makes the server encode a UUID as a
/// SQLite blob literal, which PostgreSQL reads as a bit string
/// (`operator does not exist: uuid = bit`); the other way round a SQLite
/// device compares a UUID blob with text and silently matches nothing.
///
/// [ZonedDatabase] runs every call of its database in a zone naming its
/// dialect, and [DialectValueEncoder] encodes with that dialect's encoder.
/// Code outside any zone, such as the test server's own sessions, gets the
/// PostgreSQL one.
final class DialectValueEncoder implements ValueEncoder {
  DialectValueEncoder._();

  static final _instance = DialectValueEncoder._();
  static const _zoneKey = #offlineSyncTestDialect;

  final _encoders = <DatabaseDialect, ValueEncoder>{};

  /// How many times something replaced this encoder after [capture] installed
  /// it. A replacement in the middle of a query would encode it with the
  /// wrong dialect, so a test checks this stays zero.
  static int replacements = 0;

  /// Records the encoder the [Database] of [dialect] just created installed,
  /// and installs this one instead.
  static void capture(DatabaseDialect dialect) {
    final current = ValueEncoder.instance;
    if (current is! DialectValueEncoder) {
      _instance._encoders[dialect] = current;
    }
    ValueEncoder.set(_instance);
  }

  /// A zone, forked from the current one, whose SQL [dialect] encodes.
  static Zone zoneFor(DatabaseDialect dialect) =>
      Zone.current.fork(zoneValues: {_zoneKey: dialect});

  /// Installs this encoder again, counting a replacement when it was not.
  static void _ensureInstalled() {
    final current = ValueEncoder.instance;
    if (identical(current, _instance)) return;
    replacements++;
    ValueEncoder.set(_instance);
  }

  ValueEncoder get _current {
    final dialect =
        Zone.current[_zoneKey] as DatabaseDialect? ?? DatabaseDialect.postgres;
    final encoder = _encoders[dialect];
    if (encoder == null) {
      throw StateError('No $dialect database was captured.');
    }
    return encoder;
  }

  @override
  String convert(
    Object? input, {
    bool escapeStrings = true,
    bool hasDefaults = false,
  }) => _current.convert(
    input,
    escapeStrings: escapeStrings,
    hasDefaults: hasDefaults,
  );

  @override
  String? tryConvert(Object? input, {bool escapeStrings = false}) =>
      _current.tryConvert(input, escapeStrings: escapeStrings);

  @override
  String encodeColumnValue(
    Column<dynamic> column,
    dynamic value, {
    bool hasDefaults = false,
  }) => _current.encodeColumnValue(column, value, hasDefaults: hasDefaults);

  @override
  String quoteTableName(String tableName) => _current.quoteTableName(tableName);
}

/// A [Database] whose every call runs in the zone of its dialect, see
/// [DialectValueEncoder].
final class ZonedDatabase implements Database {
  ZonedDatabase(this._inner)
    : _zoneValues = {DialectValueEncoder._zoneKey: _inner.dialect};

  final Database _inner;
  final Map<Object?, Object?> _zoneValues;

  R _run<R>(R Function() body) {
    DialectValueEncoder._ensureInstalled();
    return runZoned(body, zoneValues: _zoneValues);
  }

  @override
  DatabaseDialect get dialect => _inner.dialect;

  @override
  DatabaseSerializationManager get serializationManager =>
      _inner.serializationManager;

  @override
  DatabaseAnalyzer get analyzer => _inner.analyzer;

  @override
  Future<List<T>> find<T extends TableRow<dynamic>>({
    Expression<dynamic>? where,
    int? limit,
    int? offset,
    Column<dynamic>? orderBy,
    List<Column<dynamic>>? orderByList,
    Transaction? transaction,
    Include? include,
    LockMode? lockMode,
    LockBehavior? lockBehavior,
  }) => _run(
    () => _inner.find<T>(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy,
      orderByList: orderByList,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    ),
  );

  @override
  Future<T?> findFirstRow<T extends TableRow<dynamic>>({
    Expression<dynamic>? where,
    int? offset,
    Column<dynamic>? orderBy,
    List<Column<dynamic>>? orderByList,
    Transaction? transaction,
    Include? include,
    LockMode? lockMode,
    LockBehavior? lockBehavior,
  }) => _run(
    () => _inner.findFirstRow<T>(
      where: where,
      offset: offset,
      orderBy: orderBy,
      orderByList: orderByList,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    ),
  );

  @override
  Future<T?> findById<T extends TableRow<dynamic>>(
    Object id, {
    Transaction? transaction,
    Include? include,
    LockMode? lockMode,
    LockBehavior? lockBehavior,
  }) => _run(
    () => _inner.findById<T>(
      id,
      transaction: transaction,
      include: include,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    ),
  );

  @override
  Future<void> lockRows<T extends TableRow<dynamic>>({
    required Expression<dynamic> where,
    required LockMode lockMode,
    required Transaction transaction,
    LockBehavior lockBehavior = LockBehavior.wait,
  }) => _run(
    () => _inner.lockRows<T>(
      where: where,
      lockMode: lockMode,
      transaction: transaction,
      lockBehavior: lockBehavior,
    ),
  );

  @override
  Future<List<T>> update<T extends TableRow<dynamic>>(
    List<T> rows, {
    List<Column<dynamic>>? columns,
    Transaction? transaction,
    bool noReturn = false,
  }) => _run(
    () => _inner.update<T>(
      rows,
      columns: columns,
      transaction: transaction,
      noReturn: noReturn,
    ),
  );

  @override
  Future<T> updateRow<T extends TableRow<dynamic>>(
    T row, {
    List<Column<dynamic>>? columns,
    Transaction? transaction,
  }) => _run(
    () => _inner.updateRow<T>(row, columns: columns, transaction: transaction),
  );

  @override
  Future<T?> updateById<T extends TableRow<dynamic>>(
    Object id, {
    required List<ColumnValue<dynamic, dynamic>> columnValues,
    Transaction? transaction,
  }) => _run(
    () => _inner.updateById<T>(
      id,
      columnValues: columnValues,
      transaction: transaction,
    ),
  );

  @override
  Future<List<T>> updateWhere<T extends TableRow<dynamic>>({
    required List<ColumnValue<dynamic, dynamic>> columnValues,
    required Expression<dynamic> where,
    int? limit,
    int? offset,
    Column<dynamic>? orderBy,
    List<Column<dynamic>>? orderByList,
    Transaction? transaction,
    bool noReturn = false,
  }) => _run(
    () => _inner.updateWhere<T>(
      columnValues: columnValues,
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy,
      orderByList: orderByList,
      transaction: transaction,
      noReturn: noReturn,
    ),
  );

  @override
  Future<List<T>> insert<T extends TableRow<dynamic>>(
    List<T> rows, {
    Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) => _run(
    () => _inner.insert<T>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    ),
  );

  @override
  Future<T> insertRow<T extends TableRow<dynamic>>(
    T row, {
    Transaction? transaction,
  }) => _run(() => _inner.insertRow<T>(row, transaction: transaction));

  @override
  Future<List<T>> upsert<T extends TableRow<dynamic>>(
    List<T> rows, {
    required List<Column<dynamic>> conflictColumns,
    List<Column<dynamic>>? updateColumns,
    Expression<dynamic>? updateWhere,
    Transaction? transaction,
    bool noReturn = false,
  }) => _run(
    () => _inner.upsert<T>(
      rows,
      conflictColumns: conflictColumns,
      updateColumns: updateColumns,
      updateWhere: updateWhere,
      transaction: transaction,
      noReturn: noReturn,
    ),
  );

  @override
  Future<T?> upsertRow<T extends TableRow<dynamic>>(
    T row, {
    required List<Column<dynamic>> conflictColumns,
    List<Column<dynamic>>? updateColumns,
    Expression<dynamic>? updateWhere,
    Transaction? transaction,
  }) => _run(
    () => _inner.upsertRow<T>(
      row,
      conflictColumns: conflictColumns,
      updateColumns: updateColumns,
      updateWhere: updateWhere,
      transaction: transaction,
    ),
  );

  @override
  Future<List<T>> delete<T extends TableRow<dynamic>>(
    List<T> rows, {
    Column<dynamic>? orderBy,
    List<Column<dynamic>>? orderByList,
    Transaction? transaction,
    bool noReturn = false,
  }) => _run(
    () => _inner.delete<T>(
      rows,
      orderBy: orderBy,
      orderByList: orderByList,
      transaction: transaction,
      noReturn: noReturn,
    ),
  );

  @override
  Future<T> deleteRow<T extends TableRow<dynamic>>(
    T row, {
    Transaction? transaction,
  }) => _run(() => _inner.deleteRow<T>(row, transaction: transaction));

  @override
  Future<List<T>> deleteWhere<T extends TableRow<dynamic>>({
    required Expression<dynamic> where,
    Column<dynamic>? orderBy,
    List<Column<dynamic>>? orderByList,
    Transaction? transaction,
    bool noReturn = false,
  }) => _run(
    () => _inner.deleteWhere<T>(
      where: where,
      orderBy: orderBy,
      orderByList: orderByList,
      transaction: transaction,
      noReturn: noReturn,
    ),
  );

  @override
  Future<int> count<T extends TableRow<dynamic>>({
    Expression<dynamic>? where,
    int? limit,
    bool useCache = true,
    Transaction? transaction,
  }) => _run(
    () => _inner.count<T>(
      where: where,
      limit: limit,
      useCache: useCache,
      transaction: transaction,
    ),
  );

  @override
  Stream<List<T>> watch<T extends TableRow<dynamic>>({
    Expression<dynamic>? where,
    int? limit,
    int? offset,
    Column<dynamic>? orderBy,
    List<Column<dynamic>>? orderByList,
    Include? include,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<Table<dynamic>>? alsoTriggerOnTables,
  }) => throw UnsupportedError('watch is not used by these tests');

  @override
  Future<DatabaseResult> unsafeQuery(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
    QueryParameters? parameters,
  }) => _run(
    () => _inner.unsafeQuery(
      query,
      timeoutInSeconds: timeoutInSeconds,
      transaction: transaction,
      parameters: parameters,
    ),
  );

  @override
  Future<int> unsafeExecute(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
    QueryParameters? parameters,
  }) => _run(
    () => _inner.unsafeExecute(
      query,
      timeoutInSeconds: timeoutInSeconds,
      transaction: transaction,
      parameters: parameters,
    ),
  );

  @override
  Future<DatabaseResult> unsafeSimpleQuery(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
  }) => _run(
    () => _inner.unsafeSimpleQuery(
      query,
      timeoutInSeconds: timeoutInSeconds,
      transaction: transaction,
    ),
  );

  @override
  Future<int> unsafeSimpleExecute(
    String query, {
    int? timeoutInSeconds,
    Transaction? transaction,
  }) => _run(
    () => _inner.unsafeSimpleExecute(
      query,
      timeoutInSeconds: timeoutInSeconds,
      transaction: transaction,
    ),
  );

  @override
  Stream<DatabaseResult> unsafeWatch(
    String query, {
    QueryParameters? parameters,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<String>? triggerOnTables,
  }) => throw UnsupportedError('unsafeWatch is not used by these tests');

  @override
  Future<R> transaction<R>(
    TransactionFunction<R> transactionFunction, {
    TransactionSettings? settings,
  }) => _run(
    () => _inner.transaction<R>(transactionFunction, settings: settings),
  );

  @override
  Future<bool> testConnection() => _run(_inner.testConnection);
}

/// A [DatabaseSession] over [inner] whose database runs in its dialect's
/// zone, see [ZonedDatabase].
///
/// The offline sync layer builds SQL literals itself before it calls its
/// inner database, so the zone has to be entered above it, not only below.
final class ZonedSession implements DatabaseSession {
  ZonedSession(this.inner) : db = ZonedDatabase(inner.db);

  /// The session whose calls this routes.
  final DatabaseSession inner;

  @override
  final Database db;

  @override
  Transaction? get transaction => inner.transaction;

  @override
  LogQueryFunction? get logQuery => inner.logQuery;

  @override
  LogWarningFunction? get logWarning => inner.logWarning;
}

/// [source], listened to in [zone], with the listener's callbacks run in the
/// listener's zone.
///
/// An `async*` stream runs in the zone of whoever listens to it. A sync
/// session has each side listen to the other's stream, so without this the
/// server would merge in the device's zone and the other way round.
Stream<T> listenedIn<T>(Zone zone, Stream<T> source) {
  late StreamController<T> controller;
  StreamSubscription<T>? subscription;
  controller = StreamController<T>(
    onListen: () {
      final listener = Zone.current;
      subscription = zone.run(
        () => source.listen(
          (event) => listener.run(() => controller.add(event)),
          onError: (Object error, StackTrace stackTrace) =>
              listener.run(() => controller.addError(error, stackTrace)),
          onDone: () => listener.run(controller.close),
        ),
      );
    },
    onPause: () => zone.run(() => subscription?.pause()),
    onResume: () => zone.run(() => subscription?.resume()),
    onCancel: () => zone.run(() => subscription?.cancel()),
  );
  return controller.stream;
}
