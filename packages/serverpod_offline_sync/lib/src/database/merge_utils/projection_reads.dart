part of 'foreign_key_projector.dart';

/// Loads metadata for one projection read phase in one space and transaction.
/// Field identities are resolved through the scoped rows and registered columns,
/// so equal domain UUIDs in different tables remain distinct.
///
/// Its maps become mutable projection state. Complete loading before applying
/// pending inserts or authored overlays to them.
class _ProjectionReader {
  _ProjectionReader(this._context, this._transaction);

  final CrdtRecorderContext _context;
  final Transaction _transaction;
  final rows = <MergeRowKey, _ProjectedForeignKeyRow>{};
  final fieldIds = <MergeFieldKey, int>{};
  final attemptedValues = <MergeFieldKey, CrdtDataAttemptedValue>{};
  final fieldHlcs = <MergeFieldKey, Hlc>{};

  /// Whether this space and these tables hold any attempted claims.
  /// A false result lets the closure skip attempted-claim queries, but is
  /// valid only until the next write phase; each projection checks again.
  Future<bool> hasAttemptedClaims(Set<String> tablesToLoad) async {
    final spaceId = _context.hlcManagerFor(_transaction).normalizedSpaceId;
    return tablesToLoad.isNotEmpty &&
        await CrdtDataAttemptedValue.db.findFirstRow(
              _context.databaseSession,
              where: (t) =>
                  t.field.row.spaceId.equals(spaceId) &
                  t.field.row.tblId.inSet({
                    for (final table in tablesToLoad) _context.schema[table]!.$1,
                  }),
              transaction: _transaction,
            ) !=
            null;
  }

  /// Loads one closure wave, sharing metadata reads across its tables.
  /// A null row-id set requests the whole table during a full rebuild.
  Future<Map<String, Set<UuidValue>>> loadRows({
    required Map<String, Set<UuidValue>?> requestedRows,
    required Map<String, Set<String>> columnsByTable,
    Map<String, Set<String>>? projectionColumnsByTable,
    Map<String, Set<UuidValue>> allColumnRowIds = const {},
  }) async {
    final tablesById = {
      for (final entry in requestedRows.entries)
        if (entry.value == null || entry.value!.isNotEmpty)
          _context.schema[entry.key]!.$1: entry.key,
    };
    if (tablesById.isEmpty) return {};

    final spaceId = _context.hlcManagerFor(_transaction).normalizedSpaceId;
    final crdtRows = await CrdtDataRow.db.find(
      _context.databaseSession,
      where: (t) =>
          t.spaceId.equals(spaceId) &
          tablesById.entries
              .map((entry) {
                final rowIds = requestedRows[entry.value];
                final table = t.tblId.equals(entry.key);
                return rowIds == null ? table : table & t.uuidRowId.inSet(rowIds);
              })
              .reduce((left, right) => left | right),
      include: CrdtDataRow.include(
        node: CrdtNode.include(),
        deleted: CrdtDataDeleted.include(node: CrdtNode.include()),
      ),
      orderBy: (t) => t.uuidRowId,
      transaction: _transaction,
    );
    final metadataByTable = <String, List<CrdtDataRow>>{};
    for (final row in crdtRows) {
      (metadataByTable[tablesById[row.tblId]!] ??= []).add(row);
    }

    final loadedByTable = <String, Set<UuidValue>>{};
    final columnsById = <int, String>{};
    final fieldRequests = <({Set<int> rows, Set<int> columns})>[];
    for (final tableName in requestedRows.keys) {
      final tableRows = metadataByTable[tableName];
      if (tableRows == null) continue;
      final loadedIds = {for (final row in tableRows) row.uuidRowId};
      loadedByTable[tableName] = loadedIds;
      final readSets = await _columnReadSets(
        tableName: tableName,
        loadedIds: loadedIds,
        columnNames: columnsByTable[tableName] ?? const {},
        projectionColumnNames: projectionColumnsByTable == null
            ? null
            : projectionColumnsByTable[tableName] ?? const {},
        allColumnRowIds: allColumnRowIds[tableName] ?? const {},
        transaction: _transaction,
      );
      final valuesByRowId = <UuidValue, Map<String, Object?>>{};
      for (final (ids, columns) in readSets) {
        if (projectionColumnsByTable != null) {
          OfflineSyncProjectionDebug.onClosureColumnsRead?.call(
            tableName,
            ids,
            columns,
          );
        }
        if (columns.isEmpty) continue;
        valuesByRowId.addAll(
          await _context.readDomainColumnValues(
            tableName,
            ids,
            columns,
            _transaction,
          ),
        );
        final schemaColumns = _context.schemaColumnIds(tableName, columns.toSet());
        if (schemaColumns.isEmpty) continue;
        columnsById.addAll({
          for (final entry in schemaColumns.entries) entry.value: entry.key,
        });
        fieldRequests.add((
          rows: {
            for (final row in tableRows)
              if (ids.contains(row.uuidRowId)) row.id!,
          },
          columns: schemaColumns.values.toSet(),
        ));
      }
      for (final row in tableRows) {
        final key = (tableName, row.uuidRowId);
        rows[key] = (
          key: key,
          crdtRow: row,
          values: Map<String, Object?>.from(valuesByRowId[row.uuidRowId] ?? const {}),
        );
      }
    }
    if (fieldRequests.isEmpty) return loadedByTable;

    final rowKeysById = {
      for (final row in crdtRows) row.id!: (tablesById[row.tblId]!, row.uuidRowId),
    };
    final fields = await CrdtDataField.db.find(
      _context.databaseSession,
      where: (t) => fieldRequests
          .map((request) {
            return t.rowId.inSet(request.rows) & t.columnId.inSet(request.columns);
          })
          .reduce((left, right) => left | right),
      include: CrdtDataField.include(
        node: CrdtNode.include(),
        attemptedValue: CrdtDataAttemptedValue.include(),
      ),
      transaction: _transaction,
    );
    for (final field in fields) {
      final rowKey = rowKeysById[field.rowId]!;
      final fieldKey = (rowKey.$1, rowKey.$2, columnsById[field.columnId]!);
      fieldIds[fieldKey] = field.id!;
      fieldHlcs[fieldKey] = field.hlc;
      if (field.attemptedValue case final attempted?) {
        attemptedValues[fieldKey] = attempted;
      }
    }
    return loadedByTable;
  }

  /// The row ids of [loadedIds] paired with the columns each reads, in the
  /// order of [columnNames].
  ///
  /// One set reading every column when [projectionColumnNames] is null;
  /// otherwise the rows that read every column, then the rest reading the
  /// projection columns (see [loadRows]). Empty sets are left out.
  Future<List<(Set<UuidValue>, List<String>)>> _columnReadSets({
    required String tableName,
    required Set<UuidValue> loadedIds,
    required Set<String> columnNames,
    required Set<String>? projectionColumnNames,
    required Set<UuidValue> allColumnRowIds,
    required Transaction transaction,
  }) async {
    if (projectionColumnNames == null) {
      return [(loadedIds, columnNames.toList())];
    }

    final allColumnIds = loadedIds.intersection(allColumnRowIds);
    var projectionIds = loadedIds.difference(allColumnIds);
    final unreadColumns = columnNames.difference(projectionColumnNames);
    if (unreadColumns.isNotEmpty && projectionIds.isNotEmpty) {
      final holding = await _rowsWithAttemptedValues(
        tableName: tableName,
        rowIds: projectionIds,
        columnNames: unreadColumns,
        transaction: transaction,
      );
      allColumnIds.addAll(holding);
      projectionIds = projectionIds.difference(holding);
    }

    return [
      if (allColumnIds.isNotEmpty) (allColumnIds, columnNames.toList()),
      if (projectionIds.isNotEmpty)
        (
          projectionIds,
          [
            for (final columnName in columnNames)
              if (projectionColumnNames.contains(columnName)) columnName,
          ],
        ),
    ];
  }

  /// The rows of [rowIds] holding an attempted value on any of [columnNames].
  ///
  /// Attempted values are sparse, so this asks their table instead of reading
  /// the fields of every row.
  Future<Set<UuidValue>> _rowsWithAttemptedValues({
    required String tableName,
    required Set<UuidValue> rowIds,
    required Set<String> columnNames,
    required Transaction transaction,
  }) async {
    final (tableId, _) = _context.schema[tableName]!;
    final userId = _context.hlcManagerFor(transaction).normalizedSpaceId;
    final attempted = await CrdtDataAttemptedValue.db.find(
      _context.databaseSession,
      where: (t) =>
          t.field.row.spaceId.equals(userId) &
          t.field.row.tblId.equals(tableId) &
          t.field.row.uuidRowId.inSet(rowIds) &
          t.field.column.name.inSet(columnNames),
      include: CrdtDataAttemptedValue.include(
        field: CrdtDataField.include(row: CrdtDataRow.include()),
      ),
      transaction: transaction,
    );
    return {for (final value in attempted) value.field!.row!.uuidRowId};
  }
}

/// Collects the required claim lookups for one closure wave by table.
/// Traversal selects the claims; this collector handles grouped execution.
/// Each composite claim remains independent when the queries are combined.
class _ProjectionClaimReads {
  _ProjectionClaimReads(
    this._context,
    this._transaction, {
    required this._includeAttemptedClaims,
  });

  final CrdtRecorderContext _context;
  final Transaction _transaction;
  final bool _includeAttemptedClaims;
  final _byTable = <String, List<Map<String, Set<Object?>>>>{};

  void add(String tableName, Map<String, Set<Object?>> claim) {
    (_byTable[tableName] ??= []).add(claim);
  }

  Future<void> enqueueMatches(
    void Function(String tableName, Iterable<UuidValue> ids) enqueue,
  ) async {
    for (final MapEntry(key: tableName, value: claims) in _byTable.entries) {
      enqueue(
        tableName,
        await _context.findDomainRowIdsWhereAnyColumnsIn(
          tableName: tableName,
          alternatives: claims,
          transaction: _transaction,
        ),
      );
      if (!_includeAttemptedClaims) continue;

      enqueue(
        tableName,
        await _context.findRowIdsHoldingAnyAttemptedValues(
          tableName: tableName,
          alternatives: [
            for (final claim in claims)
              (
                columnNames: claim.keys.toSet(),
                values: {for (final values in claim.values) ...values},
              ),
          ],
          transaction: _transaction,
        ),
      );
    }
  }
}
