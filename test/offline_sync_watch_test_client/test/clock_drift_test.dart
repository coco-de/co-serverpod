import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

/// Clock drift between two real SQLite replicas, one playing the Serverpod
/// endpoint (authoritative) as in `model_watch_test.dart`.
///
/// Every step runs with the wall clock pinned by [at]. `withClock` holds across
/// the whole sync round because both generators are listened to inside the
/// zone that calls `syncOnce`. The instant [t0] is aligned to a millisecond so
/// the exact edges (drift equal to the limit) hold for both `Hlc.increment`
/// and `Hlc.merge`.
///
/// | Case | Who rejects | Expected |
/// |---|---|---|
/// | K1 device behind | device merging a server batch | `ClockDriftException(remoteAhead)` on the device |
/// | K2 device ahead | server merging a device batch | `OfflineSyncRemoteException(clockDrift)` on the device |
/// | K3 device clock moved back | the device's next local write | `ClockDriftException(localAhead)` |
/// | device limit below the server's | device merging a batch another device pulled ahead | K1 on a device whose clock is right |
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
    tempDir = await Directory.systemTemp.createTemp('offline_sync_drift_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  Future<T> at<T>(DateTime wallTime, Future<T> Function() body) =>
      withClock(Clock.fixed(wallTime), body);

  /// Opens a replica. The generated `createSyncSession` does not forward
  /// `maxClockDrift`, so a replica with its own limit is opened the way the
  /// README tells apps to.
  Future<OfflineSyncDatabaseSession> openReplica(
    UuidValue userId, {
    Duration? maxClockDrift,
  }) async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(
        p.join(tempDir.path, 'replica-${++databaseCount}.db'),
      ),
      syncTables: syncTables,
      persistentUserId: userId,
      maxClockDrift: maxClockDrift,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  /// Syncs through [server] acting as the authoritative peer. With [wire], the
  /// server stream maps its failures the way the server module facade does.
  /// Every change the device sends is appended to [sent]. With [rewrite], each
  /// change the device sends reaches the server as [rewrite] returns it.
  OfflineSyncClient peerOf(
    OfflineSyncDatabaseSession server, {
    bool wire = false,
    List<CrdtMergeChange>? sent,
    CrdtMergeChange Function(CrdtMergeChange change)? rewrite,
  }) {
    return OfflineSyncClient(({required changes, required once}) {
      final inbound = changes.map((event) {
        if (event is! OfflineSyncMergeChunk) return event;
        sent?.addAll(event.changes);
        if (rewrite == null) return event;
        return OfflineSyncMergeChunk(
          changes: event.changes.map(rewrite).toList(),
        );
      });
      final stream = server.db.sync(
        inbound: inbound,
        once: once,
        mode: OfflineSyncPeerMode.authoritative,
      );
      return wire ? stream.transform(offlineSyncWireErrors()) : stream;
    });
  }

  Future<Object> syncFailure(
    OfflineSyncClient peer,
    OfflineSyncDatabaseSession device,
  ) async {
    try {
      await peer.syncOnce(device);
    } on Object catch (error) {
      return error;
    }
    fail('syncOnce completed, but a clock drift failure was expected.');
  }

  Future<Hlc?> nodeClockOf(OfflineSyncDatabaseSession session) async {
    final nodeId = await session.db.currentNodeId();
    final node = await CrdtNode.db.findFirstRow(
      session,
      where: (t) => t.uuidNodeId.equals(nodeId),
    );
    return node?.lastHlc;
  }

  group('K1 — given a server row stamped past the device limit,', () {
    test(
      'should_reject_on_the_device_keep_the_row_out_and_merge_it_once_within_the_limit',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final peer = peerOf(server);
        await at(t0.add(oneHour + oneMillisecond), () {
          return Note.db.insertRow(server, Note(title: 'from the future'));
        });

        final error = await at(t0, () => syncFailure(peer, device));

        expect(
          error,
          isA<ClockDriftException>()
              .having((e) => e.kind, 'kind', ClockDriftKind.remoteAhead)
              .having(
                (e) => e.remoteNodeId,
                'remoteNodeId',
                await server.db.currentNodeId(),
              )
              .having((e) => e.maxDrift, 'maxDrift', oneHour),
        );
        expect(
          OfflineSyncFailure.from(error).code,
          OfflineSyncFailureReason.clockDriftBehind,
        );
        expect(await Note.db.count(device), 0);

        // One millisecond later the drift is exactly the limit. The row arrives,
        // so the rejected round did not advance the device checkpoint past it.
        await at(t0.add(oneMillisecond), () => peer.syncOnce(device));
        expect(await Note.db.count(device), 1);
      },
    );

    // The fork has no ACK: whether the device re-sends a row is decided by the
    // checkpoint the server persisted when it merged it. So a row the server
    // kept must not be sent again, and a row it never merged must be. co_sync
    // needed a fix for this (unibook#14051); this pins it for the fork.
    //
    // In this in-process harness the server never reads the device batch of
    // the failed round: its generator is paused at `yield` by the device's
    // iterator until the device fails and cancels it. Over a WebSocket the
    // server is not paused by the device and may merge that batch. The
    // assertions hold either way.
    test(
      'should_resend_the_device_push_of_the_failed_round_only_if_the_server_missed_it',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final sent = <CrdtMergeChange>[];
        final peer = peerOf(server, sent: sent);
        final deviceNodeId = await device.db.currentNodeId();
        // Only the device's own rows count. The device also echoes the server's
        // row back while that row is stamped ahead of the server wall clock:
        // the server excludes its own changes with a wall-clock checkpoint
        // (`Hlc.now`), not its last HLC. Upstream behavior, harmless.
        Iterable<CrdtMergeChange> sentByDevice() =>
            sent.where((change) => change.uuidNodeId == deviceNodeId);
        await at(t0, () => Note.db.insertRow(device, Note(title: 'device')));
        await at(t0.add(oneHour + oneMillisecond), () {
          return Note.db.insertRow(server, Note(title: 'from the future'));
        });

        expect(
          await at(t0, () => syncFailure(peer, device)),
          isA<ClockDriftException>(),
        );
        if (sentByDevice().isNotEmpty) {
          await _eventually(() async => await Note.db.count(server) == 2);
        }
        final serverKeptIt = await Note.db.count(server) == 2;

        sent.clear();
        await at(t0.add(oneMillisecond), () => peer.syncOnce(device));
        expect(sentByDevice(), hasLength(serverKeptIt ? 0 : 1));
        expect(await Note.db.count(server), 2);
        expect(await Note.db.count(device), 2);

        sent.clear();
        await at(t0.add(oneMillisecond * 2), () => peer.syncOnce(device));
        expect(
          sentByDevice(),
          isEmpty,
          reason: 'the server checkpoint covers the row',
        );
      },
    );
  });

  group('K2 — given a device row stamped past the server limit,', () {
    test(
      'should_reject_on_the_server_as_a_typed_clockDrift_without_pulling_its_clock',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final peer = peerOf(server, wire: true);
        final serverClock = await nodeClockOf(server);
        await at(t0.add(oneHour + oneMillisecond), () {
          return Note.db.insertRow(device, Note(title: 'from the future'));
        });

        final error = await at(t0, () => syncFailure(peer, device));

        expect(
          error,
          isA<OfflineSyncRemoteException>()
              .having((e) => e.code, 'code', OfflineSyncFailureCode.clockDrift)
              .having((e) => e.driftMs, 'driftMs', 3600001)
              .having((e) => e.maxDriftMs, 'maxDriftMs', 3600000),
        );
        expect(
          OfflineSyncFailure.from(error).code,
          OfflineSyncFailureReason.clockDrift,
        );
        expect(await Note.db.count(server), 0);
        // The rejected merge rolled back, so the device did not pull the shared
        // server node ahead.
        expect(await nodeClockOf(server), serverClock);

        await at(t0.add(oneMillisecond), () => peer.syncOnce(device));
        expect(await Note.db.count(server), 1);
      },
    );
  });

  // A peer can send a change under any node id. Upstream checked only the
  // batch maximum and adopted it unchecked when it carried the receiver's own
  // id, so one change sent under the server's node id moved the clock every
  // space shares and let the rest of the batch skip the drift check.
  group('K2 — given a device batch that claims the server node id,', () {
    test(
      'should_reject_a_change_stamped_past_the_server_limit_without_moving_its_clock',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final serverNodeId = await server.db.currentNodeId();
        final serverClock = await nodeClockOf(server);
        final peer = peerOf(
          server,
          wire: true,
          rewrite: (change) => _underNode(change, serverNodeId),
        );
        await at(t0.add(const Duration(hours: 3)), () {
          return Note.db.insertRow(device, Note(title: 'forged'));
        });

        final error = await at(t0, () => syncFailure(peer, device));

        expect(
          error,
          isA<OfflineSyncRemoteException>()
              .having((e) => e.code, 'code', OfflineSyncFailureCode.clockDrift)
              .having((e) => e.driftMs, 'driftMs', 3 * 3600000)
              .having((e) => e.maxDriftMs, 'maxDriftMs', 3600000),
        );
        expect(await Note.db.count(server), 0);
        expect(await nodeClockOf(server), serverClock);
        // The shared server clock was not pulled ahead, so the server can still
        // write at the correct time.
        await at(t0, () => Note.db.insertRow(server, Note(title: 'server')));
        expect(await Note.db.count(server), 1);
      },
    );

    test(
      'should_still_check_the_other_changes_in_the_batch_against_the_server_limit',
      () async {
        final userId = const Uuid().v7obj();
        final server = await openReplica(userId);
        final device = await openReplica(userId);
        final serverNodeId = await server.db.currentNodeId();
        final serverClock = await nodeClockOf(server);
        final forgedAt = t0.add(const Duration(hours: 3));
        // Only the newest change is sent under the server node id, so it is the
        // batch maximum; the other change stays the device's own.
        final peer = peerOf(
          server,
          wire: true,
          rewrite: (change) => change.hlcDatetime == forgedAt
              ? _underNode(change, serverNodeId)
              : change,
        );
        await at(t0.add(const Duration(hours: 2)), () {
          return Note.db.insertRow(device, Note(title: 'ahead'));
        });
        await at(
          forgedAt,
          () => Note.db.insertRow(device, Note(title: 'forged')),
        );

        final error = await at(t0, () => syncFailure(peer, device));

        expect(
          error,
          isA<OfflineSyncRemoteException>()
              .having((e) => e.code, 'code', OfflineSyncFailureCode.clockDrift)
              .having((e) => e.driftMs, 'driftMs', 2 * 3600000),
        );
        expect(await Note.db.count(server), 0);
        expect(await nodeClockOf(server), serverClock);
      },
    );
  });

  group('K3 — given a device whose clock moved back after a write,', () {
    // The five-minute case writes only ten minutes ahead: over its own limit
    // but within the one-hour default, so a device that fell back to the
    // default would accept the write.
    for (final (limit, ahead, rejects) in [
      (oneHour, const Duration(hours: 2), true),
      (const Duration(hours: 3), const Duration(hours: 2), false),
      (const Duration(minutes: 5), const Duration(minutes: 10), true),
    ]) {
      test(
        'should_${rejects ? 'reject' : 'accept'}_a_write_after_the_clock_moved_back_'
        '${ahead.inMinutes}_minutes_with_a_limit_of_${limit.inMinutes}_minutes',
        () async {
          final device = await openReplica(
            const Uuid().v7obj(),
            maxClockDrift: limit == oneHour ? null : limit,
          );
          await at(
            t0.add(ahead),
            () => Note.db.insertRow(device, Note(title: 'a')),
          );

          final error = await _errorOf(
            at(t0, () => Note.db.insertRow(device, Note(title: 'b'))),
          );

          if (rejects) {
            expect(
              error,
              isA<ClockDriftException>()
                  .having((e) => e.kind, 'kind', ClockDriftKind.localAhead)
                  .having((e) => e.maxDrift, 'maxDrift', limit),
            );
            expect(
              OfflineSyncFailure.from(error!).code,
              OfflineSyncFailureReason.clockRollback,
            );
            expect(await Note.db.count(device), 1);
          } else {
            expect(error, isNull);
            expect(await Note.db.count(device), 2);
          }
        },
      );
    }
  });

  group('Given a device limit below the server limit (S = 1h),', () {
    for (final (deviceLimit, rejects) in [
      (const Duration(minutes: 10), true),
      (oneHour, false),
    ]) {
      test(
        'should_${rejects ? 'reject' : 'accept'}_server_stamps_another_device_pulled_'
        '50_minutes_ahead_on_a_correct_device_with_C_$deviceLimit',
        () async {
          final userId = const Uuid().v7obj();
          final server = await openReplica(userId);
          final fastDevice = await openReplica(userId);
          final correctDevice = await openReplica(
            userId,
            maxClockDrift: deviceLimit == oneHour ? null : deviceLimit,
          );
          final peer = peerOf(server);

          // A device 50 minutes ahead is within S, so the server accepts its
          // row and the shared server node moves 50 minutes ahead.
          await at(t0.add(const Duration(minutes: 50)), () {
            return Note.db.insertRow(fastDevice, Note(title: 'fast'));
          });
          await at(t0, () => peer.syncOnce(fastDevice));
          // A server write at the correct time is stamped at the pulled clock.
          await at(t0, () => Note.db.insertRow(server, Note(title: 'server')));

          final error = await _errorOf(
            at(t0, () => peer.syncOnce(correctDevice)),
          );

          if (rejects) {
            expect(
              error,
              isA<ClockDriftException>()
                  .having((e) => e.kind, 'kind', ClockDriftKind.remoteAhead)
                  .having((e) => e.maxDrift, 'maxDrift', deviceLimit),
            );
            expect(await Note.db.count(correctDevice), 0);
          } else {
            expect(error, isNull);
            expect(await Note.db.count(correctDevice), 2);
          }
        },
      );
    }
  });

  group('Given a session wrapper,', () {
    test(
      'should_reject_a_maxClockDrift_that_conflicts_with_the_wrapped_database',
      () async {
        final session = await openReplica(
          const Uuid().v7obj(),
          maxClockDrift: const Duration(minutes: 5),
        );

        expect(session.db.maxClockDrift, const Duration(minutes: 5));
        expect(
          () => OfflineSyncDatabaseSession.wraps(
            session,
            syncTables: syncTables,
            maxClockDrift: oneHour,
          ),
          throwsArgumentError,
        );
      },
    );
  });
}

/// [change] as if [nodeId] had authored it.
CrdtMergeChange _underNode(CrdtMergeChange change, UuidValue nodeId) {
  return switch (change) {
    CrdtMergeInsert() => change.copyWith(uuidNodeId: nodeId),
    CrdtMergeUpdate() => change.copyWith(uuidNodeId: nodeId),
    CrdtMergeDelete() => change.copyWith(uuidNodeId: nodeId),
  };
}

/// The error [future] completes with, or null when it succeeds.
Future<Object?> _errorOf(Future<Object?> future) async {
  try {
    await future;
    return null;
  } on Object catch (error) {
    return error;
  }
}

/// Polls [condition] until it holds, failing after [timeout].
Future<void> _eventually(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition not met within $timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
