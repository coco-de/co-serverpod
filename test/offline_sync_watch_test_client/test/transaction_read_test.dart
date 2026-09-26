import 'dart:async';
import 'dart:io';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

/// Reads inside a transaction on real SQLite (unibook#14256).
///
/// A CRDT read ANDs a space predicate built from the reader's memberships, so
/// every `find`, `findFirstRow`, `findById` and `count` queries the membership
/// tables first. Upstream ran that query without the caller's transaction.
///
/// On SQLite a query without a transaction only escapes the open write lock
/// through the parent zone the adapter records when a transaction starts, and
/// that record is one field shared by every transaction of the connection: the
/// transaction that finishes first clears it while a transaction queued behind
/// it still waits for the lock. Once that one runs, its membership query runs
/// in the zone of its own write lock and sqlite_async refuses it with
/// `LockError: Recursive lock is not allowed`. Two overlapping transactions are
/// the condition, which is why an app right after sign-in (sync and local
/// writes starting together) hit it and one transaction at a time did not.
///
/// | Case | Expected |
/// |---|---|
/// | A read in a transaction queued behind another | Reads the rows, no `LockError` |
/// | The same on a server, in [OfflineSyncDatabase.transactionForUser] | Reads the rows, no `LockError` |
/// | Every read API in a queued transaction | All four read the rows |
/// | A shared space joined inside the transaction, read in it | The read covers the new space |
void main() {
  late Directory tempDir;
  final client = Client('http://localhost:1/');
  var databaseCount = 0;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_tx_read_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  String newPath() => p.join(tempDir.path, 'replica-${++databaseCount}.db');

  Future<OfflineSyncDatabaseSession> openDevice(UuidValue userId) async {
    final session = await client.createSyncSession(
      newPath(),
      persistentUserId: userId,
    );
    addTearDown(session.close);
    return session;
  }

  Future<OfflineSyncDatabaseSession> openServer() async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(newPath()),
      syncTables: syncTables,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  /// Runs [second] in a transaction started while [first] still holds the
  /// write lock, so [second] waits for the lock and runs after [first]
  /// committed, the way a sync and a local write overlap after sign-in.
  Future<R> queuedBehindAnother<R>(
    Future<void> Function(Future<void> Function() hold) first,
    Future<R> Function() second,
  ) async {
    final started = Completer<void>();
    final release = Completer<void>();
    final firstDone = first(() {
      started.complete();
      return release.future;
    });
    await started.future;
    final secondDone = second();
    // Let the second transaction reach the lock queue before the first ends.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    release.complete();
    await firstDone;
    return secondDone;
  }

  group('Given a device,', () {
    test(
      'should_read_in_a_transaction_that_waited_for_another_to_commit',
      () async {
        final userId = const Uuid().v7obj();
        final device = await openDevice(userId);
        await Note.db.insertRow(device, Note(title: 'seed'));

        final titles = await queuedBehindAnother(
          (hold) => device.db.transaction((transaction) async {
            await Note.db.insertRow(
              device,
              Note(title: 'first'),
              transaction: transaction,
            );
            await hold();
          }),
          () => device.db.transaction(
            (transaction) async => [
              for (final note in await Note.db.find(
                device,
                orderBy: (t) => t.title,
                transaction: transaction,
              ))
                note.title,
            ],
          ),
        );

        expect(titles, ['first', 'seed']);
      },
    );

    test(
      'should_read_with_every_read_api_in_a_transaction_that_waited_for_another',
      () async {
        final userId = const Uuid().v7obj();
        final device = await openDevice(userId);
        final seed = await Note.db.insertRow(device, Note(title: 'seed'));

        final reads = await queuedBehindAnother(
          (hold) => device.db.transaction((transaction) async {
            await Note.db.insertRow(
              device,
              Note(title: 'first'),
              transaction: transaction,
            );
            await hold();
          }),
          () => device.db.transaction(
            (transaction) async => (
              found: await Note.db.find(device, transaction: transaction),
              first: await Note.db.findFirstRow(
                device,
                where: (t) => t.title.equals('seed'),
                transaction: transaction,
              ),
              byId: await Note.db.findById(
                device,
                seed.id!,
                transaction: transaction,
              ),
              count: await Note.db.count(device, transaction: transaction),
            ),
          ),
        );

        expect(reads.found, hasLength(2));
        expect(reads.first?.title, 'seed');
        expect(reads.byId?.title, 'seed');
        expect(reads.count, 2);
      },
    );
  });

  group('Given a server,', () {
    test(
      'should_read_in_a_user_transaction_that_waited_for_another_to_commit',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openServer();
        await server.db.transactionForUser(
          userId,
          (transaction) => Note.db.insertRow(
            server,
            Note(title: 'seed'),
            transaction: transaction,
          ),
        );

        final titles = await queuedBehindAnother(
          (hold) => server.db.transactionForUser(userId, (transaction) async {
            await Note.db.insertRow(
              server,
              Note(title: 'first'),
              transaction: transaction,
            );
            await hold();
          }),
          () => server.db.transactionForUser(
            userId,
            (transaction) async => [
              for (final note in await Note.db.find(
                server,
                orderBy: (t) => t.title,
                transaction: transaction,
              ))
                note.title,
            ],
          ),
        );

        expect(titles, ['first', 'seed']);
      },
    );

    // The membership query is part of the transaction, so it sees a membership
    // written earlier in the same transaction. Outside it, the query would read
    // the committed membership and miss the space.
    test(
      'should_cover_a_space_joined_earlier_in_the_same_transaction',
      () async {
        final userId = const Uuid().v7obj();
        final sharedSpaceId = const Uuid().v7obj();
        final server = await openServer();
        await server.db.transactionForUser(
          sharedSpaceId,
          (transaction) => Note.db.insertRow(
            server,
            Note(title: 'shared'),
            transaction: transaction,
          ),
        );

        final titles = await server.db.transactionForUser(userId, (
          transaction,
        ) async {
          final space = await OfflineSyncSpace.db.findFirstRow(
            server,
            where: (t) => t.uuidSpaceId.equals(sharedSpaceId),
            transaction: transaction,
          );
          await OfflineSyncSpaceMember.db.insertRow(
            server,
            OfflineSyncSpaceMember(
              spaceId: space!.id!,
              userUuid: userId,
              role: OfflineSyncSpaceRole.readWrite,
            ),
            transaction: transaction,
          );
          return [
            for (final note in await Note.db.find(
              server,
              transaction: transaction,
            ))
              note.title,
          ];
        });

        expect(titles, ['shared']);
      },
    );
  });
}
