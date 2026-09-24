import 'dart:convert';
import 'dart:io';

import 'package:serverpod/serverpod.dart';
// Serverpod currently exposes its SQL generator only through this library.
// ignore: implementation_imports
import 'package:serverpod_cli/src/database/dialects/postgres.dart';
import 'package:serverpod_database/serverpod_database.dart' show DatabaseDefinition;

/// This process's embedded PostgreSQL, shared by every integration test file
/// that needs PostgreSQL. Each `withServerpod` group gets its own database on it.
///
/// The postmaster binds its socket in `<data directory>/../run`, and
/// `serverpod_test` leaves it running when the test process ends. With the data
/// directory right in the system temp directory, every run shared
/// `<temp>/run/.s.PGSQL.5432` with the postmaster an earlier run left, and the
/// new one could not start ("Serverpod did not start within the timeout").
/// A parent directory per process keeps the socket apart.
PostgresDatabaseConfig embeddedPostgresConfig({int maxConnectionCount = 5}) =>
    PostgresDatabaseConfig.embedded(
      dataPath: '${Directory.systemTemp.path}/offline_sync_postgres_$pid/data',
      name: 'serverpod_test',
      maxConnectionCount: maxConnectionCount,
    );

/// Writes the module's latest migration, rendered for PostgreSQL, into
/// [serverDirectory]'s `migrations`.
///
/// The module's committed SQL targets SQLite. This renders the current
/// generated definition with the same PostgreSQL generator that
/// `serverpod create-migration` uses.
Future<void> preparePostgresMigrations(Directory serverDirectory) async {
  final versions = await File('migrations/migration_registry.txt').readAsLines();
  final version = versions.lastWhere((line) => line.trim().isNotEmpty);
  final source = Directory('migrations/$version');
  final target = Directory('${serverDirectory.path}/migrations/$version');
  await target.create(recursive: true);
  await for (final file in source.list()) {
    if (file is File) {
      await file.copy('${target.path}/${file.uri.pathSegments.last}');
    }
  }
  final definition = DatabaseDefinition.fromJson(
    jsonDecode(await File('${target.path}/definition.json').readAsString())
        as Map<String, dynamic>,
  );
  final sql = definition.toPgSql(installedModules: definition.installedModules);
  await File('${target.path}/definition.sql').writeAsString(sql);
  await File('${target.path}/migration.sql').writeAsString(sql);
  await File(
    '${serverDirectory.path}/migrations/migration_registry.txt',
  ).writeAsString('$version\n');
}
