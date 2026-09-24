import 'dart:async';
import 'dart:io';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:test/test.dart';

import 'test_tools/embedded_postgres.dart';
import 'test_tools/serverpod_test_tools.dart';

/// Node row locks per space on PostgreSQL (unibook#14218).
///
/// A merge first locks the node of its space (`FOR UPDATE`) and holds it until
/// its transaction ends. Upstream's server shared one node across all spaces,
/// so the merges of all users waited on that one row. Here space A's merge
/// holds its node row, stalled inside its transaction, while space B merges.
///
/// The module's test server has no synced tables. A change for a table outside
/// them still runs the merge transaction (the node lock, the node clock and the
/// space-node checkpoints) and only writes no domain row.
void main() {
  final serverDirectory = Directory(
    '${Directory.systemTemp.path}/offline_sync_space_nodes_${const Uuid().v4()}',
  );
  setUpAll(() => preparePostgresMigrations(serverDirectory));
  tearDownAll(() async {
    if (serverDirectory.existsSync()) await serverDirectory.delete(recursive: true);
  });

  withServerpod(
    'PostgreSQL space node locks',
    (sessionBuilder, _) {
      late Session raw;
      late OfflineSyncDatabaseSession server;

      setUp(() async {
        raw = sessionBuilder.build();
        await raw.db.unsafeExecute(
          'TRUNCATE offline_sync_spaces, crdt_nodes RESTART IDENTITY CASCADE',
        );
        // No persistent user: a server, which gives each space its own node.
        server = OfflineSyncDatabaseSession(raw.db, syncTables: []);
        await server.db.initialize();
      });

      test(
        'Given space A merging while it holds its node row, '
        'when space B merges, '
        'then space B finishes without waiting for space A.',
        () async {
          final spaceA = const Uuid().v7obj();
          final spaceB = const Uuid().v7obj();
          // Space A first, so its node is the lowest node row: the one every
          // space shared before.
          await server.db.currentNodeId(userId: spaceA);
          await server.db.currentNodeId(userId: spaceB);
          final nodeA = await _currentNodeOf(raw, spaceA);
          final nodeB = await _currentNodeOf(raw, spaceB);
          expect(nodeA, isNot(nodeB));

          // An open transaction inserts the remote node that space A's batch
          // names. Space A's merge locks its own node row, then waits on that
          // uncommitted insert, holding the lock.
          final remoteNodeOfA = const Uuid().v7obj();
          final inserted = Completer<void>();
          final release = Completer<void>();
          final blocker = raw.db
              .transaction<void>((transaction) async {
                await CrdtNode.db.insertRow(
                  raw,
                  CrdtNode(uuidNodeId: remoteNodeOfA),
                  transaction: transaction,
                );
                inserted.complete();
                await release.future;
                throw const _Rollback();
              })
              .then<Object?>((_) => null, onError: (Object error) => error);
          addTearDown(() async {
            if (!release.isCompleted) release.complete();
            await blocker;
          });
          await inserted.future;

          var mergeADone = false;
          final mergeA = server.db
              .mergeChanges([_change(spaceA, remoteNodeOfA)], spaceId: spaceA)
              .whenComplete(() => mergeADone = true);
          final mergeAResult = mergeA.then<Object?>(
            (_) => null,
            onError: (Object error) => error,
          );
          addTearDown(() async {
            if (!release.isCompleted) release.complete();
            await mergeAResult;
          });
          await _waitForLockWaits(raw, 1);
          expect(
            await _isRowLocked(raw, nodeA),
            isTrue,
            reason: "space A's merge transaction holds its node row",
          );

          await server.db
              .mergeChanges(
                [_change(spaceB, const Uuid().v7obj())],
                spaceId: spaceB,
              )
              .timeout(const Duration(seconds: 10));

          expect(
            mergeADone,
            isFalse,
            reason: 'space B finished while space A still held its node row',
          );
          release.complete();
          expect(await blocker, isA<_Rollback>());
          expect(await mergeAResult, isNull);
        },
      );
    },
    rollbackDatabase: RollbackDatabase.disabled,
    serverDirectory: serverDirectory,
    configOverride: (config) => config.copyWith(
      apiServer: ServerConfig(
        port: 0,
        publicHost: 'localhost',
        publicPort: 0,
        publicScheme: 'http',
      ),
      database: embeddedPostgresConfig(maxConnectionCount: 8),
    ),
  );
}

class _Rollback implements Exception {
  const _Rollback();
}

/// A change for a table outside the synced tables, in [spaceId], authored by
/// [nodeId].
CrdtMergeChange _change(UuidValue spaceId, UuidValue nodeId) => CrdtMergeUpdate(
  hlcDatetime: DateTime.now().toUtc(),
  hlcCounter: 0,
  uuidSpaceId: spaceId,
  tableName: 'untracked_table',
  uuidRowId: const Uuid().v7obj(),
  uuidNodeId: nodeId,
  columnName: 'value',
  value: 1,
);

Future<int> _currentNodeOf(Session session, UuidValue spaceId) async {
  final space = await OfflineSyncSpace.db.findFirstRow(
    session,
    where: (t) => t.uuidSpaceId.equals(spaceId),
  );
  return space!.currentNodeId!;
}

/// Whether another transaction holds a row lock on the node row [nodeId].
Future<bool> _isRowLocked(Session session, int nodeId) async {
  try {
    await session.db.unsafeQuery(
      'SELECT "id" FROM "crdt_nodes" WHERE "id" = $nodeId FOR UPDATE NOWAIT',
    );
    return false;
  } on DatabaseQueryException {
    return true;
  }
}

// Observe real lock waits rather than depending on a scheduling delay. The
// group owns an isolated database, and its tests run serially.
Future<void> _waitForLockWaits(Session session, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final result = await session.db.unsafeQuery(
      'SELECT count(*) FROM pg_stat_activity '
      "WHERE datname = current_database() AND wait_event_type = 'Lock'",
    );
    if ((result.single.single as int) >= count) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('$count transactions did not reach a database lock wait.');
}
