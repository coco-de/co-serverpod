import 'dart:convert';
import 'dart:io';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart'
    as fixture;
import 'package:path/path.dart' as p;
import 'package:serverpod_database/serverpod_database.dart'
    show
        ColumnType,
        IndexDefinition,
        IndexElementDefinition,
        IndexElementDefinitionType,
        Table,
        TableDefinition;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

import 'support/sync_harness.dart';

void main() {
  final definitions = fixture.Protocol().getTargetTableDefinitions();
  OfflineSyncSchema describe({
    List<Table<dynamic>>? tables,
    List<TableDefinition>? metadata,
  }) => OfflineSyncSchema.fromTables(
    tables ?? fixture.syncTables,
    tableDefinitions: metadata ?? definitions,
  );

  // Measured with the original engine before extracting its schema API.
  const legacyHash =
      '457eab4f-c2fe-5615-8d2f-8f33eb55eab4:0d4ead2a-9b71-5fdd-bc70-ce5a37a76ee6';
  final schema = describe();

  test('generated schema preserves the deployed handshake hash', () {
    expect(schema.hash, legacyHash);
    expect(
      OfflineSyncEngine.computeSyncTablesHash(
        fixture.syncTables,
        tableDefinitions: definitions,
      ),
      legacyHash,
    );
    expect(schema.tableNames, {'attachment', 'folder', 'note', 'stroke'});
    expect(schema.containsTable(fixture.Note.t.tableName), isTrue);
    expect(schema.containsTable('serverpod_session_log'), isFalse);
  });

  test('input order and non-sync tables do not change the hash', () {
    final reordered = definitions.reversed
        .map(
          (table) => table.copyWith(
            columns: table.columns.reversed.toList(),
            foreignKeys: table.foreignKeys.reversed.toList(),
            indexes: table.indexes.reversed.toList(),
          ),
        )
        .toList();
    expect(
      describe(
        tables: fixture.syncTables.reversed.toList(),
        metadata: reordered,
      ).hash,
      legacyHash,
    );
    expect(
      describe(
        metadata: definitions
            .where((table) => schema.containsTable(table.name))
            .toList(),
      ).hash,
      legacyHash,
    );
  });

  test('the generated table list is an immutable snapshot', () {
    final tables = fixture.syncTables.toList();
    final snapshot = describe(tables: tables);
    tables.clear();
    expect(snapshot.tableNames, hasLength(4));
    expect(() => snapshot.tableNames.clear(), throwsUnsupportedError);
    expect(snapshot.hash, legacyHash);
  });

  test(
    'table, column, nullability and foreign-key changes are detected automatically',
    () {
      final noteName = fixture.Note.t.tableName;
      final note = definitions.singleWhere((table) => table.name == noteName);
      final title = note.columns.singleWhere(
        (column) => column.name == 'title',
      );
      for (final changed in [
        note.copyWith(
          columns: note.columns
              .where((column) => column.name != 'title')
              .toList(),
        ),
        note.copyWith(
          columns: [
            ...note.columns,
            title.copyWith(name: 'memo'),
          ],
        ),
        note.copyWith(
          columns: note.columns
              .map(
                (column) => column.name == 'title'
                    ? column.copyWith(isNullable: !column.isNullable)
                    : column,
              )
              .toList(),
        ),
        note.copyWith(
          columns: note.columns
              .map(
                (column) => column.name == 'title'
                    ? column.copyWith(
                        columnType: ColumnType.bigint,
                        dartType: 'int',
                      )
                    : column,
              )
              .toList(),
        ),
        note.copyWith(foreignKeys: []),
        note.copyWith(
          indexes: [
            ...note.indexes,
            IndexDefinition(
              indexName: 'note_title_unique',
              elements: [
                IndexElementDefinition(
                  type: IndexElementDefinitionType.column,
                  definition: 'title',
                ),
              ],
              type: 'btree',
              isUnique: true,
              isPrimary: false,
            ),
          ],
        ),
      ]) {
        final newSchema = describe(
          metadata: definitions
              .map((table) => table.name == noteName ? changed : table)
              .toList(),
        );
        expect(
          newSchema.comparePeerHash(legacyHash),
          OfflineSyncSchemaCompatibility.mismatch,
        );
      }
      expect(
        describe(
          tables: fixture.syncTables
              .where((table) => table.tableName != noteName)
              .toList(),
        ).hash,
        isNot(legacyHash),
      );
    },
  );

  test(
    'a preflight does not infer schema age or accept a missing handshake hash',
    () {
      expect(
        schema.comparePeerHash(legacyHash),
        OfflineSyncSchemaCompatibility.compatible,
      );
      expect(
        schema.comparePeerHash('different'),
        OfflineSyncSchemaCompatibility.mismatch,
      );
      expect(
        schema.comparePeerHash(null),
        OfflineSyncSchemaCompatibility.unknown,
      );
      expect(
        schema.comparePeerHash(''),
        OfflineSyncSchemaCompatibility.unknown,
      );
      expect(
        () => schema.requirePeerHash(''),
        throwsA(isA<OfflineSyncTablesHashMismatchException>()),
      );
    },
  );

  late Directory temp;
  final client = fixture.Client('http://localhost:1/');
  var count = 0;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('offline_sync_settings_');
  });
  tearDownAll(() async {
    client.close();
    await temp.delete(recursive: true);
  });

  Future<OfflineSyncDatabaseSession> open({
    UuidValue? userId,
    OfflineSyncSettings? settings,
    List<Table<dynamic>>? tables,
  }) async {
    final raw = await client.createSession(
      p.join(temp.path, 'replica-${++count}.db'),
    );
    final session = OfflineSyncDatabaseSession.wrapsWithSettings(
      raw,
      syncTables: tables ?? fixture.syncTables,
      persistentUserId: userId,
      settings: settings,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  test(
    'a client opens with the paired preset and exposes metadata without constants',
    () async {
      final session = await open(userId: const Uuid().v7obj());
      expect(session.db.syncSchema.hash, legacyHash);
      expect(session.db.syncSchema.tableNames, schema.tableNames);
      expect(session.db.maxClockDrift, const Duration(hours: 1));
      expect(session.db.batchBudget.maxChanges, 5000);
      expect(
        () => OfflineSyncSettings.boundedClient.requireMatches(
          session.db.syncSettings,
        ),
        returnsNormally,
      );
      final nested = OfflineSyncDatabaseSession.wrapsWithSettings(
        session,
        syncTables: fixture.syncTables,
      );
      expect(nested.db, same(session.db));
      await nested.close();
      await session.close();
    },
  );

  test(
    'an existing wrapper cannot silently discard settings, schema or identity',
    () async {
      final user = const Uuid().v7obj();
      final session = await open(userId: user);
      expect(
        () => OfflineSyncDatabaseSession.wrapsWithSettings(
          session,
          syncTables: fixture.syncTables,
          settings: OfflineSyncSettings.boundedClient.copyWith(
            syncBatchSize: 1,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => OfflineSyncDatabaseSession.wrapsWithSettings(
          session,
          syncTables: [fixture.Note.t],
        ),
        throwsA(isA<OfflineSyncTablesHashMismatchException>()),
      );
      expect(
        () => OfflineSyncDatabaseSession.wrapsWithSettings(
          session,
          syncTables: fixture.syncTables,
          persistentUserId: const Uuid().v7obj(),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'JSON budgets split real typed-model changes and confirm all rows',
    () async {
      final user = const Uuid().v7obj();
      final server = await open(settings: OfflineSyncSettings.boundedServer);
      final device = await open(
        userId: user,
        settings: OfflineSyncSettings.boundedClient.copyWith(
          syncBatchSize: 1,
          batchBudget: OfflineSyncBatchBudget.json(maxPayloadChars: 1000),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await fixture.Note.db.insertRow(
          device,
          fixture.Note(title: '$i${'한글🩺' * 20}'),
        );
      }
      final batchSizes = <int>[];
      var currentBatch = 0;
      var largestChunk = 0;
      await peerOf(
        server,
        userId: user,
        mapDeviceEvent: (event) {
          if (event is OfflineSyncMergeChunk) {
            if (event.changes.length > largestChunk) {
              largestChunk = event.changes.length;
            }
            for (final change in event.changes) {
              currentBatch += OfflineSyncBatchBudget.measureJsonPayload(change);
            }
          }
          if (event is OfflineSyncEndOfBatch && currentBatch > 0) {
            batchSizes.add(currentBatch);
            currentBatch = 0;
          }
          return event;
        },
      ).syncOnce(device);
      expect(batchSizes.length, greaterThan(1));
      expect(batchSizes, everyElement(lessThanOrEqualTo(1000)));
      expect(largestChunk, 1);
      expect(await fixture.Note.db.count(server), 5);
      expect(await device.db.unsentRowCount(), 0);
    },
  );

  test(
    'schema mismatch sends no changes and keeps local writes unsent',
    () async {
      final user = const Uuid().v7obj();
      final server = await open(
        settings: OfflineSyncSettings.boundedServer,
        tables: [fixture.Folder.t],
      );
      final device = await open(userId: user);
      await fixture.Note.db.insertRow(
        device,
        fixture.Note(title: 'keep this draft'),
      );
      final sent = <CrdtMergeChange>[];
      final error = await errorOf(
        peerOf(server, userId: user, sent: sent).syncOnce(device),
      );
      expect(error, isA<OfflineSyncTablesHashMismatchException>());
      expect(sent, isEmpty);
      expect(await device.db.unsentRowCount(), 1);
      expect(
        (await fixture.Note.db.find(device)).single.title,
        'keep this draft',
      );
    },
  );

  test(
    'the JSON budget measures the protocol envelope and supports Unicode model data',
    () {
      final id = const Uuid().v7obj();
      final change = CrdtMergeInsert(
        hlcDatetime: DateTime.utc(2026),
        hlcCounter: 1,
        uuidSpaceId: id,
        uuidNodeId: id,
        uuidRowId: id,
        tableName: fixture.Note.t.tableName,
        data: fixture.Note(id: id, title: '한글🩺'),
      );
      final wire = jsonEncode(change.toJsonForProtocol());
      expect(OfflineSyncBatchBudget.measureJsonPayload(change), wire.length);
      expect(
        OfflineSyncBatchBudget.measureJsonPayload(change),
        greaterThan(jsonEncode({'title': '한글🩺'}).length),
      );
      expect(
        () => OfflineSyncBatchBudget.json(maxPayloadChars: 0),
        throwsArgumentError,
      );
    },
  );
}
