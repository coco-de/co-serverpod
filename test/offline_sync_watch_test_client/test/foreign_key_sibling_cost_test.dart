import 'dart:io';
import 'dart:typed_data';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

import 'support/sync_harness.dart';

/// Merging one child under a parent that already has many children costs
/// about what it costs under a parent with one (co-serverpod#41,
/// unibook#14371).
///
/// The pass loads the parent's children, because hiding or restoring a parent
/// decides their fate. It used to read, for each of them, the columns the
/// merged child names, and compare them byte by byte through a UUID probe
/// that threw once per byte. With 2 KB payloads that was 5.5 s for 100
/// siblings and 56 s for 1,000, on the server's push and on a device's pull
/// alike, all of it synchronous.
///
/// | Case | Pinned |
/// |---|---|
/// | Server merges one pushed child next to 500 stored siblings | within [_maxRatio] of one sibling |
/// | A device pulls that child next to its 500 stored siblings | same |
///
/// The bound compares against the same run with one sibling, so a slow
/// machine slows both sides. Each side takes the fastest of [_attempts] runs,
/// which drops a pause that is not the merge's.
void main() {
  const siblingsMany = 500;
  late Directory tempDir;
  final client = Client('http://localhost:1/');
  var databaseCount = 0;
  const sessionTimeout = Duration(seconds: 60);

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_sync_fk41_cost_');
  });
  tearDownAll(() => tempDir.delete(recursive: true));

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

  /// The push and pull time of one child merged next to [siblings] stored
  /// ones, the fastest of [_attempts] runs each.
  Future<({Duration push, Duration pull})> mergeOneChild(int siblings) async {
    final userId = const Uuid().v7obj();
    final server = await openReplica(userId);
    final phone = await openReplica(userId);
    final tablet = await openReplica(userId);
    Future<void> sync(OfflineSyncDatabaseSession device) =>
        peerOf(server).syncOnce(device).timeout(sessionTimeout);

    final note = await Note.db.insertRow(phone, Note(title: 'page'));
    await Stroke.db.insert(phone, [
      for (var i = 0; i < siblings; i++)
        Stroke(seq: 's$i', payload: payload(i), noteId: note.id!),
    ]);
    await sync(phone);
    await sync(tablet);

    Duration? push;
    Duration? pull;
    for (var attempt = 0; attempt < _attempts; attempt++) {
      await Stroke.db.insertRow(
        phone,
        Stroke(
          seq: 'new$attempt',
          payload: payload(-attempt),
          noteId: note.id!,
        ),
      );
      final pushWatch = Stopwatch()..start();
      await sync(phone);
      pushWatch.stop();
      final pullWatch = Stopwatch()..start();
      await sync(tablet);
      pullWatch.stop();
      if (push == null || pushWatch.elapsed < push) push = pushWatch.elapsed;
      if (pull == null || pullWatch.elapsed < pull) pull = pullWatch.elapsed;
    }

    final expected = siblings + _attempts;
    for (final replica in [server, phone, tablet]) {
      expect(await Stroke.db.count(replica), expected);
    }
    return (push: push!, pull: pull!);
  }

  group('Given a note with $siblingsMany stored strokes,', () {
    test(
      'should_merge_one_new_stroke_about_as_fast_as_next_to_one_when_pushed_and_pulled',
      () async {
        // Warm up the code paths so the first measurement is not the compile.
        await mergeOneChild(1);
        final one = await mergeOneChild(1);
        final many = await mergeOneChild(siblingsMany);

        printOnFailure(
          'push ${one.push.inMilliseconds} ms → ${many.push.inMilliseconds} ms, '
          'pull ${one.pull.inMilliseconds} ms → ${many.pull.inMilliseconds} ms',
        );
        expect(
          many.push,
          lessThanOrEqualTo(_bound(one.push)),
          reason:
              'server merge of a pushed child next to $siblingsMany siblings',
        );
        expect(
          many.pull,
          lessThanOrEqualTo(_bound(one.pull)),
          reason:
              'device merge of a pulled child next to $siblingsMany siblings',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}

const _attempts = 3;

/// How many times the one-sibling time the merge next to many may take.
///
/// Measured after the fix: about 1.3x (SQLite, M-series). Before it: about
/// 190x.
const _maxRatio = 6;

/// A floor under the bound, so a one-sibling run too fast to measure does not
/// make the bound meaningless.
const _minBound = Duration(milliseconds: 400);

Duration _bound(Duration one) {
  final scaled = one * _maxRatio;
  return scaled > _minBound ? scaled : _minBound;
}
