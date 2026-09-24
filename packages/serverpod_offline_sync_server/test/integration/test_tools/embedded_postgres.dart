import 'dart:convert';
import 'dart:io';

import 'package:serverpod/serverpod.dart';
// Serverpod currently exposes its SQL generator only through this library.
// ignore: implementation_imports
import 'package:serverpod_cli/src/database/dialects/postgres.dart';
import 'package:serverpod_database/serverpod_database.dart' show DatabaseDefinition;
import 'package:serverpod_embedded_postgres/serverpod_embedded_postgres.dart';

/// An embedded PostgreSQL for one test file, with the server directory its
/// `withServerpod` group runs in.
///
/// Call [prepare] in `setUpAll` and [dispose] in `tearDownAll`.
/// `serverpod_test` starts the postmaster and leaves it running when the test
/// process ends, one per run, on a machine that may be a CI runner host.
/// [dispose] stops it and removes its directory.
///
/// Each file gets a postmaster of its own, so stopping it cannot pull the
/// database from under another file running at the same time. The postmaster
/// binds its socket in `<data directory>/../run`, so the directory is per file
/// and process: with the data directory right in the system temp directory,
/// every run bound `<temp>/run/.s.PGSQL.5432`, the socket of the postmaster an
/// earlier run left, and could not start. Keep the file's name short: a Unix
/// socket path holds about 100 bytes.
class TestPostgres {
  /// A PostgreSQL for the test file [name].
  TestPostgres(String name)
    : _root = Directory('${Directory.systemTemp.path}/offline_sync_pg_${name}_$pid');

  final Directory _root;

  Directory get _dataDirectory => Directory('${_root.path}/data');

  /// The server directory holding the migrations [prepare] renders.
  Directory get serverDirectory => Directory('${_root.path}/server');

  /// The database configuration for `withServerpod`'s `configOverride`.
  PostgresDatabaseConfig config({int maxConnectionCount = 5}) =>
      PostgresDatabaseConfig.embedded(
        dataPath: _dataDirectory.path,
        name: 'serverpod_test',
        maxConnectionCount: maxConnectionCount,
      );

  /// Renders the module's latest migration for PostgreSQL into
  /// [serverDirectory].
  Future<void> prepare() => _preparePostgresMigrations(serverDirectory);

  /// Stops the postmaster and removes the directory.
  Future<void> dispose() async {
    try {
      final postgres = await EmbeddedPostgres.attach(_dataDirectory);
      await postgres.stop();
    } on AttachException {
      // Not started, or already stopped.
    }
    if (_root.existsSync()) await _root.delete(recursive: true);
  }
}

/// Writes the module's latest migration, rendered for PostgreSQL, into
/// [serverDirectory]'s `migrations`.
///
/// The module's committed SQL targets SQLite. This renders the current
/// generated definition with the same PostgreSQL generator that
/// `serverpod create-migration` uses.
Future<void> _preparePostgresMigrations(Directory serverDirectory) async {
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
