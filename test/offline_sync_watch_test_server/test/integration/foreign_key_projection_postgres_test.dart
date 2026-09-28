import 'dart:io';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart'
    as device;
import 'package:offline_sync_watch_test_server/src/generated/sync_tables.dart'
    as server_tables;
import 'package:path/path.dart' as p;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:test/test.dart';

// The scenarios and the golden format are the SQLite fixture's, run here
// against a PostgreSQL server.
import '../../../offline_sync_watch_test_client/test/support/foreign_key_projection_golden.dart';
import 'support/dialect_zones.dart';
import 'test_tools/embedded_postgres.dart';
import 'test_tools/serverpod_test_tools.dart';

/// Foreign key projection writes what it wrote before co-serverpod#41, with a
/// PostgreSQL server (see [defineForeignKeyProjectionGolden]).
///
/// The fix changed the SQL a server pass runs: a reached row's columns are
/// read in two sets, and the rows holding an attempted value on an unread
/// column are found through the attempted value, field, row and column
/// relations. PostgreSQL returns `bytea` and `uuid` values of its own types
/// and plans those queries differently from SQLite, so the SQLite golden does
/// not cover it. The server here is a real server database: no persistent
/// user, a node per space, as the Serverpod server runs it. It does not write
/// locally, so the random writes run on the devices only.
///
/// The devices are SQLite, as they are in production, in the same isolate as
/// the server: see [DialectValueEncoder] for what that takes.
///
/// The golden was recorded with the projector before the fix (co-serverpod
/// 28fa128). Run with `FK41_WRITE_GOLDEN=1` to record it again, which is only
/// valid on a projector known to be correct.
void main() {
  final postgres = TestPostgres('fk41');
  setUpAll(postgres.prepare);
  tearDownAll(postgres.dispose);

  late Directory tempDir;
  final client = device.Client('http://localhost:1/');
  var databaseCount = 0;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_fk41_pg_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  withServerpod(
    'PostgreSQL foreign key projection',
    (sessionBuilder, _) {
      setUp(() => DialectValueEncoder.replacements = 0);
      tearDown(() {
        expect(
          DialectValueEncoder.replacements,
          0,
          reason: 'a query may have been encoded for the wrong dialect',
        );
      });

      defineForeignKeyProjectionGolden(
        goldenFile: File(
          'test/integration/goldens/foreign_key_projection_postgres.json',
        ),
        target: _PostgresTarget(
          openServerDatabase: () async {
            final raw = sessionBuilder.build();
            DialectValueEncoder.capture(DatabaseDialect.postgres);
            // Each scenario starts from an empty server, so the state it
            // compares is its own.
            final tables = await raw.db.unsafeQuery(
              "SELECT tablename FROM pg_tables WHERE schemaname = 'public' "
              "AND tablename NOT LIKE 'serverpod_%'",
            );
            final names = [for (final row in tables) '"${row.first}"'];
            await raw.db.unsafeExecute(
              'TRUNCATE ${names.join(', ')} RESTART IDENTITY CASCADE',
            );
            final server = OfflineSyncDatabaseSession(
              ZonedDatabase(raw.db),
              syncTables: server_tables.syncTables,
            );
            await DialectValueEncoder.zoneFor(
              DatabaseDialect.postgres,
            ).run(server.db.initialize);
            return server;
          },
          openDeviceDatabase: (userId) async {
            final session = await client.createSession(
              p.join(tempDir.path, 'device-${++databaseCount}.db'),
            );
            DialectValueEncoder.capture(DatabaseDialect.sqlite);
            final offline = OfflineSyncDatabaseSession.wraps(
              session,
              syncTables: device.syncTables,
              persistentUserId: userId,
            );
            addTearDown(offline.close);
            await DialectValueEncoder.zoneFor(
              DatabaseDialect.sqlite,
            ).run(offline.db.initialize);
            return offline;
          },
        ),
      );
    },
    rollbackDatabase: RollbackDatabase.disabled,
    serverDirectory: postgres.serverDirectory,
    configOverride: (config) => config.copyWith(
      apiServer: ServerConfig(
        port: 0,
        publicHost: 'localhost',
        publicPort: 0,
        publicScheme: 'http',
      ),
      database: postgres.config(maxConnectionCount: 8),
    ),
  );
}

final class _PostgresTarget implements ForeignKeyProjectionTarget {
  _PostgresTarget({
    required this.openServerDatabase,
    required this.openDeviceDatabase,
  });

  final Future<OfflineSyncDatabaseSession> Function() openServerDatabase;
  final Future<OfflineSyncDatabaseSession> Function(UuidValue userId)
  openDeviceDatabase;

  final _offline = Expando<OfflineSyncDatabaseSession>();

  Future<DatabaseSession> _zoned(
    Future<OfflineSyncDatabaseSession> opening,
  ) async {
    final offline = await opening;
    final zoned = ZonedSession(offline);
    _offline[zoned] = offline;
    return zoned;
  }

  @override
  Future<DatabaseSession> openServer(UuidValue userId) =>
      _zoned(openServerDatabase());

  @override
  Future<DatabaseSession> openDevice(UuidValue userId) =>
      _zoned(openDeviceDatabase(userId));

  @override
  Future<void> sync(
    DatabaseSession server,
    DatabaseSession device,
    UuidValue userId,
  ) {
    final serverZone = DialectValueEncoder.zoneFor(DatabaseDialect.postgres);
    final deviceZone = DialectValueEncoder.zoneFor(DatabaseDialect.sqlite);
    final serverSession = _offline[server]!;
    final client = OfflineSyncClient(({required changes, required once}) {
      final inbound = listenedIn(deviceZone, changes);
      return listenedIn(
        serverZone,
        serverZone.run(
          () => serverSession.db.sync(
            userId: userId,
            inbound: inbound,
            once: once,
            mode: OfflineSyncPeerMode.authoritative,
          ),
        ),
      );
    });
    return deviceZone
        .run(() => client.syncOnce(_offline[device]!))
        .timeout(const Duration(seconds: 60));
  }

  @override
  bool get serverWrites => false;
}
