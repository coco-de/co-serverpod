import 'package:serverpod_database/serverpod_database.dart';
import 'package:uuid/uuid.dart';

import '../database/unique_index_utils.dart';
import 'exceptions.dart';
import 'schema_compatibility.dart';

/// An immutable description of the generated synchronized schema.
///
/// Construct this from generated `syncTables` and
/// `Protocol().getTargetTableDefinitions()`, on either the server or client.
/// Adding or changing a model then updates the hash and table list through
/// the normal Serverpod generator: no copied hash, table-name list or schema
/// counter is needed. This does not migrate the database or make different
/// schemas compatible; the stream still requires an exact hash match.
final class OfflineSyncSchema {
  /// Computes the same hash used by the stream handshake, without opening a DB.
  factory OfflineSyncSchema.fromTables(
    List<Table> syncTables, {
    required List<TableDefinition> tableDefinitions,
  }) {
    final signature = _signature(syncTables, tableDefinitions);
    const uuid = Uuid();
    return OfflineSyncSchema._(
      '${uuid.v5(Namespace.url.value, signature)}:'
      '${uuid.v5(Namespace.oid.value, signature)}',
      Set.unmodifiable(syncTables.map((table) => table.tableName)),
    );
  }

  const OfflineSyncSchema._(this.hash, this.tableNames);

  /// The fixed-size schema identity used by `OfflineSyncConnect.syncTablesHash`.
  final String hash;

  /// Generated synchronized table names, detached from the caller's list.
  final Set<String> tableNames;

  /// Whether [tableName] belongs to the synchronized schema.
  bool containsTable(String tableName) => tableNames.contains(tableName);

  /// Compares a preflight hash obtained from the server, if available.
  OfflineSyncSchemaCompatibility comparePeerHash(String? peerHash) {
    if (peerHash == null || peerHash.isEmpty) {
      return OfflineSyncSchemaCompatibility.unknown;
    }
    return peerHash == hash
        ? OfflineSyncSchemaCompatibility.compatible
        : OfflineSyncSchemaCompatibility.mismatch;
  }

  /// Requires the stream peer's exact hash. An empty hash is not accepted.
  void requirePeerHash(String peerHash) {
    if (peerHash != hash) {
      throw OfflineSyncTablesHashMismatchException(
        received: peerHash,
        expected: hash,
      );
    }
  }

  // Keep the canonical signature byte-for-byte compatible with the original
  // engine implementation. Changing it would reject already deployed peers.
  static String _signature(
    List<Table> syncTables,
    List<TableDefinition> tableDefinitions,
  ) {
    final definitionsByName = {
      for (final definition in tableDefinitions) definition.name: definition,
    };
    final sortedTables = syncTables.toList()
      ..sort((left, right) => left.tableName.compareTo(right.tableName));
    return sortedTables
        .map((table) {
          final definition = definitionsByName[table.tableName];
          final columns = [
            if (definition != null)
              for (final column in definition.columns)
                if (column.name != 'spaceId')
                  _columnIdentity(definition, column)
                else
                  for (final column in table.columns)
                    if (column.columnName != 'spaceId') column.columnName,
          ]..sort();
          final foreignKeys = _foreignKeys(definition);
          final uniqueIndexes = _uniqueIndexes(definition);
          return '${table.tableName}:'
              '${columns.join(',')}|'
              'fk[${foreignKeys.join(';')}]|'
              'uq[${uniqueIndexes.join(';')}]';
        })
        .join(';');
  }

  static String _columnIdentity(TableDefinition table, ColumnDefinition column) {
    final releaseKind = crdtUniqueConflictReleaseKindForColumn(table, column);
    return '${column.name}:${column.columnType.name}:${column.dartType}:'
        '${column.isNullable}:${releaseKind?.name ?? '-'}';
  }

  static List<String> _foreignKeys(TableDefinition? definition) {
    if (definition == null) return const [];
    return <String>[
      for (final fk in definition.foreignKeys)
        // Each foreign key must map all parameters.
        // ignore: no_adjacent_strings_in_list
        '${(fk.columns.toList()..sort()).join(',')}->'
            '${fk.referenceTableSchema}.${fk.referenceTable}'
            '(${(fk.referenceColumns.toList()..sort()).join(',')})'
            '|u:${fk.onUpdate?.toString() ?? '-'}'
            '|d:${fk.onDelete?.toString() ?? '-'}'
            '|m:${fk.matchType?.toString() ?? '-'}',
    ]..sort();
  }

  static List<String> _uniqueIndexes(TableDefinition? definition) {
    if (definition == null) return const [];
    return <String>[
      for (final index in definition.indexes)
        if (index.isUnique && !index.isPrimary)
          () {
            final elements = [
              for (final element in index.elements)
                '${element.type}:${element.definition}',
            ]..sort();
            return elements.join(',');
          }(),
    ]..sort();
  }
}
