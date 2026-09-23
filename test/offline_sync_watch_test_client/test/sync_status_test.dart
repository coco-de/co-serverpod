import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_database/serverpod_database.dart'
    show DatabaseSession;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

import 'support/sync_harness.dart';

/// The unsent row count and the sync status of [OfflineSyncStatusTracker],
/// between two real SQLite replicas, one playing the Serverpod endpoint
/// (authoritative) as in `model_watch_test.dart` (unibook#14183).
///
/// The fork has no acknowledgement, so the count rests on what the device
/// records from the server: its handshake checkpoint (replaced every session)
/// and the end of a `once` session the server closed. The cases pin both, and
/// that a failed round never lowers the count.
///
/// | Case | Expected count |
/// |---|---|
/// | Offline writes, no sync | Rows written, a deleted unsynced row included |
/// | Synced row deleted offline | 1 |
/// | Successful round | 0, in the same event as `lastSuccessAt` |
/// | Server rejects the round (K2) | Unchanged |
/// | Server merged, device failed | Unchanged until the next round |
/// | Reopened after a round | 0 (persisted) |
/// | Server that lost the data | All rows again, from its handshake |
/// | Server restored from a backup | The rows after its lower checkpoint |
/// | Rows in a shared space too | 0 after a round: every space confirmed |
/// | Writes committed while a round collects | Counted after it, sent next |
/// | Checkpoint lowered during a count | Counted again from the lower one |
/// | A count that fails | Unknown (null), never 0 or the last count |
///
/// The device's checkpoint writes must not re-project every space on an idle
/// round, and a count read before a round ended is never the round's outcome.
void main() {
  late Directory tempDir;
  final client = Client('http://localhost:1/');
  var databaseCount = 0;
  final t0 = DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch,
    isUtc: true,
  );
  const oneMillisecond = Duration(milliseconds: 1);
  const oneHour = Duration(hours: 1);

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_status_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  Future<T> at<T>(DateTime wallTime, Future<T> Function() body) =>
      withClock(Clock.fixed(wallTime), body);

  String newPath() => p.join(tempDir.path, 'replica-${++databaseCount}.db');

  Future<OfflineSyncDatabaseSession> openReplica(
    UuidValue userId, {
    String? path,
    int syncBatchSize = OfflineSyncEngine.defaultSyncBatchSize,
  }) async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(path ?? newPath()),
      syncTables: syncTables,
      persistentUserId: userId,
      syncBatchSize: syncBatchSize,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  OfflineSyncStatusTracker trackerOf(
    OfflineSyncClient peer,
    OfflineSyncDatabaseSession device, {
    bool watchUnsentRows = true,
  }) {
    final tracker = OfflineSyncStatusTracker(
      peer,
      device,
      watchUnsentRows: watchUnsentRows,
      unsentRowsThrottle: const Duration(milliseconds: 30),
    );
    addTearDown(tracker.dispose);
    return tracker;
  }

  List<OfflineSyncStatus> eventsOf(OfflineSyncStatusTracker tracker) {
    final events = <OfflineSyncStatus>[];
    final subscription = tracker.statusChanges.listen(events.add);
    addTearDown(subscription.cancel);
    return events;
  }

  Future<void> countSettles(OfflineSyncStatusTracker tracker, int count) =>
      eventually(() async => tracker.status.unsentRowCount == count);

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

  group('Given a device that writes while offline,', () {
    test(
      'should_count_each_written_row_once_without_a_sync_including_an_unsynced_delete',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final tracker = trackerOf(peerOf(server), device);
        await countSettles(tracker, 0);

        final a = await Note.db.insertRow(device, Note(title: 'a'));
        final b = await Note.db.insertRow(device, Note(title: 'b'));
        await Note.db.updateRow(device, a.copyWith(title: 'a2'));

        // The watch picks the writes up; nothing synced.
        await countSettles(tracker, 2);
        expect(await tracker.countUnsentRows(), 2);
        expect(tracker.status.lastSuccessAt, isNull);
        expect(tracker.status.isIdle, isFalse);

        // Its insert and delete are both sent, so it still counts once.
        await Note.db.deleteRow(device, b);
        expect(await device.db.unsentRowCount(), 2);
        expect(await Note.db.count(server), 0);

        await tracker.syncOnce();
        expect(tracker.status.unsentRowCount, 0);
        expect((await Note.db.find(server)).map((note) => note.title), ['a2']);
      },
    );

    test(
      'should_count_a_synced_row_deleted_offline_until_it_is_sent',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final tracker = trackerOf(peerOf(server), device);
        final a = await Note.db.insertRow(device, Note(title: 'a'));
        await tracker.syncOnce();
        expect(tracker.status.unsentRowCount, 0);

        await Note.db.deleteRow(device, a);

        await countSettles(tracker, 1);
        expect(await device.db.unsentRowCount(), 1);

        await tracker.syncOnce();
        expect(tracker.status.unsentRowCount, 0);
        expect(await Note.db.count(server), 0);
      },
    );
  });

  group('Given a successful syncOnce round,', () {
    test(
      'should_publish_the_success_and_a_zero_count_in_one_event_without_counting_server_rows',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        await Note.db.insertRow(server, Note(title: 'server'));
        await Note.db.insertRow(device, Note(title: 'd1'));
        await Note.db.insertRow(device, Note(title: 'd2'));
        final tracker = trackerOf(peerOf(server), device);
        await countSettles(tracker, 2);
        final events = eventsOf(tracker);

        await tracker.syncOnce();
        await pumpEventQueue();

        final firstSuccess = events.firstWhere((e) => e.lastSuccessAt != null);
        expect(firstSuccess.phase, OfflineSyncPhase.idle);
        expect(firstSuccess.unsentRowCount, 0);
        expect(tracker.status.isIdle, isTrue);
        // The server's row arrived and, written by another node, never counts.
        expect(await Note.db.count(device), 3);
        expect(await device.db.unsentRowCount(), 0);
      },
    );

    test(
      'should_keep_the_count_after_reopening_the_database_and_count_all_without_a_sync',
      () async {
        final userId = const Uuid().v7obj();
        final controlUserId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final syncedPath = newPath();
        final synced = await openReplica(userId, path: syncedPath);
        final unsyncedPath = newPath();
        final unsynced = await openReplica(controlUserId, path: unsyncedPath);
        for (final device in [synced, unsynced]) {
          await Note.db.insertRow(device, Note(title: 'a'));
          await Note.db.insertRow(device, Note(title: 'b'));
        }
        final tracker = trackerOf(peerOf(server), synced);
        await tracker.syncOnce();
        expect(tracker.status.unsentRowCount, 0);
        await tracker.dispose();
        await synced.close();
        await unsynced.close();

        final reopened = await openReplica(userId, path: syncedPath);
        final reopenedTracker = trackerOf(peerOf(server), reopened);
        final control = await openReplica(controlUserId, path: unsyncedPath);
        final controlTracker = trackerOf(peerOf(server), control);

        await eventually(
          () async =>
              reopenedTracker.status.unsentRowCount != null &&
              controlTracker.status.unsentRowCount != null,
        );
        expect(reopenedTracker.status.unsentRowCount, 0);
        expect(controlTracker.status.unsentRowCount, 2);
      },
    );
  });

  group('Given a process whose schema registry changed,', () {
    // A fresh replica registers the synchronized schema, so every new wrapper
    // over it re-projects every space on its first operation. The device's
    // checkpoint writes must not open one: an idle round used to pay it twice
    // (the handshake and the close), once per handshaken space plus one.
    test('should_not_rebuild_projections_in_an_idle_round', () async {
      final userId = const Uuid().v7obj();
      final opening = CrdtMutationRecorder.debugProjectionRebuildCount;
      final server = await openReplica(userId);
      final device = await openReplica(userId);
      expect(
        CrdtMutationRecorder.debugProjectionRebuildCount - opening,
        greaterThan(0),
        reason:
            'the fixture must have a changed registry, else this is vacuous',
      );
      await Note.db.insertRow(device, Note(title: 'a'));
      final tracker = trackerOf(peerOf(server), device, watchUnsentRows: false);
      await tracker.syncOnce();
      expect(tracker.status.unsentRowCount, 0);

      final idle = CrdtMutationRecorder.debugProjectionRebuildCount;
      await tracker.syncOnce();
      await tracker.syncOnce();

      expect(CrdtMutationRecorder.debugProjectionRebuildCount - idle, 0);
      expect(tracker.status.unsentRowCount, 0);
    });
  });

  group('Given a checkpoint that goes back while the count runs,', () {
    tearDown(() => OfflineSyncEngine.debugOnUnsentRowCheckpointsRead = null);

    // The handshake of a server that lost the data replaces the checkpoint
    // with a lower one. Committed between the count's checkpoint and row
    // reads, it must not leave the count at the old, higher checkpoint.
    test(
      'should_count_again_from_the_lowered_checkpoint_instead_of_counting_low',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final deviceNodeId = await device.db.currentNodeId();
        await Note.db.insertRow(device, Note(title: 'a'));
        await Note.db.insertRow(device, Note(title: 'b'));
        await peerOf(server).syncOnce(device);
        expect(await device.db.unsentRowCount(), 0);

        var reads = 0;
        OfflineSyncEngine.debugOnUnsentRowCheckpointsRead = () async {
          if (reads++ > 0) return;
          final own = await OfflineSyncSpaceNode.db.find(
            device,
            where: (t) => t.node.uuidNodeId.equals(deviceNodeId),
          );
          expect(own.map((spaceNode) => spaceNode.lastReceivedHlc), [
            isNotNull,
          ]);
          for (final spaceNode in own) {
            await OfflineSyncSpaceNode.db.updateRow(
              device,
              spaceNode.copyWith(lastReceivedHlc: null),
              columns: (t) => [t.lastReceivedHlc],
            );
          }
        };

        expect(await device.db.unsentRowCount(), 2);
        expect(reads, 2, reason: 'the second attempt reads the lowered one');
      },
    );
  });

  group('Given local writes committed while a round collects its changes,', () {
    // The round reads the pending inserts, updates and deletes with one query
    // each. Read at different moments, a later update (read after the inserts)
    // could be sent while an earlier insert was missed, and the checkpoint
    // advanced past the update then skipped the insert for good: the server
    // never got it and the count said 0.
    test(
      'should_count_both_after_the_round_and_send_both_in_the_next_instead_of_losing_the_insert',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        // One change per chunk, so the round yields between the change kinds.
        final device = await openReplica(userId, syncBatchSize: 1);
        final q = await Note.db.insertRow(device, Note(title: 'q'));
        await peerOf(server).syncOnce(device);
        await Note.db.insertRow(device, Note(title: 'p'));
        expect(await device.db.unsentRowCount(), 1);

        await _syncOnceWritingAtFirstChunk(server, device, () async {
          // An insert, then an update in a later transaction (a higher HLC).
          await Note.db.insertRow(device, Note(title: 'r'));
          await Note.db.updateRow(device, q.copyWith(title: 'q2'));
        });

        expect(await _titlesOf(server), {'q', 'p'});
        expect(await device.db.unsentRowCount(), 2);

        await peerOf(server).syncOnce(device);

        expect(await _titlesOf(server), {'q2', 'p', 'r'});
        expect(await device.db.unsentRowCount(), 0);
      },
    );

    // Within the snapshot the three queries still run one after another. A
    // write committing between them must stay out of all three, or the update
    // read last goes without the insert read first, as above.
    test(
      'should_keep_writes_committed_between_the_pending_reads_out_of_the_round',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final deviceDatabase = await client.createSession(newPath());
        final device = OfflineSyncDatabaseSession.wraps(
          deviceDatabase,
          syncTables: syncTables,
          persistentUserId: userId,
        );
        addTearDown(device.close);
        await device.db.initialize();
        final q = await Note.db.insertRow(device, Note(title: 'q'));
        await peerOf(server).syncOnce(device);

        Future<void>? writes;
        addTearDown(() => OfflineSyncEngine.debugOnPendingRowsRead = null);
        OfflineSyncEngine.debugOnPendingRowsRead = (session) async {
          if (writes != null || !identical(session.db, deviceDatabase.db)) {
            return;
          }
          // Outside the collection's zone, as another caller would write.
          writes = Zone.root.run(() async {
            await Note.db.insertRow(device, Note(title: 'r'));
            await Note.db.updateRow(device, q.copyWith(title: 'q2'));
          });
          // Time to commit both, unless the snapshot holds them off.
          await Future<void>.delayed(const Duration(milliseconds: 100));
        };

        await peerOf(server).syncOnce(device);
        expect(writes, isNotNull, reason: 'the device must have collected');
        await writes;

        expect(await _titlesOf(server), {'q'});
        expect(await device.db.unsentRowCount(), 2);

        await peerOf(server).syncOnce(device);

        expect(await _titlesOf(server), {'q2', 'r'});
        expect(await device.db.unsentRowCount(), 0);
      },
    );
  });

  group('Given a round that fails,', () {
    test(
      'should_keep_the_count_and_record_a_typed_failure_when_the_server_rejects_the_push',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final tracker = trackerOf(peerOf(server, wire: true), device);
        await at(t0.add(oneHour + oneMillisecond), () {
          return Note.db.insertRow(device, Note(title: 'from the future'));
        });
        await countSettles(tracker, 1);

        final error = await at(t0, () => errorOf(tracker.syncOnce()));

        expect(error, isA<OfflineSyncRemoteException>());
        final failed = tracker.status;
        expect(failed.phase, OfflineSyncPhase.idle);
        expect(failed.lastFailure?.code, OfflineSyncFailureReason.clockDrift);
        expect(failed.lastFailureAt, t0);
        expect(failed.unsentRowCount, 1);
        expect(failed.lastSuccessAt, isNull);
        expect(failed.needsAttention, isFalse, reason: 'clock drift clears');
        expect(await Note.db.count(server), 0);

        await at(t0.add(oneMillisecond), () => tracker.syncOnce());

        final recovered = tracker.status;
        expect(recovered.unsentRowCount, 0);
        expect(recovered.lastFailure, isNull);
        expect(recovered.lastFailureAt, isNull);
        expect(recovered.lastSuccessAt, t0.add(oneMillisecond));
        expect(await Note.db.count(server), 1);
      },
    );

    // The WebSocket case of clock_drift_test.dart: the server merges the
    // device batch and persists its checkpoint before the device fails on the
    // server batch. The device cannot tell, so it keeps counting the row until
    // the next round, whose handshake reports it covered.
    test(
      'should_keep_the_count_when_the_server_merged_and_clear_it_next_round_without_a_resend',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final deviceNodeId = await device.db.currentNodeId();
        final sent = <CrdtMergeChange>[];
        final failingPeer = peerOf(
          server,
          sent: sent,
          holdServerDataUntil: () => eventually(
            () async => await checkpointOf(server, deviceNodeId) != null,
          ),
        );
        await at(t0, () => Note.db.insertRow(device, Note(title: 'device')));
        await at(t0.add(oneHour + oneMillisecond), () {
          return Note.db.insertRow(server, Note(title: 'from the future'));
        });
        final failingTracker = trackerOf(failingPeer, device);
        await countSettles(failingTracker, 1);

        expect(
          await at(t0, () => errorOf(failingTracker.syncOnce())),
          isA<ClockDriftException>(),
        );
        expect(await Note.db.count(server), 2, reason: 'the server merged it');
        expect(failingTracker.status.unsentRowCount, 1);
        expect(
          failingTracker.status.lastFailure?.code,
          OfflineSyncFailureReason.clockDriftBehind,
        );

        sent.clear();
        final tracker = trackerOf(peerOf(server, sent: sent), device);
        await at(t0.add(oneMillisecond), () => tracker.syncOnce());

        expect(tracker.status.unsentRowCount, 0);
        expect(
          sent.where((change) => change.uuidNodeId == deviceNodeId),
          isEmpty,
        );
      },
    );

    test(
      'should_count_every_row_again_when_the_server_handshake_reports_less',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        await Note.db.insertRow(device, Note(title: 'a'));
        await Note.db.insertRow(device, Note(title: 'b'));
        final tracker = trackerOf(peerOf(server), device);
        await tracker.syncOnce();
        expect(tracker.status.unsentRowCount, 0);

        // A server replica that never saw the device, as after a restore, cut
        // off right after its handshake so the device cannot resend anything.
        final restored = await openReplica(userId);
        final cutTracker = trackerOf(
          peerOf(restored, mapServerStream: _cutAfterFirstBatch),
          device,
        );

        expect(await errorOf(cutTracker.syncOnce()), isA<StateError>());
        expect(cutTracker.status.unsentRowCount, 2);
        expect(await device.db.unsentRowCount(), 2);
        expect(await Note.db.count(restored), 0);
      },
    );

    // The case above clears the checkpoint (a server that never saw the
    // device). A server restored from a backup reports a lower one instead,
    // which must replace the higher one the device recorded.
    test(
      'should_count_the_rows_after_the_lower_checkpoint_a_restored_server_reports',
      () async {
        final userId = const Uuid().v7obj();
        final serverPath = newPath();
        final server = await openReplica(userId, path: serverPath);
        final device = await openReplica(userId);
        final deviceNodeId = await device.db.currentNodeId();
        await Note.db.insertRow(device, Note(title: 'a'));
        await trackerOf(peerOf(server), device).syncOnce();

        // A backup holding only the first row, then the server goes on.
        await server.close();
        final backupPath = newPath();
        for (final suffix in ['', '-wal', '-shm']) {
          final file = File('$serverPath$suffix');
          if (file.existsSync()) await file.copy('$backupPath$suffix');
        }
        final live = await openReplica(userId, path: serverPath);
        await Note.db.insertRow(device, Note(title: 'b'));
        await Note.db.insertRow(device, Note(title: 'c'));
        final liveTracker = trackerOf(peerOf(live), device);
        await liveTracker.syncOnce();
        expect(liveTracker.status.unsentRowCount, 0);

        final restored = await openReplica(userId, path: backupPath);
        expect(
          await checkpointOf(restored, deviceNodeId),
          isNotNull,
          reason: 'a lower checkpoint, not none',
        );
        final cutTracker = trackerOf(
          peerOf(restored, mapServerStream: _cutAfterFirstBatch),
          device,
        );

        expect(await errorOf(cutTracker.syncOnce()), isA<StateError>());
        expect(cutTracker.status.unsentRowCount, 2);
        expect(await device.db.unsentRowCount(), 2);
        expect(await Note.db.count(restored), 1);
      },
    );
  });

  group('Given a device that also writes in a shared space,', () {
    // Each space has its own checkpoint. A round confirms every space it
    // handshook, not only the first.
    test(
      'should_confirm_every_handshaken_space_at_the_end_of_a_round',
      () async {
        final userId = const Uuid().v7obj();
        final shared = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final deviceNodeId = await device.db.currentNodeId();
        final sharedSpace = await OfflineSyncSpace.db.insertRow(
          server,
          OfflineSyncSpace(uuidSpaceId: shared),
        );
        await OfflineSyncSpaceMember.db.insertRow(
          server,
          OfflineSyncSpaceMember(
            spaceId: sharedSpace.id!,
            userUuid: userId,
            role: OfflineSyncSpaceRole.readWrite,
          ),
        );
        final tracker = trackerOf(
          peerOf(server),
          device,
          watchUnsentRows: false,
        );
        // The first round tells the device about the shared space.
        await tracker.syncOnce();

        await Note.db.insertRow(device, Note(title: 'personal'));
        await device.db.transactionForUser(
          userId,
          (transaction) => Note.db.insertRow(
            device,
            Note(title: 'shared'),
            transaction: transaction,
          ),
          spaceId: shared,
        );
        expect(await device.db.unsentRowCount(), 2);

        await tracker.syncOnce();

        expect(tracker.status.unsentRowCount, 0);
        final own = await OfflineSyncSpaceNode.db.find(
          device,
          where: (t) => t.node.uuidNodeId.equals(deviceNodeId),
        );
        expect(
          own.where((spaceNode) => spaceNode.lastReceivedHlc != null),
          hasLength(2),
          reason: 'one confirmed checkpoint per space',
        );
      },
    );
  });

  group('Given watchUnsentRowCount,', () {
    test(
      'should_emit_on_listen_after_offline_writes_and_after_a_round_but_not_for_an_unchanged_count',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        const throttle = Duration(milliseconds: 30);
        final counts = <int>[];
        final countSubscription = device.db
            .watchUnsentRowCount(throttle: throttle)
            .listen(counts.add);
        addTearDown(countSubscription.cancel);
        var triggers = 0;
        final triggerSubscription = device.db
            .watchUnsentRowCountTriggers(throttle: throttle)
            .listen((_) => triggers++);
        addTearDown(triggerSubscription.cancel);

        await eventually(() async => counts.length == 1 && triggers == 1);
        expect(counts, [0]);

        final a = await Note.db.insertRow(device, Note(title: 'a'));
        await eventually(() async => counts.length == 2);
        expect(counts, [0, 1]);

        // A commit that leaves the count as it is.
        final before = triggers;
        await Note.db.updateRow(device, a.copyWith(title: 'a2'));
        await eventually(() async => triggers > before);
        await Future<void>.delayed(throttle * 4);
        expect(counts, [0, 1]);

        await Note.db.insertRow(device, Note(title: 'b'));
        await eventually(() async => counts.length == 3);
        expect(counts, [0, 1, 2]);

        await peerOf(server).syncOnce(device);
        await eventually(() async => counts.last == 0);
        expect(counts, [0, 1, 2, 0]);
      },
    );
  });

  group('Given the status stream,', () {
    test(
      'should_publish_syncing_then_the_outcome_once_for_joined_calls_and_skip_equal_values',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        await Note.db.insertRow(device, Note(title: 'a'));
        var opened = 0;
        final peer = peerOf(
          server,
          mapServerStream: (stream) {
            opened++;
            return stream;
          },
        );
        // Without the watch, only the tracker's own counts publish, so the
        // exact sequence is fixed.
        final tracker = trackerOf(peer, device, watchUnsentRows: false);
        await countSettles(tracker, 1);
        final events = eventsOf(tracker);

        await Future.wait([tracker.syncOnce(), tracker.syncOnce()]);
        await tracker.refreshUnsentRowCount();
        await pumpEventQueue();

        expect(opened, 1);
        expect(
          [
            for (final event in events)
              (event.phase, event.unsentRowCount, event.lastSuccessAt != null),
          ],
          [
            (OfflineSyncPhase.syncing, 1, false),
            (OfflineSyncPhase.idle, 0, true),
          ],
        );
      },
    );

    test('should_publish_syncing_then_the_failure_with_the_count', () async {
      final userId = const Uuid().v7obj();
      final server = await openReplica(userId);
      final device = await openReplica(userId);
      await at(t0.add(oneHour + oneMillisecond), () {
        return Note.db.insertRow(device, Note(title: 'from the future'));
      });
      final tracker = trackerOf(
        peerOf(server, wire: true),
        device,
        watchUnsentRows: false,
      );
      await countSettles(tracker, 1);
      final events = eventsOf(tracker);

      await at(t0, () => errorOf(tracker.syncOnce()));
      await pumpEventQueue();

      expect(
        [
          for (final event in events)
            (event.phase, event.unsentRowCount, event.lastFailure?.code),
        ],
        [
          (OfflineSyncPhase.syncing, 1, null),
          (OfflineSyncPhase.idle, 1, OfflineSyncFailureReason.clockDrift),
        ],
      );
    });

    test(
      'should_record_a_continuous_failure_without_a_phase_or_a_success',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final tracker = trackerOf(peerOf(server, wire: true), device);
        await at(t0.add(oneHour + oneMillisecond), () {
          return Note.db.insertRow(device, Note(title: 'from the future'));
        });
        await countSettles(tracker, 1);
        final events = eventsOf(tracker);

        final live = await at(t0, () async => tracker.syncContinuously());
        addTearDown(live.cancel);

        expect(await errorOf(live.done), isA<OfflineSyncRemoteException>());
        await eventually(() async => tracker.status.lastFailure != null);
        expect(
          tracker.status.lastFailure?.code,
          OfflineSyncFailureReason.clockDrift,
        );
        expect(tracker.status.lastFailureAt, t0);
        expect(tracker.status.lastSuccessAt, isNull);
        expect(tracker.status.unsentRowCount, 1);
        expect(
          events.map((event) => event.phase),
          everyElement(OfflineSyncPhase.idle),
        );
      },
    );

    // The sign-out warning rests on this: a count that fails is unknown, never
    // zero and never the last count.
    test(
      'should_publish_an_unknown_count_instead_of_zero_or_the_last_one_when_counting_fails',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        await Note.db.insertRow(device, Note(title: 'a'));
        final tracker = trackerOf(
          peerOf(server),
          device,
          watchUnsentRows: false,
        );
        await countSettles(tracker, 1);
        final events = eventsOf(tracker);

        await device.close();
        expect(await errorOf(tracker.countUnsentRows()), isNotNull);
        await tracker.refreshUnsentRowCount();

        expect(tracker.status.unsentRowCount, isNull);
        expect(tracker.status.isIdle, isFalse);

        expect(await errorOf(tracker.syncOnce()), isNotNull);
        await pumpEventQueue();

        expect(
          [
            for (final event in events)
              (event.phase, event.unsentRowCount, event.lastFailure != null),
          ],
          [
            (OfflineSyncPhase.idle, null, false),
            (OfflineSyncPhase.syncing, null, false),
            (OfflineSyncPhase.idle, null, true),
          ],
        );
      },
    );

    // A count that read the row before the round sent it must not be
    // published as the round's outcome: that would pair lastSuccessAt with a
    // count the round already made stale.
    test(
      'should_publish_the_outcome_with_a_count_started_after_the_round_not_one_in_progress',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        await Note.db.insertRow(device, Note(title: 'a'));
        final roundEnded = Completer<void>();
        Completer<void>? hold;
        final countRead = Completer<void>();
        var counts = 0;
        final tracker = OfflineSyncStatusTracker(
          _SignalingClient(peerOf(server), roundEnded),
          device,
          watchUnsentRows: false,
          unsentRowCounter: () async {
            counts++;
            final count = await device.db.unsentRowCount();
            if (hold case final gate?) {
              hold = null;
              countRead.complete();
              await gate.future;
            }
            return count;
          },
        );
        addTearDown(tracker.dispose);
        await countSettles(tracker, 1);
        final events = eventsOf(tracker);

        final release = hold = Completer<void>();
        final heldCount = tracker.refreshUnsentRowCount();
        await countRead.future;
        final round = tracker.syncOnce();
        await roundEnded.future;
        // Let the tracker take the end of the round while the count is held.
        await pumpEventQueue();
        release.complete();
        await Future.wait([heldCount, round]);

        expect(counts, 3, reason: 'on creation, the held one, one after');
        final success = events.firstWhere((e) => e.lastSuccessAt != null);
        expect(success.unsentRowCount, 0);
        expect(tracker.status.unsentRowCount, 0);
      },
    );

    test('should_publish_nothing_and_refuse_to_sync_after_dispose', () async {
      final userId = const Uuid().v7obj();
      final server = await openReplica(userId);
      final device = await openReplica(userId);
      final tracker = trackerOf(peerOf(server), device);
      await countSettles(tracker, 0);
      final events = eventsOf(tracker);

      await tracker.dispose();
      await Note.db.insertRow(device, Note(title: 'after dispose'));
      await tracker.refreshUnsentRowCount();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(events, isEmpty);
      expect(tracker.status.unsentRowCount, 0);
      expect(await errorOf(tracker.syncOnce()), isA<StateError>());
      expect(await Note.db.count(server), 0);
    });
  });
}

/// Forwards [source] up to and including its first [OfflineSyncEndOfBatch],
/// the end of the server's handshake, then fails as a dropped connection would
/// and stops reading the server.
/// The note titles stored in [session].
Future<Set<String>> _titlesOf(DatabaseSession session) async => {
  for (final note in await Note.db.find(session)) note.title,
};

/// Runs one `once` round of [device] against [server], pausing the device's
/// stream at its first [OfflineSyncMergeChunk] to run [write] meanwhile.
Future<void> _syncOnceWritingAtFirstChunk(
  OfflineSyncDatabaseSession server,
  OfflineSyncDatabaseSession device,
  Future<void> Function() write,
) async {
  final toServer = StreamController<OfflineSyncStreamEvent>();
  final fromServer = server.db.sync(
    inbound: toServer.stream,
    once: true,
    mode: OfflineSyncPeerMode.authoritative,
  );
  var wrote = false;
  final done = Completer<void>();
  late final StreamSubscription<OfflineSyncStreamEvent> subscription;
  subscription = device.db
      .sync(inbound: fromServer, once: true, mode: OfflineSyncPeerMode.follower)
      .listen(
        (event) async {
          toServer.add(event);
          if (event is OfflineSyncClose) unawaited(toServer.close());
          if (wrote || event is! OfflineSyncMergeChunk) return;
          wrote = true;
          subscription.pause();
          await write();
          subscription.resume();
        },
        onDone: done.complete,
        onError: done.completeError,
      );
  await done.future;
  expect(wrote, isTrue, reason: 'the round must have sent a chunk');
}

Stream<OfflineSyncStreamEvent> _cutAfterFirstBatch(
  Stream<OfflineSyncStreamEvent> source,
) async* {
  await for (final event in source) {
    yield event;
    if (event is OfflineSyncEndOfBatch) {
      throw StateError('Connection cut after the handshake.');
    }
  }
}

/// Delegates to [_inner] and completes [_roundEnded] when its first
/// [syncOnce] returns, before the caller resumes.
class _SignalingClient extends OfflineSyncClient {
  _SignalingClient(this._inner, this._roundEnded)
    : super(({required changes, required once}) {
        throw UnsupportedError('Syncs through the inner client.');
      });

  final OfflineSyncClient _inner;
  final Completer<void> _roundEnded;

  @override
  Future<void> syncOnce(
    DatabaseSession session, {
    OfflineSyncOnMergeSuccess? onMergeSuccess,
  }) async {
    await _inner.syncOnce(session, onMergeSuccess: onMergeSuccess);
    if (!_roundEnded.isCompleted) _roundEnded.complete();
  }
}
