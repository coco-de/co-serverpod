import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_database/serverpod_database.dart'
    show DatabaseSession, IncludeList, WhereExpressionBuilder;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  final client = Client('http://localhost:1/');
  var databaseCount = 0;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_watch_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  Future<OfflineSyncDatabaseSession> openReplica(UuidValue userId) async {
    final session = await client.createSyncSession(
      p.join(tempDir.path, 'replica-${++databaseCount}.db'),
      persistentUserId: userId,
    );
    addTearDown(session.close);
    return session;
  }

  StreamQueue<T> queueOf<T>(Stream<T> stream) {
    final queue = StreamQueue(stream);
    addTearDown(() => queue.cancel(immediate: true));
    return queue;
  }

  // Titles rather than models: generated models have no value equality.
  StreamQueue<List<String>> watchTitles(
    DatabaseSession session, {
    WhereExpressionBuilder<NoteTable>? where,
    int? limit,
    int? offset,
  }) {
    return queueOf(
      Note.db
          .watch(
            session,
            where: where,
            orderBy: (t) => t.title,
            limit: limit,
            offset: offset,
          )
          .map((notes) => [for (final note in notes) note.title]),
    );
  }

  /// Whether [queue] emits within [window]. A later emission stays queued.
  Future<bool> emitsWithin(
    StreamQueue<Object?> queue, [
    Duration window = const Duration(seconds: 1),
  ]) {
    return queue.hasNext.timeout(window, onTimeout: () => false);
  }

  /// Syncs through [server] acting as the authoritative peer, the role the
  /// Serverpod endpoint plays against Postgres in production.
  OfflineSyncClient peerOf(OfflineSyncDatabaseSession server) {
    return OfflineSyncClient(
      ({required changes, required once}) => server.db.sync(
        inbound: changes,
        once: once,
        mode: OfflineSyncPeerMode.authoritative,
      ),
    );
  }

  group('Model.db.watch 로컬 쓰기', () {
    test(
      'should_emit_initial_rows_then_local_insert_update_and_delete',
      () async {
        final session = await openReplica(const Uuid().v7obj());
        final titles = watchTitles(session);
        expect(await titles.next, isEmpty);

        final note = await Note.db.insertRow(session, Note(title: 'draft'));
        expect(await titles.next, ['draft']);

        await Note.db.updateRow(session, note.copyWith(title: 'final'));
        expect(await titles.next, ['final']);

        // A delete only writes CRDT metadata and never touches the note row.
        await Note.db.deleteRow(session, note);
        expect(await titles.next, isEmpty);
      },
    );

    test('should_drop_rows_that_stop_matching_the_where_filter', () async {
      final session = await openReplica(const Uuid().v7obj());
      final titles = watchTitles(
        session,
        where: (t) => t.archived.equals(false),
      );
      expect(await titles.next, isEmpty);

      final a = await Note.db.insertRow(session, Note(title: 'a'));
      expect(await titles.next, ['a']);
      await Note.db.insertRow(session, Note(title: 'b'));
      expect(await titles.next, ['a', 'b']);

      await Note.db.updateRow(session, a.copyWith(archived: true));
      expect(await titles.next, ['b']);
    });

    test('should_page_visible_rows_with_limit_and_offset', () async {
      final session = await openReplica(const Uuid().v7obj());
      for (final title in ['a', 'b', 'c', 'd', 'e']) {
        await Note.db.insertRow(session, Note(title: title));
      }
      final page = watchTitles(session, limit: 2, offset: 1);
      final tail = watchTitles(session, offset: 3);
      expect(await page.next, ['b', 'c']);
      expect(await tail.next, ['d', 'e']);

      final b = await Note.db.findFirstRow(
        session,
        where: (t) => t.title.equals('b'),
      );
      await Note.db.deleteRow(session, b!);
      expect(await page.next, ['c', 'd']);
      expect(await tail.next, ['e']);
    });

    test('should_not_emit_for_a_rolled_back_transaction', () async {
      final session = await openReplica(const Uuid().v7obj());
      final titles = watchTitles(session);
      expect(await titles.next, isEmpty);

      await expectLater(
        session.db.transaction((transaction) async {
          await Note.db.insertRow(
            session,
            Note(title: 'ghost'),
            transaction: transaction,
          );
          throw const _Abort();
        }),
        throwsA(isA<_Abort>()),
      );
      expect(await emitsWithin(titles), isFalse);

      await Note.db.insertRow(session, Note(title: 'real'));
      expect(await titles.next, ['real']);
    });

    test('should_skip_unchanged_results_from_other_synced_tables', () async {
      final session = await openReplica(const Uuid().v7obj());
      final titles = watchTitles(session);
      expect(await titles.next, isEmpty);

      // Every synced write touches the shared CRDT tables and re-runs the query,
      // but an identical result must not reach the listener.
      await Folder.db.insertRow(session, Folder(name: 'inbox'));
      expect(await emitsWithin(titles), isFalse);
    });

    test('should_hide_deleted_rows_inside_an_included_list', () async {
      final session = await openReplica(const Uuid().v7obj());
      final include = Folder.include(
        notes: Note.includeList(orderBy: (t) => t.title),
      );
      final folders = queueOf(
        Folder.db
            .watch(session, include: include)
            .map(
              (folders) => {
                for (final folder in folders)
                  folder.name: [
                    for (final note in folder.notes ?? const <Note>[])
                      note.title,
                  ],
              },
            ),
      );
      expect(await folders.next, isEmpty);

      final folder = await Folder.db.insertRow(session, Folder(name: 'inbox'));
      expect(await folders.next, {'inbox': <String>[]});
      final a = await Note.db.insertRow(
        session,
        Note(title: 'a', folderId: folder.id),
      );
      expect(await folders.next, {
        'inbox': ['a'],
      });
      await Note.db.insertRow(session, Note(title: 'b', folderId: folder.id));
      expect(await folders.next, {
        'inbox': ['a', 'b'],
      });

      await Note.db.deleteRow(session, a);
      expect(await folders.next, {
        'inbox': ['b'],
      });

      // Every re-run restores the caller's include predicate before find()
      // adds the visibility filter, so it never accumulates.
      final notesWhere = (include.includes['notes']! as IncludeList).where;
      expect('NOT EXISTS'.allMatches('$notesWhere'), hasLength(1));
    });

    test('should_watch_local_only_client_tables', () async {
      final session = await openReplica(const Uuid().v7obj());
      final drafts = queueOf(
        LocalDraft.db
            .watch(session)
            .map((drafts) => [for (final draft in drafts) draft.body]),
      );
      expect(await drafts.next, isEmpty);

      await LocalDraft.db.insertRow(session, LocalDraft(body: 'hello'));
      expect(await drafts.next, ['hello']);
    });

    test('should_forward_unsafe_watch_as_raw_sql', () async {
      final session = await openReplica(const Uuid().v7obj());
      final counts = queueOf(
        session.db
            .unsafeWatch(
              'SELECT COUNT(*) FROM note',
              triggerOnTables: const {'note'},
            )
            .map((result) => result.first.first),
      );
      expect(await counts.next, 0);

      await Note.db.insertRow(session, Note(title: 'a'));
      expect(await counts.next, 1);
    });
  });

  group('Model.db.watch 동기화 병합', () {
    test('should_reemit_merged_insert_update_and_delete', () async {
      final userId = const Uuid().v7obj();
      final server = await openReplica(userId);
      final device = await openReplica(userId);
      final peer = peerOf(server);
      final titles = watchTitles(device);
      expect(await titles.next, isEmpty);

      final note = await Note.db.insertRow(server, Note(title: 'remote'));
      await peer.syncOnce(device);
      expect(await titles.next, ['remote']);

      await Note.db.updateRow(server, note.copyWith(title: 'edited'));
      await peer.syncOnce(device);
      expect(await titles.next, ['edited']);

      // A merged tombstone only writes CRDT metadata on the device.
      await Note.db.deleteRow(server, note);
      await peer.syncOnce(device);
      expect(await titles.next, isEmpty);
    });

    test('should_stream_remote_writes_during_continuous_sync', () async {
      final userId = const Uuid().v7obj();
      final server = await openReplica(userId);
      final device = await openReplica(userId);
      final live = peerOf(server).syncContinuously(device);
      addTearDown(live.cancel);
      final titles = watchTitles(device);
      expect(await titles.next, isEmpty);

      await Note.db.insertRow(server, Note(title: 'live'));
      expect(await titles.next.timeout(const Duration(seconds: 10)), ['live']);
    });
  });
}

class _Abort implements Exception {
  const _Abort();
}
