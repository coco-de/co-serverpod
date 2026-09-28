import 'dart:io';
import 'dart:typed_data';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

import 'support/sync_harness.dart';

/// Merging one child under a parent that already has many children does not
/// read those children's payloads, and costs little per row it reaches
/// (co-serverpod#41, unibook#14371).
///
/// The pass loads the rows the merged child's foreign key component reaches:
/// its parent, the parent's other children (hiding or restoring a parent
/// decides their fate), and up and down from there, such as the other notes
/// of the note's folder and their strokes. It used to read, for each of them,
/// every column the merged child names and compare them byte by byte through
/// a UUID probe that threw once per byte. With 2 KB payloads that was 5.5 s
/// for 100 siblings and 56 s for 1,000, on the server's push and on a
/// device's pull alike, all of it synchronous.
///
/// Now a reached row reads its foreign key and unique columns only. What is
/// left is linear in the component: loading each reached row's metadata and
/// those few columns, twice per merge (the batch plan and the end pass).
///
/// | Case | Pinned |
/// |---|---|
/// | Server merges a pushed child; a device merges it on pull | reached rows read no payload or plain column, but do read the unique columns |
/// | Same, next to 500 siblings and 4 more notes of 50 strokes in the folder | merge passes cost at most [_perRowBudget] per added component row |
///
/// The timing counts the merge passes only ([OfflineSyncProjectionDebug]),
/// not the rest of a sync or the projection rebuild a fresh replica runs on
/// its first operations, and takes the fastest of [_attempts] runs.
void main() {
  late Directory tempDir;
  final client = Client('http://localhost:1/');
  var databaseCount = 0;
  const sessionTimeout = Duration(seconds: 60);

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_fk41_cost_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));
  tearDown(() {
    OfflineSyncProjectionDebug.onClosureColumnsRead = null;
    OfflineSyncProjectionDebug.onPass = null;
  });

  Future<OfflineSyncDatabaseSession> openReplica(UuidValue userId) async {
    final session = OfflineSyncDatabaseSession.wraps(
      await client.createSession(
        p.join(tempDir.path, 'replica-${++databaseCount}.db'),
      ),
      syncTables: syncTables,
      persistentUserId: userId,
    );
    addTearDown(session.close);
    await session.db.initialize();
    return session;
  }

  ByteData payload(int seed) {
    final bytes = Uint8List(2048);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (seed * 131 + i * 7) & 0xff;
    }
    return ByteData.sublistView(bytes);
  }

  /// A server, a phone and a tablet holding one note of [siblings] strokes,
  /// in a folder with [otherNotes] more notes of [strokesPerOtherNote] each.
  Future<_Fixture> seed({
    required int siblings,
    int otherNotes = 0,
    int strokesPerOtherNote = 0,
  }) async {
    final userId = const Uuid().v7obj();
    final fixture = _Fixture(
      server: await openReplica(userId),
      phone: await openReplica(userId),
      tablet: await openReplica(userId),
      sessionTimeout: sessionTimeout,
    );
    final phone = fixture.phone;
    final folder = await Folder.db.insertRow(phone, Folder(name: 'f'));
    final note = await Note.db.insertRow(
      phone,
      Note(title: 'page', folderId: folder.id),
    );
    fixture.noteId = note.id!;
    final stored = await Stroke.db.insert(phone, [
      for (var i = 0; i < siblings; i++)
        Stroke(
          seq: 's$i',
          legacyId: 'l$i',
          payload: payload(i),
          noteId: note.id!,
        ),
    ]);
    fixture.siblingIds.addAll([for (final stroke in stored) stroke.id!]);
    for (var n = 0; n < otherNotes; n++) {
      final other = await Note.db.insertRow(
        phone,
        Note(title: 'other$n', folderId: folder.id),
      );
      await Stroke.db.insert(phone, [
        for (var i = 0; i < strokesPerOtherNote; i++)
          Stroke(seq: 's$i', payload: payload(n * 1000 + i), noteId: other.id!),
      ]);
    }
    await fixture.sync(phone);
    await fixture.sync(fixture.tablet);
    return fixture;
  }

  group('Given a note with stored strokes,', () {
    test(
      'should_not_read_the_siblings_payload_or_plain_columns_when_a_new_stroke_is_pushed_and_pulled',
      () async {
        final fixture = await seed(siblings: 20);
        final reads = <(String, Set<UuidValue>, List<String>)>[];
        OfflineSyncProjectionDebug.onClosureColumnsRead =
            (tableName, rowIds, columnNames) =>
                reads.add((tableName, {...rowIds}, [...columnNames]));

        await Stroke.db.insertRow(
          fixture.phone,
          Stroke(
            seq: 'new',
            legacyId: 'mine',
            payload: payload(-1),
            noteId: fixture.noteId,
          ),
        );
        for (final (label, device) in [
          ('push', fixture.phone),
          ('pull', fixture.tablet),
        ]) {
          reads.clear();
          await fixture.sync(device);

          final siblingReads = [
            for (final (table, rowIds, columns) in reads)
              if (table == 'stroke' &&
                  rowIds.intersection(fixture.siblingIds).isNotEmpty)
                (rowIds, columns),
          ];
          expect(
            siblingReads,
            isNotEmpty,
            reason: '$label: the merge must reach the siblings, else vacuous',
          );
          for (final (rowIds, columns) in siblingReads) {
            expect(
              columns,
              isNot(anyOf(contains('payload'), contains('legacyId'))),
              reason:
                  '$label: siblings ${rowIds.length} read with the merged '
                  "child's columns",
            );
            expect(
              columns,
              containsAll(<String>['noteId', 'seq']),
              reason:
                  '$label: a reached sibling must read its foreign key and '
                  'unique columns, the ones projection decides',
            );
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'should_cost_little_per_reached_row_when_merging_next_to_500_siblings_and_a_folder_of_notes',
      () async {
        // Warm up the code paths so the first measurement is not the compile.
        await _mergeTime(await seed(siblings: 1), payload);
        final one = await _mergeTime(await seed(siblings: 1), payload);
        const siblingsMany = 500;
        const otherNotes = 4;
        const strokesPerOtherNote = 50;
        final many = await _mergeTime(
          await seed(
            siblings: siblingsMany,
            otherNotes: otherNotes,
            strokesPerOtherNote: strokesPerOtherNote,
          ),
          payload,
        );
        const addedRows =
            siblingsMany - 1 + otherNotes * (1 + strokesPerOtherNote);

        final report =
            'merge passes: push ${one.push.inMicroseconds / 1000} ms → '
            '${many.push.inMicroseconds / 1000} ms, pull '
            '${one.pull.inMicroseconds / 1000} ms → '
            '${many.pull.inMicroseconds / 1000} ms, over $addedRows added rows';
        printOnFailure(report);
        expect(
          many.push - one.push,
          lessThanOrEqualTo(_perRowBudget * addedRows),
          reason: 'server merge of a pushed child: $report',
        );
        expect(
          many.pull - one.pull,
          lessThanOrEqualTo(_perRowBudget * addedRows),
          reason: 'device merge of a pulled child: $report',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}

final class _Fixture {
  _Fixture({
    required this.server,
    required this.phone,
    required this.tablet,
    required this.sessionTimeout,
  });

  final OfflineSyncDatabaseSession server;
  final OfflineSyncDatabaseSession phone;
  final OfflineSyncDatabaseSession tablet;
  final Duration sessionTimeout;
  late final UuidValue noteId;
  final siblingIds = <UuidValue>{};

  Future<void> sync(OfflineSyncDatabaseSession device) =>
      peerOf(server).syncOnce(device).timeout(sessionTimeout);
}

/// The time the merge passes of the round pushing one child from the phone
/// took (the server's merge of it), and of the round pulling it to the tablet
/// (the tablet's), the fastest of [_attempts] runs each.
Future<({Duration push, Duration pull})> _mergeTime(
  _Fixture fixture,
  ByteData Function(int seed) payload,
) async {
  var total = Duration.zero;
  OfflineSyncProjectionDebug.onPass =
      ({required elapsed, required rowCount, required seeded}) {
        // The projection rebuild a fresh replica runs is not the merge's cost.
        if (seeded) total += elapsed;
      };
  Duration? push;
  Duration? pull;
  try {
    for (var attempt = 0; attempt < _attempts; attempt++) {
      await Stroke.db.insertRow(
        fixture.phone,
        Stroke(
          seq: 'new$attempt',
          payload: payload(-attempt),
          noteId: fixture.noteId,
        ),
      );
      total = Duration.zero;
      await fixture.sync(fixture.phone);
      if (push == null || total < push) push = total;
      total = Duration.zero;
      await fixture.sync(fixture.tablet);
      if (pull == null || total < pull) pull = total;
    }
  } finally {
    OfflineSyncProjectionDebug.onPass = null;
  }
  final expected = fixture.siblingIds.length + _attempts;
  for (final replica in [fixture.server, fixture.phone, fixture.tablet]) {
    expect(
      await Stroke.db.count(
        replica,
        where: (t) => t.noteId.equals(fixture.noteId),
      ),
      expected,
    );
  }
  return (push: push!, pull: pull!);
}

const _attempts = 3;

/// How long the merge passes may take per row the component grows by.
///
/// Measured after the fix: about 0.1 ms (SQLite, M-series, both passes).
/// Before it: about 50 ms per 2 KB sibling.
const _perRowBudget = Duration(microseconds: 1000);
