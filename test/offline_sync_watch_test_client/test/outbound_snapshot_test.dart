import 'dart:io';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

import 'support/sync_harness.dart';

void main() {
  test(
    'budgeted batches capture payloads before the first wire chunk',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sync_budget_snapshot_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final client = Client('http://localhost:1/');
      final userId = const Uuid().v7obj();
      final author = OfflineSyncDatabaseSession.wraps(
        await client.createSession(p.join(directory.path, 'author.db')),
        syncTables: syncTables,
        persistentUserId: userId,
        syncBatchSize: 1,
        batchBudget: OfflineSyncBatchBudget(maxChanges: 10),
      );
      addTearDown(author.close);
      await author.db.initialize();
      final receiver = await client.createSyncSession(
        p.join(directory.path, 'receiver.db'),
        persistentUserId: userId,
      );
      addTearDown(receiver.close);
      final notes = await Note.db.insert(author, [
        Note(title: 'a0'),
        Note(title: 'b0'),
      ]);
      final captured = <CrdtMergeChange>[];
      var edited = false;
      final transport = peerOf(
        author,
        mapServerStream: (stream) async* {
          await for (final event in stream) {
            if (event is OfflineSyncMergeChunk) {
              captured.addAll(event.changes);
              if (!edited) {
                edited = true;
                await Note.db
                    .update(author, [
                      for (final note in notes)
                        note.copyWith(title: '${note.title}-edited'),
                    ], columns: (t) => [t.title])
                    .timeout(const Duration(seconds: 5));
              }
            }
            yield event;
          }
        },
      );
      await transport.syncOnce(receiver).timeout(const Duration(seconds: 10));
      expect(edited, isTrue);
      expect(
        captured.whereType<CrdtMergeInsert>().map(
          (change) => (change.data as Note).title,
        ),
        unorderedEquals(['a0', 'b0']),
      );
      await transport.syncOnce(receiver).timeout(const Duration(seconds: 10));
      expect(
        (await Note.db.find(
          receiver,
          orderBy: (t) => t.title,
        )).map((note) => note.title),
        ['a0-edited', 'b0-edited'],
      );
    },
  );

  test(
    'captures payloads before yielding and releases the SQLite write lock',
    () async {
      final directory = await Directory.systemTemp.createTemp('sync_snapshot_');
      addTearDown(() => directory.delete(recursive: true));
      final client = Client('http://localhost:1/');
      final userId = const Uuid().v7obj();
      final author = await client.createSyncSession(
        p.join(directory.path, 'author.db'),
        persistentUserId: userId,
      );
      addTearDown(author.close);
      final peer = await client.createSyncSession(
        p.join(directory.path, 'peer.db'),
        persistentUserId: userId,
      );
      addTearDown(peer.close);
      final notes = await Note.db.insert(author, [
        Note(title: 'a0'),
        Note(title: 'b0'),
      ]);
      final engine = OfflineSyncEngine(
        syncTables: syncTables,
        serializationManager: author.db.serializationManager,
      );

      final captured = <CrdtMergeChange>[];
      await for (final change in engine.collectPendingChanges(
        author,
        checkpointsBySpaceUuid: {userId: const []},
      )) {
        captured.add(change);
        if (captured.length != 1) continue;
        // The consumer can write while paused on the first emitted change.
        // Later changes must still carry the values captured with their HLCs.
        await Note.db
            .update(author, [
              for (final note in notes)
                note.copyWith(title: '${note.title}-edited'),
            ], columns: (t) => [t.title])
            .timeout(const Duration(seconds: 5));
      }
      expect(
        captured.whereType<CrdtMergeInsert>().map(
          (change) => (change.data as Note).title,
        ),
        unorderedEquals(['a0', 'b0']),
      );
      await engine.mergeInboundBatch(peer, spaceId: userId, mergeSet: captured);
      final checkpoints = await engine.createSyncSinceHlc(
        peer,
        spaceId: userId,
      );
      final next = await engine
          .collectPendingChanges(
            author,
            checkpointsBySpaceUuid: {userId: checkpoints.nodeCheckpoints},
          )
          .toList();
      await engine.mergeInboundBatch(peer, spaceId: userId, mergeSet: next);
      expect(
        (await Note.db.find(
          peer,
          orderBy: (t) => t.title,
        )).map((note) => note.title),
        ['a0-edited', 'b0-edited'],
      );
      final caughtUp = await engine.createSyncSinceHlc(peer, spaceId: userId);
      expect(
        await engine
            .collectPendingChanges(
              author,
              checkpointsBySpaceUuid: {userId: caughtUp.nodeCheckpoints},
            )
            .toList(),
        isEmpty,
      );
    },
  );
}
