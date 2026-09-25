import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

import 'support/batch_recorder.dart';
import 'support/sync_harness.dart';

/// A batch budget must not send a change that writes a foreign key in an
/// earlier batch than the insert of the parent it names (fork,
/// unibook#14251).
///
/// Restoring a row (inserting it again with its id) stamps its insert anew,
/// so a child written under it before the restore sorts before its parent's
/// insert. The receiver merges one batch in one transaction with deferred
/// foreign keys: a child whose parent is not in that transaction nor in its
/// database fails the commit, and the sender builds the same first batch in
/// every session. The account would stop syncing for good.
///
/// | Case | Pinned |
/// |---|---|
/// | Device restores the parent after inserting a child under it | The child's insert goes with the parent's, the server gets every row |
/// | Server restores the parent, a new device pulls | Same, from the authoritative side |
/// | Device moves a child to a parent, then restores that parent | The update goes with the parent's insert |
/// | The parent a dependency brings names a grandparent restored after it | The grandparent's insert goes too |
/// | Only the child's attempted value names the parent, a new device pulls | Same: the value sent is the attempted one |
/// | Many children before a restored note | Each round reads the foreign keys of the changes it takes only |
/// | Random writes on a server and two devices, 32 seeds | Budgets 1, 2 and 3 end where the unlimited run ends |
void main() {
  late Directory tempDir;
  final client = Client('http://localhost:1/');
  var databaseCount = 0;
  const sessionTimeout = Duration(seconds: 20);

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_fk_batch_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  Future<OfflineSyncDatabaseSession> openReplica(
    UuidValue userId, {
    OfflineSyncBatchBudget batchBudget = OfflineSyncBatchBudget.unlimited,
  }) async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(
        p.join(tempDir.path, 'replica-${++databaseCount}.db'),
      ),
      syncTables: syncTables,
      persistentUserId: userId,
      batchBudget: batchBudget,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  /// Waits long enough that the next write is not stamped right after the
  /// previous one, so no write groups them.
  Future<void> apart() => Future<void>.delayed(const Duration(milliseconds: 3));

  /// Runs [write] at a wall clock [ahead] of now, so every HLC it takes shares
  /// one millisecond: a restore's insert and its tombstone are then one write.
  Future<T> inOneMillisecond<T>(
    Future<T> Function() write, {
    Duration ahead = const Duration(milliseconds: 20),
  }) => withClock(Clock.fixed(DateTime.now().toUtc().add(ahead)), write);

  /// The visible folders, notes and attachments of [session], comparable
  /// across replicas.
  Future<List<String>> contentOf(OfflineSyncDatabaseSession session) async => [
    for (final folder in await Folder.db.find(session))
      'folder ${folder.id} ${folder.name}',
    for (final note in await Note.db.find(session))
      'note ${note.id} ${note.title} ${note.folderId}',
    for (final attachment in await Attachment.db.find(session))
      'attachment ${attachment.id} ${attachment.name} ${attachment.noteId}',
  ]..sort();

  /// How many visible rows of [prefix] ('note', 'attachment') [content] holds.
  int countOf(List<String> content, String prefix) =>
      content.where((line) => line.startsWith('$prefix ')).length;

  /// Whether [change] is the insert of [rowId].
  bool isInsertOf(CrdtMergeChange change, UuidValue? rowId) =>
      change is CrdtMergeInsert && change.uuidRowId == rowId;

  /// The rows whose inserts go in the batch of [frames] that carries the
  /// insert of [rowId].
  List<UuidValue> insertsInBatchOf(BatchRecorder frames, UuidValue? rowId) => [
    for (final change in frames.dataBatches.singleWhere(
      (batch) => batch.any((change) => isInsertOf(change, rowId)),
    ))
      if (change is CrdtMergeInsert) change.uuidRowId,
  ];

  /// Waits past the fixed clock of [inOneMillisecond].
  Future<void> pastFixedClock() =>
      Future<void>.delayed(const Duration(milliseconds: 25));

  group('Given a device with a batch budget,', () {
    for (final maxChanges in [1, 2, 3]) {
      test(
        'should_send_the_childs_insert_with_its_restored_parents_insert_when_maxChanges_is_$maxChanges',
        () async {
          final userId = const Uuid().v7obj();
          final server = await openReplica(userId);
          final device = await openReplica(
            userId,
            batchBudget: OfflineSyncBatchBudget(maxChanges: maxChanges),
          );
          final parent = await Note.db.insertRow(device, Note(title: 'p'));
          await apart();
          final child = await Attachment.db.insertRow(
            device,
            Attachment(name: 'c', noteId: parent.id!),
          );
          await apart();
          await Note.db.deleteRow(device, parent);
          await apart();
          // The restore stamps the note's insert after the attachment's.
          await inOneMillisecond(
            () => Note.db.insertRow(device, Note(id: parent.id, title: 'p2')),
          );
          final deviceFrames = BatchRecorder();

          await peerOf(
            server,
            mapDeviceEvent: deviceFrames.record,
          ).syncOnce(device).timeout(sessionTimeout);

          expect(await contentOf(server), await contentOf(device));
          expect(countOf(await contentOf(server), 'note'), 1);
          expect(await device.db.unsentRowCount(), 0);
          final batchOfChildInsert = deviceFrames.dataBatches.singleWhere(
            (batch) => batch.any(
              (change) =>
                  change is CrdtMergeInsert && change.uuidRowId == child.id,
            ),
          );
          expect(
            batchOfChildInsert.any(
              (change) =>
                  change is CrdtMergeInsert && change.uuidRowId == parent.id,
            ),
            isTrue,
            reason: "the parent's insert goes in the child's batch",
          );
        },
      );
    }
  });

  group('Given a device with a batch budget and a foreign key update,', () {
    for (final maxChanges in [1, 2, 3]) {
      test(
        'should_send_the_update_with_the_insert_of_the_restored_parent_it_names_when_maxChanges_is_$maxChanges',
        () async {
          // The attachment moves to a note that is then deleted and restored:
          // the update of its foreign key sorts before the note's insert.
          final userId = const Uuid().v7obj();
          final server = await openReplica(userId);
          final device = await openReplica(
            userId,
            batchBudget: OfflineSyncBatchBudget(maxChanges: maxChanges),
          );
          final first = await Note.db.insertRow(device, Note(title: 'p1'));
          await apart();
          final child = await Attachment.db.insertRow(
            device,
            Attachment(name: 'c', noteId: first.id!),
          );
          await peerOf(server).syncOnce(device).timeout(sessionTimeout);
          await apart();
          final second = await Note.db.insertRow(device, Note(title: 'p2'));
          await apart();
          await Attachment.db.updateRow(
            device,
            child.copyWith(noteId: second.id),
            columns: (t) => [t.noteId],
          );
          await apart();
          await Note.db.deleteRow(device, second);
          await apart();
          await inOneMillisecond(
            () => Note.db.insertRow(device, Note(id: second.id, title: 'p3')),
          );
          await pastFixedClock();
          final deviceFrames = BatchRecorder();

          await peerOf(
            server,
            mapDeviceEvent: deviceFrames.record,
          ).syncOnce(device).timeout(sessionTimeout);

          expect(await contentOf(server), await contentOf(device));
          expect(countOf(await contentOf(server), 'note'), 2);
          final batchOfUpdate = deviceFrames.dataBatches.singleWhere(
            (batch) => batch.any(
              (change) =>
                  change is CrdtMergeUpdate && change.uuidRowId == child.id,
            ),
          );
          expect(
            batchOfUpdate.any((change) => isInsertOf(change, second.id)),
            isTrue,
            reason: "the restored note's insert goes in the update's batch",
          );
        },
      );
    }
  });

  group('Given a device with a batch budget and a chain of foreign keys,', () {
    test(
      'should_send_the_restored_grandparents_insert_with_the_childs_when_the_parent_it_brings_names_it',
      () async {
        // The attachment names the note, restored after it; the note names
        // the folder, restored after the note. The note's foreign key is read
        // only once the attachment's dependency brings the note's insert into
        // the batch.
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 1),
        );
        final folder = await Folder.db.insertRow(device, Folder(name: 'f'));
        await apart();
        final note = await Note.db.insertRow(
          device,
          Note(title: 'n', folderId: folder.id),
        );
        await apart();
        final attachment = await Attachment.db.insertRow(
          device,
          Attachment(name: 'a', noteId: note.id!),
        );
        await apart();
        await Note.db.deleteRow(device, note);
        await apart();
        await Folder.db.deleteRow(device, folder);
        await apart();
        await inOneMillisecond(
          () => Note.db.insertRow(
            device,
            Note(id: note.id, title: 'n2', folderId: folder.id),
          ),
        );
        await pastFixedClock();
        await inOneMillisecond(
          () => Folder.db.insertRow(device, Folder(id: folder.id, name: 'f2')),
        );
        await pastFixedClock();
        final deviceFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncOnce(device).timeout(sessionTimeout);

        expect(await contentOf(server), await contentOf(device));
        expect(
          insertsInBatchOf(deviceFrames, attachment.id),
          containsAll([attachment.id, note.id, folder.id]),
        );
      },
    );

    test(
      'should_send_a_new_device_the_parents_insert_with_the_child_whose_attempted_value_names_it',
      () async {
        // The tablet files n in folder f. The server deletes and restores f,
        // so its insert of f sorts after n. The phone then deletes f with a
        // higher generation: the server shows n without a folder, and only
        // n's attempted value names f.
        final userId = const Uuid().v7obj();
        final server = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 1),
        );
        final phone = await openReplica(userId);
        final tablet = await openReplica(userId);
        final folder = await Folder.db.insertRow(phone, Folder(name: 'f'));
        await peerOf(server).syncOnce(phone).timeout(sessionTimeout);
        await peerOf(server).syncOnce(tablet).timeout(sessionTimeout);
        await apart();
        final note = await Note.db.insertRow(
          tablet,
          Note(title: 'n', folderId: folder.id),
        );
        await apart();
        await Folder.db.deleteRow(server, folder);
        await apart();
        await inOneMillisecond(
          () => Folder.db.insertRow(server, Folder(id: folder.id, name: 'f2')),
        );
        await pastFixedClock();
        await peerOf(server).syncOnce(tablet).timeout(sessionTimeout);
        await apart();
        // Generation 4: above the server's restore (generation 3).
        await Folder.db.deleteRow(phone, folder);
        await apart();
        await Folder.db.insertRow(phone, Folder(id: folder.id, name: 'f3'));
        await apart();
        await Folder.db.deleteRow(phone, folder);
        await apart();
        await peerOf(server).syncOnce(phone).timeout(sessionTimeout);
        expect(
          (await Note.db.findById(server, note.id!))!.folderId,
          isNull,
          reason: 'projected away',
        );
        final laptop = await openReplica(userId);
        final serverFrames = BatchRecorder();

        await peerOf(
          server,
          mapServerStream: (stream) => stream.map(serverFrames.record),
        ).syncOnce(laptop).timeout(sessionTimeout);

        expect(await contentOf(laptop), await contentOf(server));
        expect(
          insertsInBatchOf(serverFrames, note.id),
          containsAll([note.id, folder.id]),
        );
      },
    );
  });

  group('Given a device with a batch budget and many children,', () {
    test(
      'should_read_the_foreign_keys_of_the_changes_each_batch_takes_only',
      () async {
        // A note restored last makes every attachment before it a change
        // that may name it. Reading all of their foreign keys every round
        // made each round cost the whole backlog; this pins what is read.
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 3),
        );
        for (var i = 0; i < 5; i++) {
          final note = await Note.db.insertRow(device, Note(title: 'n$i'));
          await apart();
          await Attachment.db.insertRow(
            device,
            Attachment(name: 'a$i', noteId: note.id!),
          );
          await apart();
        }
        final last = await Note.db.insertRow(device, Note(title: 'z'));
        await apart();
        await Note.db.deleteRow(device, last);
        await apart();
        await inOneMillisecond(
          () => Note.db.insertRow(device, Note(id: last.id, title: 'z2')),
        );
        await pastFixedClock();
        final reads = <int>[];
        addTearDown(() => OfflineSyncEngine.debugOnForeignKeysRead = null);
        OfflineSyncEngine.debugOnForeignKeysRead = reads.add;
        final deviceFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncOnce(device).timeout(sessionTimeout);

        expect(await contentOf(server), await contentOf(device));
        expect(deviceFrames.dataSizes, [3, 3, 3, 3]);
        // Each round reads the attachments among the changes it takes.
        expect(reads, [1, 2, 1, 1]);
      },
    );
  });

  group('Given a server with a batch budget,', () {
    for (final maxChanges in [1, 2]) {
      test(
        'should_send_a_new_device_the_childs_insert_with_the_parents_insert_the_server_restored_when_maxChanges_is_$maxChanges',
        () async {
          final userId = const Uuid().v7obj();
          final server = await openReplica(
            userId,
            batchBudget: OfflineSyncBatchBudget(maxChanges: maxChanges),
          );
          final phone = await openReplica(userId);
          final parent = await Note.db.insertRow(phone, Note(title: 'p'));
          await peerOf(server).syncOnce(phone).timeout(sessionTimeout);
          await apart();
          final child = await Attachment.db.insertRow(
            phone,
            Attachment(name: 'c', noteId: parent.id!),
          );
          await apart();
          // The server deletes and restores the note before it hears of the
          // attachment: its insert of the note is stamped after the phone's
          // insert of the attachment.
          await Note.db.deleteRow(server, parent);
          await apart();
          await inOneMillisecond(
            () => Note.db.insertRow(server, Note(id: parent.id, title: 'p2')),
          );
          // Past the fixed clock of the restore.
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await peerOf(server).syncOnce(phone).timeout(sessionTimeout);
          expect(await contentOf(server), await contentOf(phone));
          final tablet = await openReplica(userId);
          final serverFrames = BatchRecorder();

          await peerOf(
            server,
            mapServerStream: (stream) => stream.map(serverFrames.record),
          ).syncOnce(tablet).timeout(sessionTimeout);

          expect(await contentOf(tablet), await contentOf(server));
          expect(countOf(await contentOf(tablet), 'attachment'), 1);
          final batchOfChildInsert = serverFrames.dataBatches.singleWhere(
            (batch) => batch.any(
              (change) =>
                  change is CrdtMergeInsert && change.uuidRowId == child.id,
            ),
          );
          expect(
            batchOfChildInsert.any(
              (change) =>
                  change is CrdtMergeInsert && change.uuidRowId == parent.id,
            ),
            isTrue,
            reason: "the parent's insert goes in the child's batch",
          );
        },
      );
    }
  });

  group('Given random writes on a server and two devices,', () {
    // Every seed runs its operations once per budget, on fresh replicas that
    // all use that budget, and must end where the unlimited run ends. The
    // range holds the seeds the review named (106, 109, 124), but this
    // generator is not the review's: before the fix, seeds 111, 115, 122,
    // 127 and 130 of it reached the foreign key violation.
    for (var seed = 100; seed < 132; seed++) {
      test(
        'should_end_every_replica_where_the_unlimited_run_ends_when_the_budget_is_1_2_or_3_for_seed_$seed',
        () async {
          const limits = [null, 1, 2, 3];
          // The runs share nothing, so they run side by side. Each keeps its
          // own failure, so the report names the budget that failed.
          final results = await Future.wait([
            for (final maxChanges in limits)
              runRandomWrites(
                seed,
                maxChanges == null
                    ? OfflineSyncBatchBudget.unlimited
                    : OfflineSyncBatchBudget(maxChanges: maxChanges),
                openReplica,
                contentOf,
                apart,
              ).then<Object>((content) => content, onError: (Object e) => e),
          ]);
          for (var i = 0; i < limits.length; i++) {
            expect(
              results[i],
              isA<List<List<String>>>(),
              reason: 'seed $seed, maxChanges ${limits[i]} failed',
            );
          }
          for (var i = 1; i < limits.length; i++) {
            expect(
              results[i],
              results.first,
              reason: 'seed $seed, maxChanges ${limits[i]}',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}

/// Runs the random writes of [seed] on a server and two devices opened with
/// [budget], syncing the devices in between, then has a new device pull
/// everything. Returns every replica's content, in the order server, phone,
/// tablet, new device.
///
/// Every step is a valid local write on the replica it picks, or a sync. The
/// replicas' states, and so the steps, are the same for every budget as long
/// as every sync delivers everything. A sync that fails fails the test.
Future<List<List<String>>> runRandomWrites(
  int seed,
  OfflineSyncBatchBudget budget,
  Future<OfflineSyncDatabaseSession> Function(
    UuidValue userId, {
    OfflineSyncBatchBudget batchBudget,
  })
  openReplica,
  Future<List<String>> Function(OfflineSyncDatabaseSession session) contentOf,
  Future<void> Function() apart,
) async {
  const sessionTimeout = Duration(seconds: 20);
  final random = Random(seed);
  final userId = const Uuid().v7obj();
  final server = await openReplica(userId, batchBudget: budget);
  final phone = await openReplica(userId, batchBudget: budget);
  final tablet = await openReplica(userId, batchBudget: budget);
  final writers = [server, phone, tablet];
  var nextId = 0;
  // Ids the same across budgets, so the contents compare.
  UuidValue newId() => UuidValue.fromString(
    '${seed.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-'
    '${(++nextId).toRadixString(16).padLeft(12, '0')}',
  );
  final folderIds = <UuidValue>[];
  final noteIds = <UuidValue>[];
  final attachmentIds = <UuidValue>[];
  T? pick<T>(List<T> from) =>
      from.isEmpty ? null : from[random.nextInt(from.length)];

  /// Ids of [ids] whose row [replica] holds hidden: deleted, restorable.
  Future<List<UuidValue>> hiddenOf(
    OfflineSyncDatabaseSession replica,
    List<UuidValue> ids,
    Future<bool> Function(UuidValue id) isVisible,
  ) async => [
    for (final id in ids)
      if (await CrdtDataRow.db.findFirstRow(
                replica,
                where: (t) => t.uuidRowId.equals(id),
              ) !=
              null &&
          !await isVisible(id))
        id,
  ];

  Future<void> sync(OfflineSyncDatabaseSession device) =>
      peerOf(server).syncOnce(device).timeout(sessionTimeout);

  for (var step = 0; step < 32; step++) {
    await apart();
    final replica = writers[random.nextInt(writers.length)];
    final folders = await Folder.db.find(replica, orderBy: (t) => t.id);
    final notes = await Note.db.find(replica, orderBy: (t) => t.id);
    final attachments = await Attachment.db.find(replica, orderBy: (t) => t.id);
    final op = random.nextInt(15);
    switch (op) {
      case 0:
        final id = newId();
        folderIds.add(id);
        await Folder.db.insertRow(replica, Folder(id: id, name: 'f$step'));
      case 1 || 2:
        final id = newId();
        noteIds.add(id);
        await Note.db.insertRow(
          replica,
          Note(id: id, title: 'n$step', folderId: pick(folders)?.id),
        );
      case 3 || 4 || 5:
        final note = pick(notes);
        if (note == null) break;
        final id = newId();
        attachmentIds.add(id);
        await Attachment.db.insertRow(
          replica,
          Attachment(id: id, name: 'a$step', noteId: note.id!),
        );
      case 6:
        final note = pick(notes);
        if (note == null) break;
        await Note.db.updateRow(
          replica,
          note.copyWith(title: 'n$step'),
          columns: (t) => [t.title],
        );
      case 7:
        final attachment = pick(attachments);
        final note = pick(notes);
        if (attachment == null || note == null) break;
        await Attachment.db.updateRow(
          replica,
          attachment.copyWith(noteId: note.id),
          columns: (t) => [t.noteId],
        );
      case 8 || 9:
        final note = pick(notes);
        if (note == null) break;
        await Note.db.deleteRow(replica, note);
      case 10:
        final choice = random.nextInt(2);
        if (choice == 0) {
          final attachment = pick(attachments);
          if (attachment == null) break;
          await Attachment.db.deleteRow(replica, attachment);
        } else {
          final folder = pick(folders);
          if (folder == null) break;
          await Folder.db.deleteRow(replica, folder);
        }
      case 11 || 12:
        // Restore a note: its insert is stamped anew, after anything
        // written under it before.
        final hidden = await hiddenOf(
          replica,
          noteIds,
          (id) async => await Note.db.findById(replica, id) != null,
        );
        final id = pick(hidden);
        if (id == null) break;
        await Note.db.insertRow(replica, Note(id: id, title: 'r$step'));
      case 13:
        final choice = random.nextInt(2);
        if (choice == 0) {
          final hidden = await hiddenOf(
            replica,
            folderIds,
            (id) async => await Folder.db.findById(replica, id) != null,
          );
          final id = pick(hidden);
          if (id == null) break;
          await Folder.db.insertRow(replica, Folder(id: id, name: 'r$step'));
        } else {
          final hidden = await hiddenOf(
            replica,
            attachmentIds,
            (id) async => await Attachment.db.findById(replica, id) != null,
          );
          final id = pick(hidden);
          final note = pick(notes);
          if (id == null || note == null) break;
          await Attachment.db.insertRow(
            replica,
            Attachment(id: id, name: 'r$step', noteId: note.id!),
          );
        }
      default:
        await sync(random.nextBool() ? phone : tablet);
    }
  }
  for (var round = 0; round < 2; round++) {
    await sync(phone);
    await sync(tablet);
  }
  final laptop = await openReplica(userId, batchBudget: budget);
  await sync(laptop);
  return [
    for (final replica in [server, phone, tablet, laptop])
      await contentOf(replica),
  ];
}
