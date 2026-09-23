import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
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
  }) async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(path ?? newPath()),
      syncTables: syncTables,
      persistentUserId: userId,
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
