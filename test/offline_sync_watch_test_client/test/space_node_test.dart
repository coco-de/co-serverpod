import 'dart:io';

import 'package:clock/clock.dart';
import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

import 'support/sync_harness.dart';

/// A server CRDT node per space (unibook#14218) between real SQLite replicas.
///
/// The server is a replica opened without a persistent user, which holds many
/// users the way the Serverpod server does. Upstream shared one node across
/// every space of a database, so one device clock pulling that node ahead moved
/// the server's timestamps for every other user. A device still shares one
/// node across its spaces.
///
/// Every step runs with the wall clock pinned by [at], for both peers of a
/// round. A device "five minutes behind" is a round run five minutes before the
/// wall clock at which the server issued the timestamps it receives.
///
/// | Case | Expected |
/// |---|---|
/// | Server and device | A node per server space · one node on the device |
/// | A follower sync without a persistent user | `StateError` |
/// | A space A device pushes a stamp 59 minutes ahead | A server write for space B stays within a minute of the wall clock |
/// | A space B device five minutes behind | Syncs without `clockDriftBehind` |
/// | A sibling device of space A five minutes behind | `clockDriftBehind` (the residual, C = S) |
/// | Space A exhausts its counter | Server writes for space B still succeed |
/// | A space leaves a shared node | Its clock starts at max(shared clock, stored stamps) |
/// | One session over two spaces | Two server nodes, no echo, no resend |
void main() {
  late Directory tempDir;
  final client = Client('http://localhost:1/');
  var databaseCount = 0;
  final t0 = DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch,
    isUtc: true,
  );
  const oneMinute = Duration(minutes: 1);
  const fiveMinutes = Duration(minutes: 5);
  const thirtyMinutes = Duration(minutes: 30);
  const fiftyNineMinutes = Duration(minutes: 59);

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_space_node_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

  Future<T> at<T>(DateTime wallTime, Future<T> Function() body) =>
      withClock(Clock.fixed(wallTime), body);

  String newPath() => p.join(tempDir.path, 'replica-${++databaseCount}.db');

  /// A server: no persistent user, so every space gets its own node.
  Future<OfflineSyncDatabaseSession> openServer() async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(newPath()),
      syncTables: syncTables,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  /// A device of [userId]: one node for the install.
  Future<OfflineSyncDatabaseSession> openDevice(UuidValue userId) async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(newPath()),
      syncTables: syncTables,
      persistentUserId: userId,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  /// A server write of a note in the personal space of [userId].
  Future<Note> serverWrite(
    OfflineSyncDatabaseSession server,
    UuidValue userId,
    String title,
  ) => server.db.transactionForUser(
    userId,
    (transaction) =>
        Note.db.insertRow(server, Note(title: title), transaction: transaction),
  );

  /// The timestamp [session] stamped the insert of [note] with.
  Future<Hlc> insertStampOf(
    OfflineSyncDatabaseSession session,
    Note note,
  ) async {
    final row = await CrdtDataRow.db.findFirstRow(
      session,
      where: (t) => t.uuidRowId.equals(note.id!),
      include: CrdtDataRow.include(node: CrdtNode.include()),
    );
    return row!.hlc;
  }

  Future<OfflineSyncSpace> spaceOf(
    OfflineSyncDatabaseSession session,
    UuidValue spaceId,
  ) async {
    final space = await OfflineSyncSpace.db.findFirstRow(
      session,
      where: (t) => t.uuidSpaceId.equals(spaceId),
      include: OfflineSyncSpace.include(currentNode: CrdtNode.include()),
    );
    return space!;
  }

  group('Given a server and a device,', () {
    test(
      'should_give_each_server_space_its_own_node_and_keep_one_node_on_the_device',
      () async {
        final userA = const Uuid().v7obj();
        final userB = const Uuid().v7obj();
        final server = await openServer();
        final device = await openDevice(userA);

        await serverWrite(server, userA, 'a');
        await serverWrite(server, userB, 'b');
        final sharedOnDevice = const Uuid().v7obj();
        final personalNode = await device.db.currentNodeId();
        final sharedNode = await device.db.currentNodeId(
          userId: sharedOnDevice,
        );

        final serverNodes = {
          (await spaceOf(server, userA)).currentNodeId,
          (await spaceOf(server, userB)).currentNodeId,
        };
        expect(serverNodes, hasLength(2));
        expect(await CrdtNode.db.count(server), 2);
        expect(sharedNode, personalNode);
      },
    );

    // A follower's own checkpoints and unsent row count follow the one node
    // its connect frame names, so a follower needs the device's shared node.
    test(
      'should_refuse_a_follower_sync_on_a_database_without_a_persistent_user',
      () async {
        final notADevice = await openServer();

        final error = await errorOf(
          notADevice.db
              .sync(
                userId: const Uuid().v7obj(),
                inbound: const Stream.empty(),
                mode: OfflineSyncPeerMode.follower,
                once: true,
              )
              .drain<void>(),
        );

        expect(error, isA<StateError>());
        expect(await CrdtNode.db.count(notADevice), 0);
      },
    );
  });

  group('Given a server whose space A a device pulled 59 minutes ahead,', () {
    late UuidValue userA;
    late UuidValue userB;
    late OfflineSyncDatabaseSession server;

    setUp(() async {
      userA = const Uuid().v7obj();
      userB = const Uuid().v7obj();
      server = await openServer();
      final deviceA = await openDevice(userA);
      await at(t0.add(fiftyNineMinutes), () {
        return Note.db.insertRow(deviceA, Note(title: 'ahead'));
      });
      await at(t0, () => peerOf(server, userId: userA).syncOnce(deviceA));
      expect(
        (await spaceOf(server, userA)).currentNode!.lastHlc!.datetime,
        t0.add(fiftyNineMinutes),
        reason: 'the server accepted the stamp within S and its clock took it',
      );
    });

    test(
      'should_stamp_a_server_write_for_space_B_within_a_minute_of_the_wall_clock',
      () async {
        final forB = await at(t0, () => serverWrite(server, userB, 'for B'));
        final forA = await at(t0, () => serverWrite(server, userA, 'for A'));

        final stampB = await insertStampOf(server, forB);
        expect(stampB.datetime.isBefore(t0), isFalse);
        expect(stampB.datetime.difference(t0), lessThanOrEqualTo(oneMinute));
        // The pull stays in its own space, where the next server write takes
        // the pulled clock.
        expect(
          (await insertStampOf(server, forA)).datetime,
          t0.add(fiftyNineMinutes),
        );
      },
    );

    test(
      'should_let_a_space_B_device_five_minutes_behind_sync_without_clockDriftBehind',
      () async {
        await at(t0, () => serverWrite(server, userB, 'for B'));
        final deviceB = await openDevice(userB);

        final error = await errorOf(
          at(
            t0.subtract(fiveMinutes),
            () => peerOf(server, userId: userB).syncOnce(deviceB),
          ),
        );

        expect(error, isNull);
        expect(await Note.db.count(deviceB), 1);
      },
    );

    // The residual the node per space leaves (C = S = 1 hour): a device of
    // the same space still receives timestamps its sibling pulled a full S
    // ahead, so a sibling behind the server by any lag stops. Devices of the
    // same account need C ≥ S + lag between them.
    test(
      'should_still_stop_a_sibling_device_of_space_A_five_minutes_behind_with_clockDriftBehind',
      () async {
        await at(t0, () => serverWrite(server, userA, 'for A'));
        final siblingA = await openDevice(userA);

        final error = await errorOf(
          at(
            t0.subtract(fiveMinutes),
            () => peerOf(server, userId: userA).syncOnce(siblingA),
          ),
        );

        expect(
          error,
          isA<ClockDriftException>().having(
            (e) => e.kind,
            'kind',
            ClockDriftKind.remoteAhead,
          ),
        );
        expect(
          OfflineSyncFailure.from(error!).code,
          OfflineSyncFailureReason.clockDriftBehind,
        );
        expect(await Note.db.count(siblingA), 0);
      },
    );
  });

  group('Given a device that exhausts the counter of space A,', () {
    test('should_keep_server_writes_for_space_B_succeeding', () async {
      final userA = const Uuid().v7obj();
      final userB = const Uuid().v7obj();
      final server = await openServer();
      final deviceA = await openDevice(userA);
      final deviceNodeId = await deviceA.db.currentNodeId();
      // The last counter value at 59 minutes ahead: the next timestamp the
      // clock of space A issues before the wall clock gets there overflows.
      final exhausting = peerOf(
        server,
        userId: userA,
        rewrite: (change) => change.uuidNodeId == deviceNodeId
            ? _withCounter(change, 0xFFFF)
            : change,
      );
      await at(t0.add(fiftyNineMinutes), () {
        return Note.db.insertRow(deviceA, Note(title: 'ahead'));
      });
      await at(t0, () => exhausting.syncOnce(deviceA));

      final errorA = await errorOf(
        at(t0, () => serverWrite(server, userA, 'for A')),
      );
      final forB = await at(t0, () => serverWrite(server, userB, 'for B'));

      expect(errorA, isA<OverflowException>());
      expect(
        OfflineSyncFailure.from(errorA!).code,
        OfflineSyncFailureReason.hlcOverflow,
      );
      expect(
        (await insertStampOf(server, forB)).datetime.difference(t0),
        lessThanOrEqualTo(oneMinute),
      );
    });
  });

  // A server database written before unibook#14218 has every space on one
  // node. Each space that still shares it leaves on its next use, and the new
  // clock must not start below a timestamp the space holds or below what the
  // shared clock issued, or the server's next write in the space loses LWW to
  // an older edit. This is the reverse of the device move onto a shared node.
  group('Given a server whose spaces share one node,', () {
    test(
      'should_start_each_leaving_space_at_the_later_of_the_shared_clock_and_its_stored_stamps',
      () async {
        final userA = const Uuid().v7obj();
        final userB = const Uuid().v7obj();
        final userC = const Uuid().v7obj();
        final server = await openServer();
        final deviceA = await openDevice(userA);
        // Space A holds a stamp 59 minutes ahead; B and C hold wall-clock ones.
        final deviceNote = await at(t0.add(fiftyNineMinutes), () {
          return Note.db.insertRow(deviceA, Note(title: 'device'));
        });
        await at(t0, () => peerOf(server, userId: userA).syncOnce(deviceA));
        await at(t0, () => serverWrite(server, userB, 'b'));
        await at(t0, () => serverWrite(server, userC, 'c'));

        final sharedUuid = const Uuid().v7obj();
        final shared = await CrdtNode.db.insertRow(
          server,
          CrdtNode(
            uuidNodeId: sharedUuid,
            lastHlc: Hlc(t0.add(thirtyMinutes), 0, sharedUuid),
          ),
        );
        for (final userId in [userA, userB, userC]) {
          final space = await spaceOf(server, userId);
          await OfflineSyncSpace.db.updateRow(
            server,
            space.copyWith(currentNodeId: shared.id),
            columns: (t) => [t.currentNodeId],
          );
        }
        // Drop the cached spaces, as a restart onto this database would.
        await server.db.initialize();

        // Space A: its stored stamp (59 minutes) is later than the shared
        // clock (30 minutes).
        await at(t0, () {
          return server.db.transactionForUser(
            userA,
            (transaction) => Note.db.updateById(
              server,
              deviceNote.id!,
              columnValues: (t) => [t.title('server')],
              transaction: transaction,
            ),
          );
        });
        final spaceA = await spaceOf(server, userA);
        expect(spaceA.currentNodeId, isNot(shared.id));
        expect(spaceA.currentNode!.lastHlc!.datetime, t0.add(fiftyNineMinutes));
        await at(t0, () => peerOf(server, userId: userA).syncOnce(deviceA));
        expect(
          (await Note.db.findById(deviceA, deviceNote.id!))!.title,
          'server',
          reason: 'the later server edit wins LWW on the device',
        );

        // Space C: the shared clock (30 minutes) is later than its stored
        // stamps (the wall clock).
        final inC = await at(t0, () => serverWrite(server, userC, 'c2'));
        expect((await spaceOf(server, userC)).currentNodeId, isNot(shared.id));
        expect(
          (await insertStampOf(server, inC)).datetime,
          t0.add(thirtyMinutes),
        );

        // Space B is the last one on the shared node and keeps it.
        await at(t0, () => serverWrite(server, userB, 'b2'));
        expect((await spaceOf(server, userB)).currentNodeId, shared.id);

        // The server wrote the shared node's changes itself, so each space
        // that left it records them as held and no device sends them back.
        for (final space in [spaceA, await spaceOf(server, userC)]) {
          final retired = await OfflineSyncSpaceNode.db.findFirstRow(
            server,
            where: (t) =>
                t.spaceId.equals(space.id) & t.nodeId.equals(shared.id),
          );
          expect(
            retired?.lastReceivedHlc,
            Hlc(t0.add(thirtyMinutes), 0, sharedUuid),
          );
        }
      },
    );
  });

  // One sync session over several spaces has one server node per space, but
  // the connect frame names one node. The fork keeps such sessions instead of
  // rejecting them (unibook runs one personal space per user, #14187): every
  // checkpoint is kept per space and node, so the session stays consistent.
  group(
    'Given a user who syncs a personal and a shared space in one session,',
    () {
      test(
        'should_deliver_both_server_nodes_then_send_only_new_changes_without_echo',
        () async {
          final userId = const Uuid().v7obj();
          final sharedSpaceId = const Uuid().v7obj();
          final server = await openServer();
          final device = await openDevice(userId);
          final deviceNodeId = await device.db.currentNodeId();
          final sharedSpace = await OfflineSyncSpace.db.insertRow(
            server,
            OfflineSyncSpace(uuidSpaceId: sharedSpaceId),
          );
          await OfflineSyncSpaceMember.db.insertRow(
            server,
            OfflineSyncSpaceMember(
              spaceId: sharedSpace.id!,
              userUuid: userId,
              role: OfflineSyncSpaceRole.readWrite,
            ),
          );
          final sent = <CrdtMergeChange>[];
          final received = <CrdtMergeChange>[];
          final peer = peerOf(
            server,
            userId: userId,
            sent: sent,
            mapServerStream: (stream) => stream.map((event) {
              if (event is OfflineSyncMergeChunk) {
                received.addAll(event.changes);
              }
              return event;
            }),
          );
          await serverWrite(server, userId, 'personal from the server');
          await server.db.transactionForUser(
            userId,
            (transaction) => Note.db.insertRow(
              server,
              Note(title: 'shared from the server'),
              transaction: transaction,
            ),
            spaceId: sharedSpaceId,
          );
          final personalNodeId = (await spaceOf(
            server,
            userId,
          )).currentNode!.uuidNodeId;
          final sharedNodeId = (await spaceOf(
            server,
            sharedSpaceId,
          )).currentNode!.uuidNodeId;
          expect(sharedNodeId, isNot(personalNodeId));

          await peer.syncOnce(device);

          expect(await Note.db.count(device), 2);
          expect(received.map((change) => change.uuidNodeId).toSet(), {
            personalNodeId,
            sharedNodeId,
          });
          expect(sent, isEmpty);

          await Note.db.insertRow(
            device,
            Note(title: 'personal from the device'),
          );
          await device.db.transactionForUser(
            userId,
            (transaction) => Note.db.insertRow(
              device,
              Note(title: 'shared from the device'),
              transaction: transaction,
            ),
            spaceId: sharedSpaceId,
          );
          sent.clear();
          received.clear();
          await peer.syncOnce(device);

          expect(sent, hasLength(2));
          expect(sent.map((change) => change.uuidNodeId).toSet(), {
            deviceNodeId,
          }, reason: 'the device sends no server change back');
          expect(received, isEmpty, reason: 'the server resends nothing');
          expect(await Note.db.count(server), 4);

          sent.clear();
          received.clear();
          await peer.syncOnce(device);

          expect(sent, isEmpty);
          expect(received, isEmpty);
          final deviceCheckpoints = await OfflineSyncSpaceNode.db.find(
            server,
            where: (t) => t.node.uuidNodeId.equals(deviceNodeId),
          );
          expect(
            deviceCheckpoints.map((spaceNode) => spaceNode.spaceId).toSet(),
            {(await spaceOf(server, userId)).id, sharedSpace.id},
          );
          expect(
            deviceCheckpoints.every(
              (spaceNode) => spaceNode.lastReceivedHlc != null,
            ),
            isTrue,
          );
        },
      );
    },
  );
}

/// [change] with its counter set to [counter].
CrdtMergeChange _withCounter(CrdtMergeChange change, int counter) {
  return switch (change) {
    CrdtMergeInsert() => change.copyWith(hlcCounter: counter),
    CrdtMergeUpdate() => change.copyWith(hlcCounter: counter),
    CrdtMergeDelete() => change.copyWith(hlcCounter: counter),
  };
}
