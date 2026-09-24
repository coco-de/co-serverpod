import 'dart:io';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:test/test.dart';

import 'test_tools/embedded_postgres.dart';
import 'test_tools/serverpod_test_tools.dart';

void main() {
  final serverDirectory = Directory(
    '${Directory.systemTemp.path}/offline_sync_updates_${const Uuid().v4()}',
  );
  setUpAll(() async {
    await preparePostgresMigrations(serverDirectory);
  });

  tearDownAll(() async {
    if (serverDirectory.existsSync()) await serverDirectory.delete(recursive: true);
  });

  withServerpod(
    'PostgreSQL untracked updates with the database interceptor',
    (sessionBuilder, _) {
      late Session session;

      setUp(() {
        sessionBuilder.build().serverpod.initializeOfflineSync(syncTables: []);
        session = sessionBuilder.build();
      });

      group('Given an ordinary row in the test harness transaction,', () {
        late ServerHealthMetric metric;

        setUp(() async {
          metric = await ServerHealthMetric.db.insertRow(
            session,
            ServerHealthMetric(
              name: 'original',
              serverId: 'test server',
              timestamp: DateTime.utc(2026),
              isHealthy: true,
              value: 1,
              granularity: 1,
            ),
          );
        });

        group('when updateRow changes its name,', () {
          setUp(() async {
            await ServerHealthMetric.db.updateRow(
              session,
              metric.copyWith(name: 'updated'),
            );
          });

          test('then the change is visible in the test transaction.', () async {
            final stored = await ServerHealthMetric.db.findById(session, metric.id!);
            expect(stored?.name, 'updated');
          });
        });
      });
    },
    databaseInterceptor: offlineSyncDatabaseInterceptor,
    serverDirectory: serverDirectory,
    configOverride: (config) => config.copyWith(
      apiServer: ServerConfig(
        port: 0,
        publicHost: 'localhost',
        publicPort: 0,
        publicScheme: 'http',
      ),
      database: embeddedPostgresConfig(),
    ),
  );
}
