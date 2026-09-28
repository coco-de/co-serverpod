import 'dart:io';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:serverpod_database/serverpod_database.dart'
    show DatabaseSession;
import 'package:test/test.dart';

import 'support/foreign_key_projection_golden.dart';
import 'support/sync_harness.dart';

/// Foreign key projection writes what it wrote before co-serverpod#41, with a
/// SQLite server (see [defineForeignKeyProjectionGolden]).
///
/// The server here is a client database acting as the authoritative peer, as
/// the other fixture tests use it. `offline_sync_watch_test_server` runs the
/// same scenarios on a PostgreSQL server.
void main() {
  late Directory tempDir;
  final client = Client('http://localhost:1/');
  var databaseCount = 0;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_fk41_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  Future<OfflineSyncDatabaseSession> openReplica(UuidValue userId) async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(
        p.join(tempDir.path, 'replica-${++databaseCount}.db'),
      ),
      syncTables: syncTables,
      persistentUserId: userId,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  defineForeignKeyProjectionGolden(
    goldenFile: File('test/goldens/foreign_key_projection_equivalence.json'),
    target: _SqliteTarget(openReplica),
  );
}

final class _SqliteTarget implements ForeignKeyProjectionTarget {
  _SqliteTarget(this._open);

  final Future<OfflineSyncDatabaseSession> Function(UuidValue userId) _open;

  @override
  Future<OfflineSyncDatabaseSession> openServer(UuidValue userId) =>
      _open(userId);

  @override
  Future<OfflineSyncDatabaseSession> openDevice(UuidValue userId) =>
      _open(userId);

  @override
  Future<void> sync(
    DatabaseSession server,
    DatabaseSession device,
    UuidValue userId,
  ) => peerOf(server as OfflineSyncDatabaseSession)
      .syncOnce(device as OfflineSyncDatabaseSession)
      .timeout(const Duration(seconds: 30));

  @override
  bool get serverWrites => true;
}
