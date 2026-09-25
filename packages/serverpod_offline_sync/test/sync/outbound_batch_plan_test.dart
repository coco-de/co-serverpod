import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:serverpod_offline_sync/src/sync/outbound_batch.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Where a peer may end an outbound batch, and how a batch is counted against
/// its budget (fork, unibook#14251).
///
/// The planner is pure: it orders and cuts what the engine read from the CRDT
/// tables. The engine's use of it, over real SQLite replicas, is tested in
/// `test/offline_sync_watch_test_client/test/batch_budget_test.dart`; the
/// cascade case needs a cascading foreign key the fixture schema does not
/// have, so its shape is pinned here with the stamping order the recorder
/// produces (`_softDeleteRowsByTable`: the deleted parents, then their cascade
/// children, each with its own increment).
void main() {
  final device = UuidValue.fromString('00000000-0000-7000-8000-00000000000d');
  final other = UuidValue.fromString('00000000-0000-7000-8000-00000000000e');
  final t0 = DateTime.utc(2026, 9, 25, 12);

  Hlc hlc(int counter, [UuidValue? node, int millisecond = 0]) =>
      Hlc(t0.add(Duration(milliseconds: millisecond)), counter, node ?? device);

  UuidValue rowId(int n) =>
      UuidValue.fromString('00000000-0000-7000-8000-${n.toString().padLeft(12, '0')}');

  OutboundChangeRef insert(Hlc hlc, int row, {String table = 'note'}) => (
    hlc: hlc,
    kind: OutboundChangeKind.insert,
    tableName: table,
    rowId: rowId(row),
    columnName: null,
    deleteReason: null,
  );

  OutboundChangeRef update(Hlc hlc, int row, {String column = 'title'}) => (
    hlc: hlc,
    kind: OutboundChangeKind.update,
    tableName: 'note',
    rowId: rowId(row),
    columnName: column,
    deleteReason: null,
  );

  OutboundChangeRef delete(
    Hlc hlc,
    int row, {
    String table = 'note',
    CrdtDataDeletedReason reason = CrdtDataDeletedReason.userDelete,
  }) => (
    hlc: hlc,
    kind: OutboundChangeKind.delete,
    tableName: table,
    rowId: rowId(row),
    columnName: null,
    deleteReason: reason,
  );

  /// The units as lists of parts of indices, for readable expectations.
  List<List<List<int>>> shape(List<OutboundChangeRef> changes) => [
    for (final unit in planOutboundUnits(changes)) unit.parts,
  ];

  group('Given pending changes collected in upstream order,', () {
    test(
      'when they are planned, then they go in HLC order, not inserts first',
      () {
        // Upstream collects inserts, then updates, then deletes. An update
        // stamped before an insert must still go first: a batch that ended
        // after the insert would move the checkpoint past the update.
        final changes = [
          insert(hlc(2), 2),
          insert(hlc(3), 3),
          update(hlc(1), 1),
          delete(hlc(4), 4),
        ];

        expect(shape(changes), [
          [
            [2],
          ],
          [
            [0],
          ],
          [
            [1],
          ],
          [
            [3],
          ],
        ]);
      },
    );

    test(
      'when two changes share an HLC, then no cut goes between them',
      () {
        final changes = [update(hlc(1), 1), update(hlc(1), 1, column: 'archived')];

        // Same HLC: ordered by kind, table, row, then column ('archived' first).
        expect(shape(changes), [
          [
            [1, 0],
          ],
        ]);
      },
    );

    test(
      'when changes of two nodes share a datetime and counter, then they are '
      'separate: only the same HLC of the same node is kept together',
      () {
        final changes = [update(hlc(1, other), 2), update(hlc(1), 1)];

        expect(shape(changes), hasLength(2));
      },
    );

    test(
      'when a row has a delete stamped before its insert, then the delete and '
      'the insert are one part',
      () {
        // A delete of a later generation from another node can carry an older
        // HLC than a concurrent re-insertion. A receiver without the row drops
        // a delete that arrives in an earlier batch than the insert.
        final changes = [
          delete(hlc(1, other), 1, reason: CrdtDataDeletedReason.userDelete),
          update(hlc(2), 9),
          insert(hlc(3), 1),
          update(hlc(4), 1),
        ];

        expect(shape(changes), [
          [
            [0, 1, 2],
          ],
          [
            [3],
          ],
        ]);
      },
    );

    test(
      'when a row is inserted and later updated and deleted, then each goes on '
      'its own: the receiver has the row by then',
      () {
        final changes = [insert(hlc(1), 1), update(hlc(2), 1), delete(hlc(3), 1)];

        expect(shape(changes), [
          [
            [0],
          ],
          [
            [1],
          ],
          [
            [2],
          ],
        ]);
      },
    );
  });

  group('Given a delete that cascaded,', () {
    test(
      'when several parents cascaded in one delete, then the parents and every '
      'cascade delete are one unit of single-change parts',
      () {
        // The recorder stamps the deleted parents first, then the children.
        final changes = [
          delete(hlc(1), 1, table: 'page'),
          delete(hlc(2), 2, table: 'page'),
          delete(
            hlc(3),
            1,
            table: 'page_meta',
            reason: CrdtDataDeletedReason.userCascadeDelete,
          ),
          delete(
            hlc(4),
            2,
            table: 'page_meta',
            reason: CrdtDataDeletedReason.userCascadeDelete,
          ),
        ];

        expect(shape(changes), [
          [
            [0],
            [1],
            [2],
            [3],
          ],
        ]);
      },
    );

    test(
      "when another node's change sorts between a delete and its cascade, then "
      'the unit still spans both',
      () {
        final changes = [
          delete(hlc(1), 1, table: 'page'),
          update(hlc(1, other, 0), 7),
          delete(
            hlc(2),
            1,
            table: 'page_meta',
            reason: CrdtDataDeletedReason.userCascadeDelete,
          ),
        ];
        // `other` sorts after `device` at the same datetime and counter.
        expect(other.uuid.compareTo(device.uuid), greaterThan(0));

        expect(shape(changes), [
          [
            [0],
            [1],
            [2],
          ],
        ]);
      },
    );

    test(
      'when the node wrote something else between an earlier delete and a '
      'cascading one, then the earlier delete stays a unit of its own',
      () {
        final changes = [
          delete(hlc(1), 5),
          update(hlc(2), 6),
          delete(hlc(3), 1, table: 'page'),
          delete(
            hlc(4),
            1,
            table: 'page_meta',
            reason: CrdtDataDeletedReason.userCascadeDelete,
          ),
        ];

        expect(shape(changes), [
          [
            [0],
          ],
          [
            [1],
          ],
          [
            [2],
            [3],
          ],
        ]);
      },
    );

    test(
      'when deletes cascade nothing, then each is a unit of its own',
      () {
        final changes = [delete(hlc(1), 1), delete(hlc(2), 2), delete(hlc(3), 3)];

        expect(shape(changes), hasLength(3));
      },
    );
  });

  test('Given no pending change, when planned, then there is no unit', () {
    expect(planOutboundUnits(const []), isEmpty);
  });

  group('Given an OfflineSyncBatchBudget,', () {
    test('when it is unlimited, then it sets no limit', () {
      expect(OfflineSyncBatchBudget.unlimited.isUnlimited, isTrue);
      expect(OfflineSyncBatchBudget(maxChanges: 1).isUnlimited, isFalse);
    });

    test('when it is built wrong, then it throws ArgumentError', () {
      expect(() => OfflineSyncBatchBudget(maxChanges: 0), throwsArgumentError);
      expect(
        () => OfflineSyncBatchBudget(maxPayloadChars: 0, measurePayload: (_) => 0),
        throwsArgumentError,
      );
      expect(OfflineSyncBatchBudget.new, throwsArgumentError);
      expect(() => OfflineSyncBatchBudget(maxPayloadChars: 10), throwsArgumentError);
    });

    test(
      'when a batch reaches a limit exactly, then it fits; one more does not',
      () {
        final meter = OutboundBatchMeter(
          OfflineSyncBatchBudget(
            maxChanges: 3,
            maxPayloadChars: 10,
            measurePayload: (_) => 0,
          ),
        );
        expect(meter.isEmpty, isTrue);

        expect(meter.fits(changes: 3, payloadChars: 10), isTrue);
        meter.add(changes: 2, payloadChars: 6);
        expect(meter.fitsChanges(1), isTrue);
        expect(meter.fitsChanges(2), isFalse);
        expect(meter.fits(changes: 1, payloadChars: 4), isTrue);
        expect(meter.fits(changes: 1, payloadChars: 5), isFalse);
        expect(meter.isEmpty, isFalse);
      },
    );

    test(
      'when the measure returns a negative payload, then counting throws',
      () {
        final meter = OutboundBatchMeter(
          OfflineSyncBatchBudget(maxPayloadChars: 10, measurePayload: (_) => -1),
        );
        final change = CrdtMergeDelete(
          uuidSpaceId: device,
          hlcDatetime: t0,
          hlcCounter: 0,
          tableName: 'note',
          uuidRowId: rowId(1),
          uuidNodeId: device,
          clFlag: 2,
          reason: CrdtDataDeletedReason.userDelete,
        );

        expect(() => meter.payloadOf(change), throwsStateError);
      },
    );

    test(
      'when there is no payload limit, then the measure is not called',
      () {
        var calls = 0;
        final meter = OutboundBatchMeter(
          OfflineSyncBatchBudget(
            maxChanges: 1,
            measurePayload: (_) {
              calls++;
              return 5;
            },
          ),
        );
        final change = CrdtMergeDelete(
          uuidSpaceId: device,
          hlcDatetime: t0,
          hlcCounter: 0,
          tableName: 'note',
          uuidRowId: rowId(1),
          uuidNodeId: device,
          clFlag: 2,
          reason: CrdtDataDeletedReason.userDelete,
        );

        expect(meter.payloadOf(change), 0);
        expect(calls, 0);
      },
    );
  });

  group('Given the end-of-batch frame,', () {
    test('when it says there is more, then the flag survives the wire', () {
      final json = OfflineSyncEndOfBatch(hasMore: true).toJson();

      expect(json['hasMore'], isTrue);
      expect(OfflineSyncEndOfBatch.fromJson(json).hasMore, isTrue);
      expect(
        OfflineSyncEndOfBatch.fromJson(
          OfflineSyncEndOfBatch(hasMore: false).toJson(),
        ).hasMore,
        isFalse,
      );
    });

    test(
      'when it comes from a peer built before the flag, then the flag is null',
      () {
        final json = {'__className__': 'serverpod_offline_sync.OfflineSyncEndOfBatch'};

        expect(OfflineSyncEndOfBatch.fromJson(json).hasMore, isNull);
        expect(OfflineSyncEndOfBatch().toJson().containsKey('hasMore'), isFalse);
      },
    );
  });
}
