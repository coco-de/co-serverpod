import 'dart:async';

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
/// A server database written before has its spaces on one node, and each
/// leaves it on its next use. That move locks the space's row and then the
/// node: it must not wait on a merge that only references the space, and
/// sessions moving at once must neither give a space two nodes nor leave the
/// node without a space.
///
/// The module's test server has no synced tables. A change for a table outside
/// them still runs the merge transaction (the node lock, the node clock and the
/// space-node checkpoints) and only writes no domain row.
void main() {
  final postgres = TestPostgres('nodes');
  setUpAll(postgres.prepare);
  tearDownAll(postgres.dispose);

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

      /// Another server session: a database of its own, knowing no space yet.
      OfflineSyncDatabase anotherSession() =>
          OfflineSyncDatabaseSession(raw.db, syncTables: []).db;

      /// Gives [spaceIds] a node each, then points them at one new node, as a
      /// server database written before unibook#14218 has them. Returns the
      /// shared node's id.
      Future<int> shareOneNode(List<UuidValue> spaceIds) async {
        final shared = await CrdtNode.db.insertRow(
          raw,
          CrdtNode(uuidNodeId: const Uuid().v7obj()),
        );
        for (final spaceId in spaceIds) {
          await server.db.currentNodeId(userId: spaceId);
          await OfflineSyncSpace.db.updateRow(
            raw,
            (await _spaceOf(raw, spaceId)).copyWith(currentNodeId: shared.id),
            columns: (t) => [t.currentNodeId],
          );
        }
        return shared.id!;
      }

      /// Runs a transaction that holds what [lock] takes until [release]
      /// completes, then rolls back. Returns once it holds it; the future it
      /// adds to [holding] completes with the transaction's error.
      Future<void> holdIn(
        Future<void> Function(Transaction transaction) lock,
        Completer<void> release,
        List<Future<Object?>> holding,
      ) async {
        final held = Completer<void>();
        holding.add(
          raw.db
              .transaction<void>((transaction) async {
                await lock(transaction);
                held.complete();
                await release.future;
                throw const _Rollback();
              })
              .then<Object?>((_) => null, onError: (Object error) => error),
        );
        await held.future;
      }

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
            await _isRowLocked(raw, 'crdt_nodes', nodeA),
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

      test(
        'Given a space on a shared node that a merge references, '
        'when the space leaves the node, '
        'then it does not wait for that merge.',
        () async {
          final spaceX = const Uuid().v7obj();
          final sharedId = await shareOneNode([spaceX, const Uuid().v7obj()]);
          final spaceRow = (await _spaceOf(raw, spaceX)).id!;
          final deviceNode = await CrdtNode.db.insertRow(
            raw,
            CrdtNode(uuidNodeId: const Uuid().v7obj()),
          );
          // Inserting a row that references the space takes FOR KEY SHARE on
          // its row until the transaction ends. A merge into the space by a
          // server of the version before does that while it holds the shared
          // node, which the move locks next.
          final release = Completer<void>();
          final holding = <Future<Object?>>[];
          addTearDown(() async {
            if (!release.isCompleted) release.complete();
            await Future.wait(holding);
          });
          await holdIn(
            (transaction) => OfflineSyncSpaceNode.db.insertRow(
              raw,
              OfflineSyncSpaceNode(spaceId: spaceRow, nodeId: deviceNode.id!),
              transaction: transaction,
            ),
            release,
            holding,
          );
          expect(
            await _isRowLocked(raw, 'offline_sync_spaces', spaceRow),
            isTrue,
            reason: 'the merge holds a lock FOR UPDATE on the space waits for',
          );

          await anotherSession()
              .currentNodeId(userId: spaceX)
              .timeout(const Duration(seconds: 10));

          expect((await _spaceOf(raw, spaceX)).currentNodeId, isNot(sharedId));
          release.complete();
          expect(await holding.single, isA<_Rollback>());
        },
      );

      test(
        'Given a space on a shared node, '
        'when two sessions move it off the node at once, '
        'then it gets one node of its own.',
        () async {
          final spaceX = const Uuid().v7obj();
          final spaceY = const Uuid().v7obj();
          final sharedId = await shareOneNode([spaceX, spaceY]);
          final spaceRow = (await _spaceOf(raw, spaceX)).id!;
          final nodesBefore = await CrdtNode.db.count(raw);
          // Hold the space's row, so both sessions find the space on the
          // shared node and queue for its row.
          final release = Completer<void>();
          final holding = <Future<Object?>>[];
          addTearDown(() async {
            if (!release.isCompleted) release.complete();
            await Future.wait(holding);
          });
          await holdIn(
            (transaction) => OfflineSyncSpace.db.lockRows(
              raw,
              where: (t) => t.id.equals(spaceRow),
              lockMode: LockMode.forUpdate,
              transaction: transaction,
            ),
            release,
            holding,
          );
          final moves = [
            anotherSession().currentNodeId(userId: spaceX),
            anotherSession().currentNodeId(userId: spaceX),
          ];
          await _waitForLockWaits(raw, 2);
          release.complete();

          final nodes = await Future.wait(
            moves,
          ).timeout(const Duration(seconds: 10));

          expect(nodes.toSet(), hasLength(1));
          expect(await CrdtNode.db.count(raw), nodesBefore + 1);
          expect((await _spaceOf(raw, spaceY)).currentNodeId, sharedId);
          expect(await holding.single, isA<_Rollback>());
        },
      );

      test(
        'Given two spaces on a shared node, '
        'when both move off it at once, '
        'then the one that moves last keeps it.',
        () async {
          final spaceB = const Uuid().v7obj();
          final spaceC = const Uuid().v7obj();
          final sharedId = await shareOneNode([spaceB, spaceC]);
          final nodesBefore = await CrdtNode.db.count(raw);
          // Hold the shared node's row, so both sessions lock their own space
          // and queue for the node.
          final release = Completer<void>();
          final holding = <Future<Object?>>[];
          addTearDown(() async {
            if (!release.isCompleted) release.complete();
            await Future.wait(holding);
          });
          await holdIn(
            (transaction) => CrdtNode.db.findById(
              raw,
              sharedId,
              lockMode: LockMode.forUpdate,
              transaction: transaction,
            ),
            release,
            holding,
          );
          final moves = [
            anotherSession().currentNodeId(userId: spaceB),
            anotherSession().currentNodeId(userId: spaceC),
          ];
          await _waitForLockWaits(raw, 2);
          release.complete();

          await Future.wait(moves).timeout(const Duration(seconds: 10));

          final onShared = [
            for (final spaceId in [spaceB, spaceC])
              if ((await _spaceOf(raw, spaceId)).currentNodeId == sharedId) spaceId,
          ];
          expect(onShared, hasLength(1));
          expect(await CrdtNode.db.count(raw), nodesBefore + 1);
          expect(await holding.single, isA<_Rollback>());
        },
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

Future<OfflineSyncSpace> _spaceOf(Session session, UuidValue spaceId) async {
  final space = await OfflineSyncSpace.db.findFirstRow(
    session,
    where: (t) => t.uuidSpaceId.equals(spaceId),
  );
  return space!;
}

Future<int> _currentNodeOf(Session session, UuidValue spaceId) async =>
    (await _spaceOf(session, spaceId)).currentNodeId!;

/// Whether another transaction holds a lock on the row [id] of [table] that
/// `FOR UPDATE` waits for.
Future<bool> _isRowLocked(Session session, String table, int id) async {
  try {
    await session.db.unsafeQuery(
      'SELECT "id" FROM "$table" WHERE "id" = $id FOR UPDATE NOWAIT',
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
