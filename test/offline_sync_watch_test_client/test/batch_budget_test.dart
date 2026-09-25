import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

import 'support/batch_recorder.dart';
import 'support/sync_harness.dart';

/// Outbound batch budget and row isolation between two real SQLite replicas,
/// one playing the Serverpod endpoint (authoritative) as in
/// `model_watch_test.dart` (fork, unibook#14251).
///
/// Upstream sends every pending change of a round in one batch, which the
/// receiver holds in memory until the batch ends. A budget ends the batch
/// before a limit and sends the rest in the next rounds; a `once` session runs
/// them before it closes. Row isolation leaves a rejected row out so the rest
/// keeps syncing, and a released row goes again in full.
///
/// | Case | Pinned |
/// |---|---|
/// | No budget, no isolation | Upstream's order (inserts, updates, deletes) in one batch |
/// | Device budget, `once` | Batches at the limit, every change sent, HLC prefix per batch, checkpoint at the last change, nothing unsent |
/// | Device budget, continuous | One batch per round, every change sent |
/// | Device budget, attempted values | Each batch reads its own inserts' only |
/// | An update stamped between two inserts | Sent: HLC order, not inserts first |
/// | Either limit ends between a delete and its cascade | Both in the next batch |
/// | An earlier delete fills the batch before a delete and its cascade | The earlier delete, then both in the next batch |
/// | The payload limit ends a non-empty batch before a delete run that fits an empty one | The run whole in the next batch, not its first group in this one |
/// | The budget ends inside one write's changes of a row | All of them in the next batch |
/// | A delete stamped before its row's insert, new device | Sent with the insert: the device ends without the row |
/// | An insert whose foreign key the server projected away, in a later batch | Sent with the attempted value, not the projected one |
/// | Server budget (authoritative) | The device receives batches at the limit and every row |
/// | Payload limit, a change larger than the budget | Sent alone, the session goes on |
/// | A peer built before `hasMore` | Each side closes after one batch; the next session sends on |
/// | Unlimited peer | Still says `hasMore: false` |
/// | Isolated row | Left out, the rest sent, the checkpoint passes it, still counted unsent |
/// | Row that leaves isolation without release | Never sent again (the contract) |
/// | Released row | Sent in full with its latest values, confirmed, then not counted |
/// | Released row deleted while isolated | Its insert and delete arrive |
/// | Released row confirmed slowly, watched count | Counted again after the confirmation: 0 |
/// | Released row, continuous session | Sent once per session, never confirmed, still counted unsent |
/// | Released row, session closed with more to send | Not confirmed, still counted unsent; the next session sends the rest |
/// | Held row of another node, checkpoint going back | Counted in the every-row fallback too |
/// | Released rows over the budget, `once` | Sent across batches, the session ends |
///
/// SQLite only: the Postgres snapshot of the planned collection is covered by
/// unibook's integration tests.
void main() {
  late Directory tempDir;
  final client = Client('http://localhost:1/');
  var databaseCount = 0;
  const sessionTimeout = Duration(seconds: 20);

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_batch_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  Future<OfflineSyncDatabaseSession> openReplica(
    UuidValue userId, {
    OfflineSyncBatchBudget batchBudget = OfflineSyncBatchBudget.unlimited,
    OfflineSyncRowIsolation? rowIsolation,
  }) async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(
        p.join(tempDir.path, 'replica-${++databaseCount}.db'),
      ),
      syncTables: syncTables,
      persistentUserId: userId,
      batchBudget: batchBudget,
      rowIsolation: rowIsolation,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  Future<List<String>> titlesOf(OfflineSyncDatabaseSession session) async => [
    for (final note in await Note.db.find(session, orderBy: (t) => t.title))
      note.title,
  ];

  Future<void> insertNotes(
    OfflineSyncDatabaseSession session,
    int count,
  ) async {
    for (var i = 0; i < count; i++) {
      await Note.db.insertRow(
        session,
        Note(title: 'n${i.toString().padLeft(2, '0')}'),
      );
    }
  }

  /// The checkpoint [server] persisted for the changes it merged from [nodeId].
  Future<Hlc?> checkpointOf(
    OfflineSyncDatabaseSession server,
    UuidValue nodeId,
  ) async {
    final spaceNodes = await OfflineSyncSpaceNode.db.find(
      server,
      include: OfflineSyncSpaceNode.include(node: CrdtNode.include()),
    );
    return spaceNodes
        .where((spaceNode) => spaceNode.node?.uuidNodeId == nodeId)
        .map((spaceNode) => spaceNode.lastReceivedHlc)
        .nonNulls
        .firstOrNull;
  }

  /// The insert HLC of [rowId] in [session].
  Future<Hlc> insertHlcOf(
    OfflineSyncDatabaseSession session,
    UuidValue rowId,
  ) async {
    final row = await CrdtDataRow.db.findFirstRow(
      session,
      where: (t) => t.uuidRowId.equals(rowId),
      include: CrdtDataRow.include(node: CrdtNode.include()),
    );
    return row!.hlc;
  }

  /// The tombstone of [rowId] in [session].
  Future<CrdtDataDeleted> tombstoneOf(
    OfflineSyncDatabaseSession session,
    UuidValue rowId,
  ) async {
    final tombstone = await CrdtDataDeleted.db.findFirstRow(
      session,
      where: (t) => t.row.uuidRowId.equals(rowId),
      include: CrdtDataDeleted.include(node: CrdtNode.include()),
    );
    return tombstone!;
  }

  /// Runs [write] at a wall clock [ahead] of now, so every HLC it takes shares
  /// one millisecond, and apart from anything written before it.
  Future<T> inOneMillisecond<T>(
    Future<T> Function() write, {
    Duration ahead = const Duration(milliseconds: 20),
  }) => withClock(Clock.fixed(DateTime.now().toUtc().add(ahead)), write);

  /// The kind of each change of [batch], in order.
  List<String> kindsOf(List<CrdtMergeChange> batch) => [
    for (final change in batch)
      switch (change) {
        CrdtMergeInsert() => 'insert',
        CrdtMergeUpdate() => 'update',
        CrdtMergeDelete() => 'delete',
      },
  ];

  group('Given a device without a budget or row isolation,', () {
    test(
      'should_send_inserts_then_updates_then_deletes_in_one_batch_as_upstream',
      () async {
        // The planned collection orders by HLC. The default path must stay
        // upstream's: its collection order, one batch per round.
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final a = await Note.db.insertRow(device, Note(title: 'a'));
        final c = await Note.db.insertRow(device, Note(title: 'c'));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        // Stamped update, delete, insert: the reverse of upstream's order.
        await Note.db.updateRow(
          device,
          a.copyWith(title: 'a2'),
          columns: (t) => [t.title],
        );
        await Note.db.deleteRow(device, c);
        await Note.db.insertRow(device, Note(title: 'b'));
        final deviceFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncOnce(device).timeout(sessionTimeout);

        expect(kindsOf(deviceFrames.dataBatches.single), [
          'insert',
          'update',
          'delete',
        ]);
        expect(deviceFrames.dataHasMore, [false]);
        expect(await titlesOf(server), ['a2', 'b']);
      },
    );
  });

  group('Given a device with a batch budget,', () {
    test(
      'should_send_a_once_session_in_batches_at_the_limit_and_every_change_when_the_backlog_exceeds_it',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 3),
        );
        await insertNotes(device, 10);
        final deviceFrames = BatchRecorder();
        final serverFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
          mapServerStream: (stream) => stream.map(serverFrames.record),
        ).syncOnce(device).timeout(sessionTimeout);

        expect(await titlesOf(server), await titlesOf(device));
        expect(await Note.db.count(server), 10);
        expect(deviceFrames.dataSizes, [3, 3, 3, 1]);
        expect(deviceFrames.dataHasMore, [true, true, true, false]);
        expect(deviceFrames.everyHasMoreSet, isTrue);
        // Each batch is past the previous one for the device node: the
        // checkpoint that moves to a batch's last change skips nothing.
        final batches = deviceFrames.dataBatches;
        for (var i = 1; i < batches.length; i++) {
          expect(
            batches[i]
                    .map((change) => change.hlc)
                    .reduce((a, b) => a < b ? a : b) >
                batches[i - 1]
                    .map((change) => change.hlc)
                    .reduce((a, b) => a > b ? a : b),
            isTrue,
            reason: 'batch $i starts after batch ${i - 1} ends',
          );
        }
        final deviceNode = await device.db.currentNodeId();
        expect(
          await checkpointOf(server, deviceNode),
          batches.last
              .map((change) => change.hlc)
              .reduce((a, b) => a > b ? a : b),
        );
        expect(await device.db.unsentRowCount(), 0);
        // The unlimited server still says it has nothing more.
        expect(serverFrames.everyHasMoreSet, isTrue);
        expect(
          serverFrames.endOfBatches.map((frame) => frame.hasMore),
          everyElement(isFalse),
        );
      },
    );

    test(
      'should_read_the_attempted_values_of_the_inserts_each_batch_takes_only',
      () async {
        // Reading them for every pending insert made each round cost the
        // whole backlog. Nothing here has an attempted value: this pins what
        // is read, not what is sent.
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 3),
        );
        await insertNotes(device, 10);
        final reads = <int>[];
        addTearDown(() => OfflineSyncEngine.debugOnAttemptedValuesRead = null);
        OfflineSyncEngine.debugOnAttemptedValuesRead = reads.add;

        await peerOf(server).syncOnce(device).timeout(sessionTimeout);

        expect(reads, [3, 3, 3, 1]);
        expect(await Note.db.count(server), 10);
      },
    );

    test(
      'should_send_one_batch_per_round_and_every_change_when_the_session_is_continuous',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 3),
        );
        await insertNotes(device, 7);
        final deviceFrames = BatchRecorder();

        final live = peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncContinuously(device);
        addTearDown(live.cancel);
        await eventually(
          () async => await Note.db.count(server) == 7,
          timeout: const Duration(seconds: 15),
        );
        await live.cancel();

        expect(deviceFrames.dataSizes, [3, 3, 1]);
        expect(deviceFrames.dataHasMore, [true, true, false]);
        expect(await titlesOf(server), await titlesOf(device));
      },
    );

    test(
      'should_send_an_update_stamped_between_two_inserts_when_the_batch_ends_after_the_first_insert',
      () async {
        // Upstream collects inserts before updates. Cut after two inserts, that
        // order would move the checkpoint past the earlier update, and no later
        // round would send it: the server would keep the old title.
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 2),
        );
        final a = await Note.db.insertRow(device, Note(title: 'a'));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        await Note.db.updateRow(
          device,
          a.copyWith(title: 'a2'),
          columns: (t) => [t.title],
        );
        await Note.db.insertRow(device, Note(title: 'b'));
        await Note.db.insertRow(device, Note(title: 'c'));
        final deviceFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncOnce(device).timeout(sessionTimeout);

        expect(await titlesOf(server), ['a2', 'b', 'c']);
        expect(deviceFrames.dataSizes, [2, 1]);
        expect(deviceFrames.dataBatches.first.first, isA<CrdtMergeUpdate>());
        expect(await device.db.unsentRowCount(), 0);
      },
    );

    // Each limit ends a batch at its own check: the change count before the
    // unit is read, the payload after.
    for (final (limit, budget) in [
      ('change', OfflineSyncBatchBudget(maxChanges: 2)),
      (
        'payload',
        OfflineSyncBatchBudget(maxPayloadChars: 2, measurePayload: (_) => 1),
      ),
    ]) {
      test(
        'should_send_a_delete_and_its_cascade_in_one_batch_when_the_${limit}_limit_ends_between_them',
        () async {
          // The recorder stamps the deleted note, then its cascade-deleted
          // attachment. A batch that ended between them would leave the
          // server with the note deleted and its attachment alive until the
          // next round.
          final userId = const Uuid().v7obj();
          final server = await openReplica(userId);
          final device = await openReplica(userId, batchBudget: budget);
          final parent = await Note.db.insertRow(device, Note(title: 'p'));
          final attachment = await Attachment.db.insertRow(
            device,
            Attachment(name: 'a', noteId: parent.id!),
          );
          final other = await Note.db.insertRow(device, Note(title: 'x'));
          await peerOf(server).syncOnce(device).timeout(sessionTimeout);
          await Note.db.updateRow(
            device,
            other.copyWith(title: 'x2'),
            columns: (t) => [t.title],
          );
          await Note.db.deleteRow(device, parent);
          final deviceFrames = BatchRecorder();

          await peerOf(
            server,
            mapDeviceEvent: deviceFrames.record,
          ).syncOnce(device).timeout(sessionTimeout);

          // Two fit: the update, then the delete with its cascade.
          expect(deviceFrames.dataSizes, [1, 2]);
          expect(
            [
              for (final change in deviceFrames.dataBatches.last)
                (change.uuidRowId, (change as CrdtMergeDelete).reason),
            ],
            [
              (parent.id, CrdtDataDeletedReason.userDelete),
              (attachment.id, CrdtDataDeletedReason.userCascadeDelete),
            ],
          );
          expect(await titlesOf(server), ['x2']);
          expect(await Attachment.db.count(server), 0);
          expect(await device.db.unsentRowCount(), 0);
        },
      );
    }

    test(
      'should_send_the_earlier_delete_then_a_delete_and_its_cascade_when_they_exceed_the_budget_together',
      () async {
        // The delete just before sits in the same run of tombstones as the
        // parent, so the unit holds all three and exceeds the budget. It goes
        // group by group: the earlier delete, then the parent with its
        // cascade, which one write stamped one right after the other.
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 2),
        );
        final earlier = await Note.db.insertRow(device, Note(title: 'e'));
        final parent = await Note.db.insertRow(device, Note(title: 'p'));
        final attachment = await Attachment.db.insertRow(
          device,
          Attachment(name: 'a', noteId: parent.id!),
        );
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        await Note.db.deleteRow(device, earlier);
        await inOneMillisecond(() => Note.db.deleteRow(device, parent));
        final deviceFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncOnce(device).timeout(sessionTimeout);

        expect(deviceFrames.dataSizes, [1, 2]);
        expect(
          [
            for (final batch in deviceFrames.dataBatches)
              [for (final change in batch) change.uuidRowId],
          ],
          [
            [earlier.id],
            [parent.id, attachment.id],
          ],
        );
        expect(await titlesOf(server), isEmpty);
        expect(await Attachment.db.count(server), 0);
      },
    );

    test(
      'should_send_a_delete_run_whole_in_the_next_batch_when_the_payload_limit_ends_the_batch_before_it',
      () async {
        // The earlier delete, the parent and its cascade are one unit, which
        // does not fit after the update but fits an empty batch. The batch
        // ends before the unit instead of taking its first group: only a unit
        // that alone exceeds the budget goes group by group. Only the payload
        // limit reaches this stop; the change limit leaves such a unit out of
        // the batch before anything is read.
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(
            maxPayloadChars: 3,
            measurePayload: (_) => 1,
          ),
        );
        final other = await Note.db.insertRow(device, Note(title: 'x'));
        final earlier = await Note.db.insertRow(device, Note(title: 'e'));
        final parent = await Note.db.insertRow(device, Note(title: 'p'));
        final attachment = await Attachment.db.insertRow(
          device,
          Attachment(name: 'a', noteId: parent.id!),
        );
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        await Note.db.updateRow(
          device,
          other.copyWith(title: 'x2'),
          columns: (t) => [t.title],
        );
        await Note.db.deleteRow(device, earlier);
        await inOneMillisecond(() => Note.db.deleteRow(device, parent));
        final deviceFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncOnce(device).timeout(sessionTimeout);

        expect(deviceFrames.dataSizes, [1, 3]);
        expect(
          [
            for (final batch in deviceFrames.dataBatches)
              [for (final change in batch) change.uuidRowId],
          ],
          [
            [other.id],
            [earlier.id, parent.id, attachment.id],
          ],
        );
        expect(
          [
            for (final change in deviceFrames.dataBatches.last)
              (change as CrdtMergeDelete).reason,
          ],
          [
            CrdtDataDeletedReason.userDelete,
            CrdtDataDeletedReason.userDelete,
            CrdtDataDeletedReason.userCascadeDelete,
          ],
        );
        expect(await titlesOf(server), ['x2']);
        expect(await Attachment.db.count(server), 0);
        expect(await device.db.unsentRowCount(), 0);
      },
    );

    test(
      'should_send_one_writes_changes_of_a_row_in_one_batch_when_the_budget_ends_between_them',
      () async {
        // An update stamps each changed column in turn. A batch that ended
        // between them would show the server the row half written until the
        // next round.
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 2),
        );
        final note = await Note.db.insertRow(device, Note(title: 'n'));
        final other = await Note.db.insertRow(device, Note(title: 'x'));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        await Note.db.updateRow(
          device,
          other.copyWith(title: 'x2'),
          columns: (t) => [t.title],
        );
        await inOneMillisecond(
          () => Note.db.updateRow(
            device,
            note.copyWith(title: 'n2', archived: true),
            columns: (t) => [t.title, t.archived],
          ),
        );
        final deviceFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncOnce(device).timeout(sessionTimeout);

        expect(deviceFrames.dataSizes, [1, 2]);
        expect([
          for (final change in deviceFrames.dataBatches.last)
            (change.uuidRowId, (change as CrdtMergeUpdate).columnName),
        ], unorderedEquals([(note.id, 'title'), (note.id, 'archived')]));
        final merged = await Note.db.findById(server, note.id!);
        expect((merged!.title, merged.archived), ('n2', true));
      },
    );

    test(
      'should_send_a_change_larger_than_the_budget_alone_and_go_on_when_the_payload_limit_is_hit',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(
            maxPayloadChars: 10,
            measurePayload: (change) => switch (change) {
              CrdtMergeInsert(:final data) => (data as Note).title.length,
              _ => 0,
            },
          ),
        );
        for (final title in ['aaaa', 'bbbb', 'c' * 25, 'dd', 'eeeeeeee']) {
          await Note.db.insertRow(device, Note(title: title));
        }
        final deviceFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncOnce(device).timeout(sessionTimeout);

        expect(await Note.db.count(server), 5);
        expect(deviceFrames.dataSizes, [2, 1, 2]);
        expect(
          [
            for (final batch in deviceFrames.dataBatches)
              batch.fold<int>(
                0,
                (sum, change) =>
                    sum +
                    ((change as CrdtMergeInsert).data as Note).title.length,
              ),
          ],
          [8, 25, 10],
        );
      },
    );

    test(
      'should_close_after_one_batch_and_send_on_in_the_next_session_when_the_peer_predates_hasMore',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 3),
        );
        await insertNotes(device, 7);
        OfflineSyncStreamEvent withoutFlag(OfflineSyncStreamEvent event) =>
            event is OfflineSyncEndOfBatch ? OfflineSyncEndOfBatch() : event;
        // Neither side sees the other's flag, as between a new and an old peer.
        final peer = peerOf(
          server,
          mapDeviceEvent: withoutFlag,
          mapServerStream: (stream) => stream.map(withoutFlag),
        );

        await peer.syncOnce(device).timeout(sessionTimeout);
        expect(await Note.db.count(server), 3);
        expect(await device.db.unsentRowCount(), 4);

        await peer.syncOnce(device).timeout(sessionTimeout);
        await peer.syncOnce(device).timeout(sessionTimeout);
        expect(await Note.db.count(server), 7);
        expect(await device.db.unsentRowCount(), 0);
      },
    );
  });

  group('Given a server with a batch budget,', () {
    test(
      'should_send_the_device_batches_at_the_limit_and_every_row_when_it_is_authoritative',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 4),
        );
        final device = await openReplica(userId);
        await insertNotes(server, 10);
        final serverFrames = BatchRecorder();

        await peerOf(
          server,
          mapServerStream: (stream) => stream.map(serverFrames.record),
        ).syncOnce(device).timeout(sessionTimeout);

        expect(await Note.db.count(device), 10);
        expect(await titlesOf(device), await titlesOf(server));
        expect(serverFrames.dataSizes, [4, 4, 2]);
        expect(serverFrames.dataHasMore, [true, true, false]);
      },
    );

    test(
      'should_send_a_delete_stamped_before_its_rows_insert_with_the_insert_when_a_new_device_pulls',
      () async {
        // A higher delete generation can carry an older HLC than a concurrent
        // restore. The phone deletes, restores and deletes r (generation 4)
        // before the server deletes and restores it (generation 3): the server
        // keeps the phone's delete, stamped before its own restore, whose
        // stamp its insert of r carries. A tablet without the row drops a
        // delete that arrives in an earlier batch than the insert, and keeps r.
        final userId = const Uuid().v7obj();
        final server = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 1),
        );
        final phone = await openReplica(userId);
        final r = await Note.db.insertRow(server, Note(title: 'r'));
        await peerOf(server).syncOnce(phone).timeout(sessionTimeout);
        await Note.db.deleteRow(phone, r);
        await Note.db.insertRow(phone, Note(id: r.id, title: 'r'));
        await Note.db.deleteRow(phone, r);
        // The server's restore must be stamped after the phone's delete.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await Note.db.deleteRow(server, r);
        await Note.db.insertRow(server, Note(id: r.id, title: 'r2'));
        await peerOf(server).syncOnce(phone).timeout(sessionTimeout);
        expect(await titlesOf(server), isEmpty);
        expect(await titlesOf(phone), isEmpty);
        final tombstone = await tombstoneOf(server, r.id!);
        expect(tombstone.clFlag, 4);
        expect(tombstone.node!.uuidNodeId, await phone.db.currentNodeId());
        expect(
          tombstone.hlc < await insertHlcOf(server, r.id!),
          isTrue,
          reason: "the server's delete of r sorts before its insert of r",
        );
        final tablet = await openReplica(userId);
        final serverFrames = BatchRecorder();

        await peerOf(
          server,
          mapServerStream: (stream) => stream.map(serverFrames.record),
        ).syncOnce(tablet).timeout(sessionTimeout);

        expect(await titlesOf(tablet), isEmpty);
        final batchOfInsert = serverFrames.dataBatches.singleWhere(
          (batch) => batch.any(
            (change) => change is CrdtMergeInsert && change.uuidRowId == r.id,
          ),
        );
        expect(
          [
            for (final change in batchOfInsert)
              if (change.uuidRowId == r.id) kindsOf([change]).single,
          ],
          ['delete', 'insert'],
        );
      },
    );
  });

  group('Given a server with a batch budget and a projected foreign key,', () {
    test(
      'should_send_the_attempted_value_of_an_insert_that_comes_in_a_later_batch',
      () async {
        // The phone files n in folder f while the tablet deletes f. The
        // server keeps n's folder as attempted and shows null. Peers must get
        // the attempted fact to converge, and each batch reads the attempted
        // values of its own inserts only.
        final userId = const Uuid().v7obj();
        final server = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 3),
        );
        final phone = await openReplica(userId);
        final tablet = await openReplica(userId);
        final folder = await Folder.db.insertRow(phone, Folder(name: 'f'));
        await peerOf(server).syncOnce(phone).timeout(sessionTimeout);
        await peerOf(server).syncOnce(tablet).timeout(sessionTimeout);
        await Folder.db.deleteRow(tablet, folder);
        await insertNotes(phone, 6);
        final filed = await Note.db.insertRow(
          phone,
          Note(title: 'n', folderId: folder.id),
        );
        await peerOf(server).syncOnce(tablet).timeout(sessionTimeout);
        await peerOf(server).syncOnce(phone).timeout(sessionTimeout);
        final onServer = await Note.db.findById(server, filed.id!);
        expect(onServer!.folderId, isNull, reason: 'projected away');
        final laptop = await openReplica(userId);
        final serverFrames = BatchRecorder();

        await peerOf(
          server,
          mapServerStream: (stream) => stream.map(serverFrames.record),
        ).syncOnce(laptop).timeout(sessionTimeout);

        final batches = serverFrames.dataBatches;
        final batchOfFiled = batches.indexWhere(
          (batch) => batch.any((change) => change.uuidRowId == filed.id),
        );
        expect(batchOfFiled, greaterThan(0), reason: 'not the first batch');
        final insert = batches[batchOfFiled].singleWhere(
          (change) => change is CrdtMergeInsert && change.uuidRowId == filed.id,
        );
        expect(((insert as CrdtMergeInsert).data as Note).folderId, folder.id);
        expect(await Note.db.count(laptop), 7);
        expect((await Note.db.findById(laptop, filed.id!))!.folderId, isNull);
      },
    );
  });

  group('Given a device with row isolation,', () {
    test(
      'should_send_every_other_row_and_count_the_isolated_one_unsent_when_a_row_is_isolated',
      () async {
        final userId = const Uuid().v7obj();
        final isolation = TestRowIsolation();
        final server = await openReplica(userId);
        final device = await openReplica(userId, rowIsolation: isolation);
        await Note.db.insertRow(device, Note(title: 'a'));
        final b = await Note.db.insertRow(device, Note(title: 'b'));
        await Note.db.insertRow(device, Note(title: 'c'));
        isolation.isolatedRows.add(noteKey(b));

        await peerOf(server).syncOnce(device).timeout(sessionTimeout);

        expect(await titlesOf(server), ['a', 'c']);
        expect(await device.db.unsentRowCount(), 1);
        // The server's checkpoint is past the isolated row: only a release
        // brings it back.
        final checkpoint = await checkpointOf(
          server,
          await device.db.currentNodeId(),
        );
        expect(checkpoint! > await insertHlcOf(device, b.id!), isTrue);
      },
    );

    test(
      'should_never_send_the_row_again_when_it_leaves_isolation_without_a_release',
      () async {
        final userId = const Uuid().v7obj();
        final isolation = TestRowIsolation();
        final server = await openReplica(userId);
        final device = await openReplica(userId, rowIsolation: isolation);
        await Note.db.insertRow(device, Note(title: 'a'));
        final b = await Note.db.insertRow(device, Note(title: 'b'));
        await Note.db.insertRow(device, Note(title: 'c'));
        isolation.isolatedRows.add(noteKey(b));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);

        isolation.isolatedRows.clear();
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);

        expect(await titlesOf(server), ['a', 'c']);
      },
    );

    test(
      'should_send_the_row_in_full_with_its_latest_values_and_confirm_it_when_it_is_released',
      () async {
        final userId = const Uuid().v7obj();
        final isolation = TestRowIsolation();
        final server = await openReplica(userId);
        final device = await openReplica(userId, rowIsolation: isolation);
        await Note.db.insertRow(device, Note(title: 'a'));
        final b = await Note.db.insertRow(device, Note(title: 'b'));
        await Note.db.insertRow(device, Note(title: 'c'));
        isolation.isolatedRows.add(noteKey(b));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        await Note.db.updateRow(device, b.copyWith(title: 'b2'));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        expect(await titlesOf(server), ['a', 'c']);
        expect(isolation.confirmed, isEmpty);

        isolation
          ..isolatedRows.remove(noteKey(b))
          ..releasedRows.add(noteKey(b));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);

        expect(await titlesOf(server), ['a', 'b2', 'c']);
        expect(isolation.confirmed, [
          {noteKey(b)},
        ]);
        expect(isolation.releasedRows, isEmpty);
        expect(await device.db.unsentRowCount(), 0);
      },
    );

    test(
      'should_send_its_insert_and_delete_when_a_row_deleted_while_isolated_is_released',
      () async {
        final userId = const Uuid().v7obj();
        final isolation = TestRowIsolation();
        final server = await openReplica(userId);
        final device = await openReplica(userId, rowIsolation: isolation);
        await Note.db.insertRow(device, Note(title: 'a'));
        final b = await Note.db.insertRow(device, Note(title: 'b'));
        isolation.isolatedRows.add(noteKey(b));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        await Note.db.deleteRow(device, b);

        isolation
          ..isolatedRows.clear()
          ..releasedRows.add(noteKey(b));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);

        expect(await titlesOf(server), ['a']);
        final serverRow = await CrdtDataRow.db.findFirstRow(
          server,
          where: (t) => t.uuidRowId.equals(b.id!),
        );
        expect(serverRow, isNotNull);
        expect(serverRow!.isHidden, isTrue);
        expect(await device.db.unsentRowCount(), 0);
      },
    );

    test(
      'should_count_the_watched_unsent_rows_again_when_the_release_is_confirmed_after_the_session_commits',
      () async {
        // The session records its confirmed checkpoint, a commit the watch
        // counts again on, before it confirms the released rows, and an
        // implementation that keeps the sets durable takes a while to
        // confirm. Without a count after the confirmation, the watch would
        // keep the one that still held the released row.
        final userId = const Uuid().v7obj();
        final isolation = TestRowIsolation(
          confirmDelay: const Duration(milliseconds: 500),
        );
        final server = await openReplica(userId);
        final device = await openReplica(userId, rowIsolation: isolation);
        await Note.db.insertRow(device, Note(title: 'a'));
        final b = await Note.db.insertRow(device, Note(title: 'b'));
        await Note.db.insertRow(device, Note(title: 'c'));
        isolation.isolatedRows.add(noteKey(b));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        isolation
          ..isolatedRows.clear()
          ..releasedRows.add(noteKey(b));
        final counts = <int>[];
        final watch = device.db
            .watchUnsentRowCount(throttle: const Duration(milliseconds: 50))
            .listen(counts.add);
        addTearDown(watch.cancel);
        await eventually(() async => counts.isNotEmpty);
        expect(counts.last, 1);

        await peerOf(server).syncOnce(device).timeout(sessionTimeout);

        expect(isolation.releasedRows, isEmpty);
        await eventually(() async => counts.last == 0);
      },
    );

    test('should_not_send_a_row_that_is_both_isolated_and_released', () async {
      final userId = const Uuid().v7obj();
      final isolation = TestRowIsolation();
      final server = await openReplica(userId);
      final device = await openReplica(userId, rowIsolation: isolation);
      final a = await Note.db.insertRow(device, Note(title: 'a'));
      isolation
        ..isolatedRows.add(noteKey(a))
        ..releasedRows.add(noteKey(a));

      await peerOf(server).syncOnce(device).timeout(sessionTimeout);

      expect(await Note.db.count(server), 0);
      expect(isolation.confirmed, isEmpty);
    });

    test(
      'should_send_each_released_row_once_and_never_confirm_it_when_the_session_is_continuous',
      () async {
        // b is below the server's checkpoint (c was merged after it); d is
        // not (nothing after it was). Each reaches the collection a different
        // way, and each must go once per session, not every round.
        final userId = const Uuid().v7obj();
        final isolation = TestRowIsolation();
        final server = await openReplica(userId);
        final device = await openReplica(userId, rowIsolation: isolation);
        await Note.db.insertRow(device, Note(title: 'a'));
        final b = await Note.db.insertRow(device, Note(title: 'b'));
        await Note.db.insertRow(device, Note(title: 'c'));
        final d = await Note.db.insertRow(device, Note(title: 'd'));
        isolation.isolatedRows.addAll([noteKey(b), noteKey(d)]);
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        final checkpoint = await checkpointOf(
          server,
          await device.db.currentNodeId(),
        );
        expect(checkpoint! > await insertHlcOf(device, b.id!), isTrue);
        expect(checkpoint < await insertHlcOf(device, d.id!), isTrue);
        isolation
          ..isolatedRows.clear()
          ..releasedRows.addAll([noteKey(b), noteKey(d)]);
        final sent = <CrdtMergeChange>[];

        final live = peerOf(server, sent: sent).syncContinuously(device);
        addTearDown(live.cancel);
        await eventually(() async => await Note.db.count(server) == 4);
        // Several more rounds: a released row read every round would go again.
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        await live.cancel();

        for (final row in [b, d]) {
          expect(
            sent.where(
              (change) =>
                  change is CrdtMergeInsert && change.uuidRowId == row.id,
            ),
            hasLength(1),
            reason: row.title,
          );
        }
        expect(isolation.confirmed, isEmpty);
        expect(isolation.releasedRows, {noteKey(b), noteKey(d)});
        // Nothing confirmed them: d is above the recorded checkpoint, b only
        // counts as released.
        expect(await device.db.unsentRowCount(), 2);
      },
    );

    test(
      'should_not_confirm_a_released_row_when_the_session_closes_with_more_to_send',
      () async {
        // r was inserted and deleted while isolated. With one change per
        // batch, a peer built before hasMore closes after r's insert: the
        // server has r alive and still needs its delete. Confirming r there
        // would drop it from the released rows, and its delete, below the
        // checkpoints, would never go.
        final userId = const Uuid().v7obj();
        final isolation = TestRowIsolation();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 1),
          rowIsolation: isolation,
        );
        final r = await Note.db.insertRow(device, Note(title: 'r'));
        await Note.db.deleteRow(device, r);
        await Note.db.insertRow(device, Note(title: 'z'));
        isolation.isolatedRows.add(noteKey(r));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        isolation
          ..isolatedRows.clear()
          ..releasedRows.add(noteKey(r));
        OfflineSyncStreamEvent withoutFlag(OfflineSyncStreamEvent event) =>
            event is OfflineSyncEndOfBatch ? OfflineSyncEndOfBatch() : event;

        await peerOf(
          server,
          mapDeviceEvent: withoutFlag,
          mapServerStream: (stream) => stream.map(withoutFlag),
        ).syncOnce(device).timeout(sessionTimeout);
        expect(await titlesOf(server), ['r', 'z']);
        expect(isolation.confirmed, isEmpty);
        expect(isolation.releasedRows, {noteKey(r)});
        // r is below the recorded checkpoint: only the release counts it.
        expect(await device.db.unsentRowCount(), 1);

        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        expect(await titlesOf(server), ['z']);
        expect(isolation.confirmed, [
          {noteKey(r)},
        ]);
        expect(await device.db.unsentRowCount(), 0);
      },
    );

    test(
      'should_send_released_rows_across_batches_and_end_the_session_when_they_exceed_the_budget',
      () async {
        final userId = const Uuid().v7obj();
        final isolation = TestRowIsolation();
        final server = await openReplica(userId);
        final device = await openReplica(
          userId,
          batchBudget: OfflineSyncBatchBudget(maxChanges: 2),
          rowIsolation: isolation,
        );
        final notes = [
          for (var i = 0; i < 5; i++)
            await Note.db.insertRow(device, Note(title: 'r$i')),
        ];
        await Note.db.insertRow(device, Note(title: 'z'));
        isolation.isolatedRows.addAll(notes.map(noteKey));
        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        expect(await titlesOf(server), ['z']);
        isolation
          ..isolatedRows.clear()
          ..releasedRows.addAll(notes.map(noteKey));
        final deviceFrames = BatchRecorder();

        await peerOf(
          server,
          mapDeviceEvent: deviceFrames.record,
        ).syncOnce(device).timeout(sessionTimeout);

        expect(await Note.db.count(server), 6);
        expect(deviceFrames.dataSizes, [2, 2, 1]);
        expect(
          isolation.confirmed.expand((rows) => rows).toSet(),
          notes.map(noteKey).toSet(),
        );
        expect(isolation.releasedRows, isEmpty);
        expect(await device.db.unsentRowCount(), 0);
      },
    );

    test(
      'should_count_a_held_row_of_another_node_when_the_checkpoint_keeps_going_back',
      () async {
        // After three counts that each read a lower checkpoint (a server
        // losing data), the count falls back to every row of this node. A
        // held row another node wrote is not one of them, and must still
        // count.
        final userId = const Uuid().v7obj();
        final isolation = TestRowIsolation();
        final server = await openReplica(userId);
        final device = await openReplica(userId, rowIsolation: isolation);
        final deviceNode = await device.db.currentNodeId();
        final s = await Note.db.insertRow(server, Note(title: 's'));
        final confirmed = <Hlc>[];
        for (final title in ['a', 'b', 'c', 'd']) {
          await Note.db.insertRow(device, Note(title: title));
          await peerOf(server).syncOnce(device).timeout(sessionTimeout);
          confirmed.add((await ownCheckpointOf(device, deviceNode))!);
        }
        expect(await titlesOf(device), ['a', 'b', 'c', 'd', 's']);
        isolation.isolatedRows.add(noteKey(s));
        expect(await device.db.unsentRowCount(), 1);

        // Each count reads a checkpoint one row lower than the one before.
        final lowered = confirmed.reversed.skip(1).toList();
        var reads = 0;
        addTearDown(
          () => OfflineSyncEngine.debugOnUnsentRowCheckpointsRead = null,
        );
        OfflineSyncEngine.debugOnUnsentRowCheckpointsRead = () async {
          final read = reads++;
          if (read >= lowered.length) return;
          await setOwnCheckpoint(device, deviceNode, lowered[read]);
        };

        expect(await device.db.unsentRowCount(), 5);
        expect(reads, 3, reason: 'three counts, then the fallback');
      },
    );
  });
}

/// The checkpoint [device] recorded for its own node [nodeId].
Future<Hlc?> ownCheckpointOf(
  OfflineSyncDatabaseSession device,
  UuidValue nodeId,
) async {
  final own = await OfflineSyncSpaceNode.db.find(
    device,
    where: (t) => t.node.uuidNodeId.equals(nodeId),
  );
  return own.single.lastReceivedHlc;
}

/// Replaces the checkpoint [device] recorded for its own node [nodeId].
Future<void> setOwnCheckpoint(
  OfflineSyncDatabaseSession device,
  UuidValue nodeId,
  Hlc? hlc,
) async {
  final own = await OfflineSyncSpaceNode.db.find(
    device,
    where: (t) => t.node.uuidNodeId.equals(nodeId),
  );
  for (final spaceNode in own) {
    await OfflineSyncSpaceNode.db.updateRow(
      device,
      spaceNode.copyWith(lastReceivedHlc: hlc),
      columns: (t) => [t.lastReceivedHlc],
    );
  }
}

/// The key of [note] for [OfflineSyncRowIsolation].
OfflineSyncRowKey noteKey(Note note) =>
    (tableName: Note.t.tableName, rowId: note.id!);

/// An in-memory [OfflineSyncRowIsolation] that removes confirmed rows. An app
/// keeps both sets durable.
final class TestRowIsolation implements OfflineSyncRowIsolation {
  /// With [confirmDelay], a confirmation takes that long before it removes the
  /// rows, as writing durable sets does.
  TestRowIsolation({this.confirmDelay});

  /// How long a confirmation takes, or null for no wait.
  final Duration? confirmDelay;

  @override
  final Set<OfflineSyncRowKey> isolatedRows = {};

  @override
  final Set<OfflineSyncRowKey> releasedRows = {};

  /// Every confirmation, in order.
  final List<Set<OfflineSyncRowKey>> confirmed = [];

  @override
  Future<void> onReleasedRowsConfirmed(Set<OfflineSyncRowKey> rows) async {
    if (confirmDelay case final delay?) await Future<void>.delayed(delay);
    confirmed.add(rows);
    releasedRows.removeAll(rows);
  }
}
