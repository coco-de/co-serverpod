import 'dart:async';
import 'dart:io';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

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
/// | Device budget, `once` | Batches at the limit, every change sent, HLC prefix per batch, checkpoint at the last change, nothing unsent |
/// | Device budget, continuous | One batch per round, every change sent |
/// | An update stamped between two inserts | Sent: HLC order, not inserts first |
/// | Server budget (authoritative) | The device receives batches at the limit and every row |
/// | Payload limit, a change larger than the budget | Sent alone, the session goes on |
/// | A peer built before `hasMore` | Each side closes after one batch; the next session sends on |
/// | Unlimited peer | Still says `hasMore: false` |
/// | Isolated row | Left out, the rest sent, the checkpoint passes it, still counted unsent |
/// | Row that leaves isolation without release | Never sent again (the contract) |
/// | Released row | Sent in full with its latest values, confirmed, then not counted |
/// | Released row deleted while isolated | Its insert and delete arrive |
/// | Released row, continuous session | Sent once per session, never confirmed |
/// | Released row, session closed with more to send | Not confirmed; the next session sends the rest |
/// | Released rows over the budget, `once` | Sent across batches, the session ends |
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

        await peerOf(server).syncOnce(device).timeout(sessionTimeout);
        expect(await titlesOf(server), ['z']);
        expect(isolation.confirmed, [
          {noteKey(r)},
        ]);
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
  });
}

/// The key of [note] for [OfflineSyncRowIsolation].
OfflineSyncRowKey noteKey(Note note) =>
    (tableName: Note.t.tableName, rowId: note.id!);

/// An in-memory [OfflineSyncRowIsolation] that removes confirmed rows. An app
/// keeps both sets durable.
final class TestRowIsolation implements OfflineSyncRowIsolation {
  @override
  final Set<OfflineSyncRowKey> isolatedRows = {};

  @override
  final Set<OfflineSyncRowKey> releasedRows = {};

  /// Every confirmation, in order.
  final List<Set<OfflineSyncRowKey>> confirmed = [];

  @override
  void onReleasedRowsConfirmed(Set<OfflineSyncRowKey> rows) {
    confirmed.add(rows);
    releasedRows.removeAll(rows);
  }
}

/// Records the batches one side sends: the changes before each end-of-batch
/// frame and the frame itself.
final class BatchRecorder {
  final List<({List<CrdtMergeChange> changes, OfflineSyncEndOfBatch end})>
  _batches = [];
  var _current = <CrdtMergeChange>[];

  /// Records [event] and returns it unchanged.
  OfflineSyncStreamEvent record(OfflineSyncStreamEvent event) {
    switch (event) {
      case OfflineSyncMergeChunk(:final changes):
        _current.addAll(changes);
      case final OfflineSyncEndOfBatch end:
        _batches.add((changes: _current, end: end));
        _current = [];
      default:
        break;
    }
    return event;
  }

  /// Every end-of-batch frame.
  List<OfflineSyncEndOfBatch> get endOfBatches => [
    for (final batch in _batches) batch.end,
  ];

  /// The batches that carried changes.
  List<List<CrdtMergeChange>> get dataBatches => [
    for (final batch in _batches)
      if (batch.changes.isNotEmpty) batch.changes,
  ];

  /// The size of each batch that carried changes.
  List<int> get dataSizes => [for (final batch in dataBatches) batch.length];

  /// The `hasMore` of each batch that carried changes.
  List<bool?> get dataHasMore => [
    for (final batch in _batches)
      if (batch.changes.isNotEmpty) batch.end.hasMore,
  ];

  /// Whether every end-of-batch frame carried the flag.
  bool get everyHasMoreSet =>
      _batches.every((batch) => batch.end.hasMore != null);
}
