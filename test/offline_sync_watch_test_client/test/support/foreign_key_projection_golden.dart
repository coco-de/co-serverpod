import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:offline_sync_watch_test_client/offline_sync_watch_test_client.dart';
import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:serverpod_database/serverpod_database.dart'
    show DatabaseSession;
import 'package:test/test.dart';

/// Where the scenarios of [defineForeignKeyProjectionGolden] run.
///
/// A replica is any [DatabaseSession] over an offline sync database, so a
/// target can route its calls, see `offline_sync_watch_test_server`.
abstract interface class ForeignKeyProjectionTarget {
  /// A new server replica for [userId], empty of every earlier scenario.
  Future<DatabaseSession> openServer(UuidValue userId);

  /// A new device replica of [userId].
  Future<DatabaseSession> openDevice(UuidValue userId);

  /// One sync round of [device] against [server].
  Future<void> sync(
    DatabaseSession server,
    DatabaseSession device,
    UuidValue userId,
  );

  /// Whether the random writes also write on the server replica.
  bool get serverWrites;
}

/// Foreign key projection writes what it wrote before co-serverpod#41.
///
/// The fix narrowed what a pass loads for the rows it only reaches through a
/// foreign key (a stored sibling of the merged child): the columns that only
/// the merged rows name are not read for them any more, and UUID probing no
/// longer throws on values that cannot be a UUID. Neither may change a merge
/// result. The golden file holds the complete CRDT and domain state of every
/// replica after each step, recorded with the projector before the fix
/// (co-serverpod 28fa128): values, visibility, tombstones, field clocks and
/// attempted values.
///
/// | Scenario | Covers |
/// |---|---|
/// | Child insert under a stored parent with siblings | the co-serverpod#41 path, push and pull |
/// | Child update, child delete | payload and plain columns of a seeded child |
/// | Parent delete with a concurrent child insert, then restore | cascade hiding, restore |
/// | Folder delete racing a note move, then restore | set-null projection, attempted value kept and cleared |
/// | Attempted value on a sibling's plain column, on the server and a device | the only state a sibling's unread column could change, push and pull |
/// | Plain column cleared in a batch that also inserts | an update written by the projection pass |
/// | Concurrent inserts and a rename claiming a stored sibling's unique `(noteId, seq)` | unique planning on a sibling the pass only reaches, push and pull |
/// | Random writes on a server and two devices, 8 seeds, with colliding `seq` | everything above interleaved |
///
/// Not covered, because the fixture has no such edge: `SET DEFAULT`,
/// `RESTRICT` / `NO ACTION` and a table referencing itself. On those the pass
/// reads only foreign key and unique columns of a reached row
/// (`_closureBlockedByForeignKeys`, `_parentRowForValue`,
/// `_findSetDefaultDependents`), which the narrowing still loads, so reading
/// the code shows no change; a test does not pin it.
///
/// Hlcs are compared by rank and nodes by creation order, so the golden does
/// not depend on the wall clock or on random node ids. Run with
/// `FK41_WRITE_GOLDEN=1` to record it again, which is only valid on a
/// projector known to be correct.
///
/// [target] runs the same scenarios on another server database: the SQLite
/// fixture here, PostgreSQL in `offline_sync_watch_test_server`, each against
/// a golden of its own.
void defineForeignKeyProjectionGolden({
  required File goldenFile,
  required ForeignKeyProjectionTarget target,
}) {
  final writeGolden = Platform.environment['FK41_WRITE_GOLDEN'] == '1';
  final recorded = <String, Object?>{};
  final golden = writeGolden
      ? const <String, Object?>{}
      : jsonDecode(goldenFile.readAsStringSync()) as Map<String, Object?>;

  tearDownAll(() async {
    if (writeGolden) {
      goldenFile.parent.createSync(recursive: true);
      goldenFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(recorded)}\n',
      );
    }
  });

  Future<void> apart() => Future<void>.delayed(const Duration(milliseconds: 3));

  /// Compares the states [replicas] reached with the golden entry [key], or
  /// records them when writing the golden.
  Future<void> checkpoint(
    String key,
    Map<String, DatabaseSession> replicas,
  ) async {
    final state = await _normalizedState(replicas);
    if (writeGolden) {
      recorded[key] = state;
      return;
    }
    expect(state, golden[key], reason: 'state after $key');
  }

  group('Given a stored parent with children,', () {
    test(
      'should_write_what_the_projector_wrote_before_when_children_are_inserted_updated_deleted_and_the_parent_is_restored',
      () async {
        final ids = _Ids(1);
        final userId = ids.next();
        final server = await target.openServer(userId);
        final a = await target.openDevice(userId);
        final b = await target.openDevice(userId);
        final replicas = {'server': server, 'a': a, 'b': b};
        Future<void> sync(DatabaseSession device) =>
            target.sync(server, device, userId);

        final folder = await Folder.db.insertRow(
          a,
          Folder(id: ids.next(), name: 'f'),
        );
        await apart();
        final note = await Note.db.insertRow(
          a,
          Note(id: ids.next(), title: 'n', folderId: folder.id),
        );
        await apart();
        final strokes = await Stroke.db.insert(a, [
          for (var i = 0; i < 6; i++)
            Stroke(
              id: ids.next(),
              seq: 's$i',
              payload: _payload(i, 64),
              noteId: note.id!,
            ),
        ]);
        await Attachment.db.insert(a, [
          for (var i = 0; i < 2; i++)
            Attachment(id: ids.next(), name: 'a$i', noteId: note.id!),
        ]);
        await sync(a);
        await sync(b);
        await checkpoint('parent/seeded', replicas);

        await apart();
        await Stroke.db.insertRow(
          a,
          Stroke(
            id: ids.next(),
            seq: 'new',
            payload: _payload(99, 64),
            noteId: note.id!,
          ),
        );
        await sync(a);
        await sync(b);
        await checkpoint('parent/child_inserted', replicas);

        await apart();
        await Stroke.db.updateRow(
          a,
          strokes[2].copyWith(seq: 's2x', payload: _payload(22, 80)),
        );
        await sync(a);
        await sync(b);
        await checkpoint('parent/child_updated', replicas);

        await apart();
        await Stroke.db.deleteRow(a, strokes[3]);
        await sync(a);
        await sync(b);
        await checkpoint('parent/child_deleted', replicas);

        // B inserts under the note before it hears that A deleted it.
        await apart();
        await Note.db.deleteRow(a, note);
        await apart();
        await Stroke.db.insertRow(
          b,
          Stroke(
            id: ids.next(),
            seq: 'late',
            payload: _payload(7, 64),
            noteId: note.id!,
          ),
        );
        await sync(a);
        await sync(b);
        await sync(a);
        await checkpoint('parent/deleted_with_concurrent_child', replicas);

        await apart();
        await Note.db.insertRow(
          a,
          Note(id: note.id, title: 'n2', folderId: folder.id),
        );
        await sync(a);
        await sync(b);
        await checkpoint('parent/restored', replicas);
      },
    );
  });

  group('Given a folder deleted while another device moves a note into it,', () {
    test(
      'should_write_what_the_projector_wrote_before_when_set_null_keeps_and_then_clears_the_attempted_value',
      () async {
        final ids = _Ids(2);
        final userId = ids.next();
        final server = await target.openServer(userId);
        final a = await target.openDevice(userId);
        final b = await target.openDevice(userId);
        final replicas = {'server': server, 'a': a, 'b': b};
        Future<void> sync(DatabaseSession device) =>
            target.sync(server, device, userId);

        final folder = await Folder.db.insertRow(
          a,
          Folder(id: ids.next(), name: 'f'),
        );
        final note = await Note.db.insertRow(
          a,
          Note(id: ids.next(), title: 'n'),
        );
        await Stroke.db.insert(a, [
          for (var i = 0; i < 3; i++)
            Stroke(
              id: ids.next(),
              seq: 's$i',
              payload: _payload(i, 32),
              noteId: note.id!,
            ),
        ]);
        await sync(a);
        await sync(b);

        await apart();
        await Folder.db.deleteRow(a, folder);
        await apart();
        await Note.db.updateRow(
          b,
          note.copyWith(folderId: folder.id),
          columns: (t) => [t.folderId],
        );
        await sync(a);
        await sync(b);
        await sync(a);
        await checkpoint('set_null/attempted', replicas);

        await apart();
        await Folder.db.insertRow(a, Folder(id: folder.id, name: 'f2'));
        await sync(a);
        await sync(b);
        await checkpoint('set_null/restored', replicas);
      },
    );
  });

  group('Given an attempted value on a stored sibling\'s plain column,', () {
    test(
      'should_write_what_the_projector_wrote_before_when_a_child_is_merged_next_to_it',
      () async {
        final ids = _Ids(3);
        final userId = ids.next();
        final server = await target.openServer(userId);
        final a = await target.openDevice(userId);
        final b = await target.openDevice(userId);
        final replicas = {'server': server, 'a': a, 'b': b};
        Future<void> sync(DatabaseSession device) =>
            target.sync(server, device, userId);

        final note = await Note.db.insertRow(
          a,
          Note(id: ids.next(), title: 'n'),
        );
        final strokes = await Stroke.db.insert(a, [
          for (var i = 0; i < 3; i++)
            Stroke(
              id: ids.next(),
              seq: 's$i',
              payload: _payload(i, 32),
              noteId: note.id!,
            ),
        ]);
        await sync(a);
        await sync(b);
        // No projector writes this: an attempted value lives on foreign key
        // and unique columns only. A database from an older schema could
        // still hold one, and the pass before the fix rewrote its reason
        // whenever a merge read that column.
        // Planted on the server, which meets it on A's push, and on B, which
        // meets it on its pull.
        for (final replica in [server, b]) {
          await _plantAttemptedValue(
            replica,
            rowId: strokes[1].id!,
            columnName: 'legacyId',
            value: 'elsewhere',
            reason: CrdtProjectionReason.foreignKeySetNull,
          );
        }
        await checkpoint('stray/planted', replicas);

        // The insert names legacyId, so the pass reads it for the rows it
        // writes, and a sibling holding the attempted value is one of them.
        await apart();
        await Stroke.db.insertRow(
          a,
          Stroke(
            id: ids.next(),
            seq: 'new',
            legacyId: 'mine',
            payload: _payload(9, 32),
            noteId: note.id!,
          ),
        );
        await sync(a);
        await sync(b);
        await checkpoint('stray/child_merged', replicas);
      },
    );
  });

  group('Given a batch that clears a plain column and inserts a sibling,', () {
    test(
      'should_write_what_the_projector_wrote_before_when_the_update_rides_the_projection_pass',
      () async {
        final ids = _Ids(4);
        final userId = ids.next();
        final server = await target.openServer(userId);
        final a = await target.openDevice(userId);
        final b = await target.openDevice(userId);
        final replicas = {'server': server, 'a': a, 'b': b};
        Future<void> sync(DatabaseSession device) =>
            target.sync(server, device, userId);

        final note = await Note.db.insertRow(
          a,
          Note(id: ids.next(), title: 'n'),
        );
        final strokes = await Stroke.db.insert(a, [
          for (var i = 0; i < 3; i++)
            Stroke(
              id: ids.next(),
              seq: 's$i',
              legacyId: i == 2 ? null : 'x$i',
              payload: _payload(i, 32),
              noteId: note.id!,
            ),
        ]);
        await sync(a);
        await sync(b);

        // The insert makes the batch need projection, so the updates are
        // written by the pass, as overlays, not straight to their rows.
        await apart();
        await Stroke.db.updateRow(
          a,
          strokes[1].copyWith(legacyId: null),
          columns: (t) => [t.legacyId],
        );
        await Stroke.db.updateRow(
          a,
          strokes[2].copyWith(legacyId: 'y2'),
          columns: (t) => [t.legacyId],
        );
        await Stroke.db.insertRow(
          a,
          Stroke(
            id: ids.next(),
            seq: 'new',
            payload: _payload(9, 32),
            noteId: note.id!,
          ),
        );
        await sync(a);
        await sync(b);
        await checkpoint('overlay/cleared_with_insert', replicas);
      },
    );
  });

  group('Given two devices claiming a stored sibling\'s unique seq,', () {
    test(
      'should_write_what_the_projector_wrote_before_when_the_claims_meet_on_push_and_pull',
      () async {
        final ids = _Ids(5);
        final userId = ids.next();
        final server = await target.openServer(userId);
        final a = await target.openDevice(userId);
        final b = await target.openDevice(userId);
        final replicas = {'server': server, 'a': a, 'b': b};
        Future<void> sync(DatabaseSession device) =>
            target.sync(server, device, userId);

        final note = await Note.db.insertRow(
          a,
          Note(id: ids.next(), title: 'n'),
        );
        final strokes = await Stroke.db.insert(a, [
          for (var i = 0; i < 4; i++)
            Stroke(
              id: ids.next(),
              seq: 's$i',
              payload: _payload(i, 32),
              noteId: note.id!,
            ),
        ]);
        await sync(a);
        await sync(b);

        // A and B insert the same (noteId, seq) without hearing of each
        // other. B's merges next to A's, a stored sibling by then.
        await apart();
        await Stroke.db.insertRow(
          a,
          Stroke(
            id: ids.next(),
            seq: 'c',
            payload: _payload(40, 32),
            noteId: note.id!,
          ),
        );
        await apart();
        await Stroke.db.insertRow(
          b,
          Stroke(
            id: ids.next(),
            seq: 'c',
            payload: _payload(41, 32),
            noteId: note.id!,
          ),
        );
        await sync(a);
        await sync(b);
        await sync(a);
        await checkpoint('unique/concurrent_inserts', replicas);

        // A renames a stored sibling to the seq B inserts, then A frees it.
        await apart();
        await Stroke.db.updateRow(
          a,
          strokes[1].copyWith(seq: 'd'),
          columns: (t) => [t.seq],
        );
        await apart();
        await Stroke.db.insertRow(
          b,
          Stroke(
            id: ids.next(),
            seq: 'd',
            payload: _payload(42, 32),
            noteId: note.id!,
          ),
        );
        await sync(a);
        await sync(b);
        await sync(a);
        await checkpoint('unique/rename_against_insert', replicas);

        await apart();
        await Stroke.db.updateRow(
          a,
          strokes[1].copyWith(seq: 's1'),
          columns: (t) => [t.seq],
        );
        await sync(a);
        await sync(b);
        await sync(a);
        await checkpoint('unique/released', replicas);
      },
    );
  });

  group('Given random writes on a server and two devices,', () {
    for (var seed = 1; seed <= 8; seed++) {
      test(
        'should_write_what_the_projector_wrote_before_for_seed_$seed',
        () async {
          final ids = _Ids(100 + seed);
          final userId = ids.next();
          final server = await target.openServer(userId);
          final phone = await target.openDevice(userId);
          final tablet = await target.openDevice(userId);
          await _runRandomWrites(
            seed,
            ids,
            writers: [if (target.serverWrites) server, phone, tablet],
            devices: [phone, tablet],
            sync: (device) => target.sync(server, device, userId),
            apart: apart,
          );
          await checkpoint('random/$seed', {
            'server': server,
            'phone': phone,
            'tablet': tablet,
          });
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}

/// Deterministic row ids, distinct per [scope].
class _Ids {
  _Ids(this.scope);

  final int scope;
  var _next = 0;

  UuidValue next() => UuidValue.fromString(
    '${scope.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-'
    '${(++_next).toRadixString(16).padLeft(12, '0')}',
  );
}

/// [length] deterministic bytes for [seed].
ByteData _payload(int seed, int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (seed * 31 + i * 7) & 0xff;
  }
  return ByteData.sublistView(bytes);
}

/// Stores an attempted value for [columnName] of the stroke [rowId] on
/// [replica], creating the field metadata when the column has none.
Future<void> _plantAttemptedValue(
  DatabaseSession replica, {
  required UuidValue rowId,
  required String columnName,
  required Object? value,
  required CrdtProjectionReason reason,
}) async {
  final row = (await CrdtDataRow.db.findFirstRow(
    replica,
    where: (t) => t.uuidRowId.equals(rowId),
  ))!;
  final column = (await CrdtSchemaColumn.db.findFirstRow(
    replica,
    where: (t) => t.tbl.name.equals('stroke') & t.name.equals(columnName),
  ))!;
  final field =
      await CrdtDataField.db.findFirstRow(
        replica,
        where: (t) => t.rowId.equals(row.id) & t.columnId.equals(column.id),
      ) ??
      await CrdtDataField.db.insertRow(
        replica,
        CrdtDataField(
          rowId: row.id!,
          columnId: column.id!,
          nodeId: row.nodeId,
          hlcDatetime: row.hlcDatetime,
          hlcCounter: row.hlcCounter,
        ),
      );
  await CrdtDataAttemptedValue.db.insertRow(
    replica,
    CrdtDataAttemptedValue(
      fieldId: field.id!,
      value: value,
      projectionReason: reason,
    ),
  );
}

/// Random local writes on [writers], with syncs of [devices] in between, then
/// a final round so every replica has heard of every write.
Future<void> _runRandomWrites(
  int seed,
  _Ids ids, {
  required List<DatabaseSession> writers,
  required List<DatabaseSession> devices,
  required Future<void> Function(DatabaseSession device) sync,
  required Future<void> Function() apart,
}) async {
  final random = Random(seed);
  final folderIds = <UuidValue>[];
  final noteIds = <UuidValue>[];
  final strokeIds = <UuidValue>[];
  T? pick<T>(List<T> from) =>
      from.isEmpty ? null : from[random.nextInt(from.length)];

  /// A seq for a stroke of [noteId]: often one of a few shared ones, so
  /// replicas claim the same unique `(noteId, seq)` concurrently. Null when
  /// the replica already holds it, where the local write would fail.
  String? seqFor(int step, UuidValue noteId, List<Stroke> strokes) {
    final seq = random.nextInt(3) == 0 ? 'q${random.nextInt(3)}' : 's$step';
    final taken = strokes.any(
      (stroke) => stroke.noteId == noteId && stroke.seq == seq,
    );
    return taken ? null : seq;
  }

  for (var step = 0; step < 40; step++) {
    await apart();
    final replica = writers[random.nextInt(writers.length)];
    final folders = await Folder.db.find(replica, orderBy: (t) => t.id);
    final notes = await Note.db.find(replica, orderBy: (t) => t.id);
    final strokes = await Stroke.db.find(replica, orderBy: (t) => t.id);
    switch (random.nextInt(12)) {
      case 0:
        final id = ids.next();
        folderIds.add(id);
        await Folder.db.insertRow(replica, Folder(id: id, name: 'f$step'));
      case 1:
        final id = ids.next();
        noteIds.add(id);
        await Note.db.insertRow(
          replica,
          Note(id: id, title: 'n$step', folderId: pick(folders)?.id),
        );
      case 2 || 3 || 4:
        final note = pick(notes);
        if (note == null) continue;
        final seq = seqFor(step, note.id!, strokes);
        if (seq == null) continue;
        final id = ids.next();
        strokeIds.add(id);
        await Stroke.db.insertRow(
          replica,
          Stroke(
            id: id,
            seq: seq,
            legacyId: random.nextBool() ? null : 'l$step',
            payload: _payload(step, 16 + random.nextInt(48)),
            noteId: note.id!,
          ),
        );
      case 5:
        final stroke = pick(strokes);
        if (stroke == null) continue;
        final seq = seqFor(step, stroke.noteId, strokes);
        if (seq == null) continue;
        await Stroke.db.updateRow(
          replica,
          stroke.copyWith(
            payload: _payload(step, 24),
            seq: seq,
            legacyId: random.nextBool() ? null : 'u$step',
          ),
        );
      case 6:
        final note = pick(notes);
        if (note == null) continue;
        await Note.db.updateRow(
          replica,
          note.copyWith(folderId: pick(folders)?.id),
          columns: (t) => [t.folderId],
        );
      case 7:
        final stroke = pick(strokes);
        if (stroke == null) continue;
        await Stroke.db.deleteRow(replica, stroke);
      case 8:
        final note = pick(notes);
        if (note == null) continue;
        await Note.db.deleteRow(replica, note);
      case 9:
        final folder = pick(folders);
        if (folder == null) continue;
        await Folder.db.deleteRow(replica, folder);
      case 10:
        // Restore a note this replica holds hidden.
        final visible = {for (final note in notes) note.id};
        final hidden = [
          for (final id in noteIds)
            if (!visible.contains(id) &&
                await CrdtDataRow.db.findFirstRow(
                      replica,
                      where: (t) => t.uuidRowId.equals(id),
                    ) !=
                    null)
              id,
        ];
        final id = pick(hidden);
        if (id == null) continue;
        await Note.db.insertRow(replica, Note(id: id, title: 'r$step'));
      default:
        final device = pick(devices)!;
        await sync(device);
    }
  }
  for (var round = 0; round < 2; round++) {
    for (final device in devices) {
      await sync(device);
    }
  }
}

/// Every replica's CRDT metadata and domain rows, independent of the wall
/// clock and of random node ids.
///
/// Hlcs become their rank among all hlcs of [replicas]; nodes become their
/// position in the order the replica created them.
Future<Map<String, Object?>> _normalizedState(
  Map<String, DatabaseSession> replicas,
) async {
  final raw = <String, _RawState>{
    for (final MapEntry(key: name, value: replica) in replicas.entries)
      name: await _readState(replica),
  };
  final hlcs =
      <(DateTime, int)>{for (final state in raw.values) ...state.hlcs}.toList()
        ..sort((l, r) {
          final byTime = l.$1.compareTo(r.$1);
          return byTime != 0 ? byTime : l.$2.compareTo(r.$2);
        });
  final rank = {for (final (index, hlc) in hlcs.indexed) hlc: index};
  final nodeNames = <String, String>{};
  for (final state in raw.values) {
    for (final uuid in state.nodeOrder) {
      nodeNames.putIfAbsent(uuid, () => 'node${nodeNames.length}');
    }
  }
  return {
    for (final MapEntry(key: name, value: state) in raw.entries)
      name: state.render(rank, nodeNames),
  };
}

class _RawState {
  final hlcs = <(DateTime, int)>{};
  final nodeOrder = <String>[];
  final lines = <List<Object?>>[];

  String _render(
    Object? part,
    Map<(DateTime, int), int> rank,
    Map<String, String> nodeNames,
  ) => switch (part) {
    (final DateTime time, final int counter) => 'hlc${rank[(time, counter)]}',
    _NodeRef(:final uuid) => uuid == null ? 'node-' : nodeNames[uuid]!,
    _ => '$part',
  };

  List<String> render(
    Map<(DateTime, int), int> rank,
    Map<String, String> nodeNames,
  ) => [
    for (final line in lines)
      line.map((part) => _render(part, rank, nodeNames)).join(' '),
  ]..sort();
}

class _NodeRef {
  _NodeRef(this.uuid);

  final String? uuid;
}

Future<_RawState> _readState(DatabaseSession replica) async {
  final state = _RawState();
  (DateTime, int) hlc(DateTime time, int counter) {
    final value = (time.toUtc(), counter);
    state.hlcs.add(value);
    return value;
  }

  final nodes = await CrdtNode.db.find(replica, orderBy: (t) => t.id);
  final nodeUuidById = <int, String>{};
  for (final node in nodes) {
    final uuid = node.uuidNodeId.uuid;
    nodeUuidById[node.id!] = uuid;
    state.nodeOrder.add(uuid);
  }
  _NodeRef node(int? id) => _NodeRef(id == null ? null : nodeUuidById[id]);
  for (final crdtNode in nodes) {
    final last = crdtNode.lastHlc;
    state.lines.add([
      'node',
      node(crdtNode.id),
      if (last == null) 'last=-' else hlc(last.datetime, last.counter),
    ]);
  }

  final rows = await CrdtDataRow.db.find(
    replica,
    include: CrdtDataRow.include(
      tbl: CrdtSchemaTable.include(),
      deleted: CrdtDataDeleted.include(),
    ),
  );
  for (final row in rows) {
    final deleted = row.deleted;
    state.lines.add([
      'row',
      row.tbl!.name,
      row.uuidRowId.uuid,
      'vis=${row.visibility.name}',
      node(row.nodeId),
      hlc(row.hlcDatetime, row.hlcCounter),
      if (deleted == null)
        'deleted=-'
      else ...[
        'deleted=${deleted.clFlag}/${deleted.reason.name}',
        node(deleted.nodeId),
        hlc(deleted.hlcDatetime, deleted.hlcCounter),
      ],
    ]);
  }

  final fields = await CrdtDataField.db.find(
    replica,
    include: CrdtDataField.include(
      row: CrdtDataRow.include(tbl: CrdtSchemaTable.include()),
      column: CrdtSchemaColumn.include(),
      attemptedValue: CrdtDataAttemptedValue.include(),
    ),
  );
  for (final field in fields) {
    final attempted = field.attemptedValue;
    state.lines.add([
      'field',
      field.row!.tbl!.name,
      field.row!.uuidRowId.uuid,
      field.column!.name,
      node(field.nodeId),
      hlc(field.hlcDatetime, field.hlcCounter),
      if (attempted == null)
        'attempted=-'
      else
        'attempted=${_value(attempted.value)}/'
            '${attempted.projectionReason.name}',
    ]);
  }
  final attemptedCount = await CrdtDataAttemptedValue.db.count(replica);
  state.lines.add(['attempted_rows', attemptedCount]);

  for (final table in ['folder', 'note', 'attachment', 'stroke']) {
    final result = await replica.db.unsafeQuery(
      'SELECT * FROM "$table" ORDER BY "id"',
    );
    for (final row in result) {
      final columns = row.toColumnMap();
      final id = _uuid(columns.remove('id'));
      for (final MapEntry(key: column, value: value)
          in (columns.entries.toList()
            ..sort((l, r) => l.key.compareTo(r.key)))) {
        final rendered = column.endsWith('Id') ? _uuid(value) : _value(value);
        state.lines.add(['domain', table, id, '$column=$rendered']);
      }
    }
  }
  return state;
}

/// A UUID column as SQLite returns it (16 bytes) or as text.
String _uuid(Object? value) => switch (value) {
  null => 'null',
  Uint8List() when value.length == 16 => UuidValue.fromByteList(value).uuid,
  _ => _value(value),
};

/// A stable rendering of a domain or attempted value.
String _value(Object? value) => switch (value) {
  null => 'null',
  Uint8List() => 'bytes${value.length}:${_hash(value)}',
  ByteData() =>
    'bytes${value.lengthInBytes}:'
        '${_hash(value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes))}',
  UuidValue() => value.uuid,
  _ => '$value',
};

String _hash(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
