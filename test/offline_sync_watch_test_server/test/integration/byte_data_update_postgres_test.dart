import 'dart:typed_data';

import 'package:offline_sync_watch_test_server/src/generated/protocol.dart';
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:test/test.dart';

import 'test_tools/embedded_postgres.dart';
import 'test_tools/serverpod_test_tools.dart';

/// The tracked update/updateRow path must pass binary values to PostgreSQL,
/// not the SQL literal strings produced by toJsonForDatabase (unibook#14684).
void main() {
  final postgres = TestPostgres('bytes14684');
  setUpAll(postgres.prepare);
  tearDownAll(postgres.dispose);

  withServerpod(
    'PostgreSQL tracked ByteData updates',
    (sessionBuilder, _) {
      late OfflineSyncDatabaseSession session;
      late UuidValue userId;
      var sequence = 0;

      setUp(() async {
        session = OfflineSyncDatabaseSession(
          sessionBuilder.build().db,
          syncTables: syncTables,
        );
        await session.db.initialize();
        userId = UuidValue.fromString(
          '14684000-0000-4000-8000-${(++sequence).toString().padLeft(12, '0')}',
        );
      });

      test(
        'should_round_trip_payload_when_updateRow_selects_binary_column',
        () {
          return session.db.transactionForUser(userId, (tx) async {
            final original = await _seedStroke(session, tx, _bytes([1, 2, 3]));
            final updated = await Stroke.db.updateRow(
              session,
              original.copyWith(
                payload: _bytes([0x52, 1, 0x62]),
                seq: 'ignored',
              ),
              columns: (t) => [t.payload],
              transaction: tx,
            );
            final stored = await Stroke.db.findById(
              session,
              original.id!,
              transaction: tx,
            );

            expect(Uint8List.sublistView(updated.payload), [0x52, 1, 0x62]);
            expect(Uint8List.sublistView(stored!.payload), [0x52, 1, 0x62]);
            expect(stored.seq, original.seq);
            expect(stored.noteId, original.noteId);
          });
        },
      );

      test(
        'should_preserve_empty_and_sliced_payloads_when_update_writes_rows',
        () {
          return session.db.transactionForUser(userId, (tx) async {
            final first = await _seedStroke(session, tx, _bytes([1]));
            final second = await _seedStroke(session, tx, _bytes([2]));
            final buffer = Uint8List.fromList([9, 9, 0, 0xff, 0x52, 9]);
            final updated = await session.db.update<Stroke>([
              first.copyWith(
                payload: ByteData(0),
                seq: 'empty',
                legacyId: null,
              ),
              second.copyWith(
                payload: ByteData.sublistView(buffer, 2, 5),
                seq: 'slice',
                legacyId: null,
              ),
            ], transaction: tx);
            final byId = {for (final row in updated) row.id!: row};
            expect(Uint8List.sublistView(byId[first.id]!.payload), isEmpty);
            expect(Uint8List.sublistView(byId[second.id]!.payload), [
              0,
              0xff,
              0x52,
            ]);

            final storedFirst = await Stroke.db.findById(
              session,
              first.id!,
              transaction: tx,
            );
            final storedSecond = await Stroke.db.findById(
              session,
              second.id!,
              transaction: tx,
            );
            expect(Uint8List.sublistView(storedFirst!.payload), isEmpty);
            expect(Uint8List.sublistView(storedSecond!.payload), [
              0,
              0xff,
              0x52,
            ]);
            expect(storedFirst.seq, 'empty');
            expect(storedSecond.seq, 'slice');
            expect(storedFirst.legacyId, isNull);
            expect(storedSecond.legacyId, isNull);
            expect(storedFirst.noteId, first.noteId);
            expect(storedSecond.noteId, second.noteId);
          });
        },
      );

      test('should_leave_payload_when_binary_column_is_not_selected', () {
        return session.db.transactionForUser(userId, (tx) async {
          final original = await _seedStroke(session, tx, _bytes([0, 0xff, 7]));
          await Stroke.db.updateRow(
            session,
            original.copyWith(payload: _bytes([99]), seq: 'new'),
            columns: (t) => [t.seq],
            transaction: tx,
          );
          final stored = await Stroke.db.findById(
            session,
            original.id!,
            transaction: tx,
          );

          expect(Uint8List.sublistView(stored!.payload), [0, 0xff, 7]);
          expect(stored.seq, 'new');
          expect(stored.legacyId, 'legacy');
        });
      });

      test(
        'should_restore_payload_when_update_transaction_rolls_back',
        () async {
          final original = await session.db.transactionForUser(
            userId,
            (tx) => _seedStroke(session, tx, _bytes([0, 0xff, 7])),
          );
          await expectLater(
            session.db.transactionForUser<void>(userId, (tx) async {
              await Stroke.db.updateRow(
                session,
                original.copyWith(payload: _bytes([0x52, 1, 0x62])),
                columns: (t) => [t.payload],
                transaction: tx,
              );
              throw StateError('rollback the test update');
            }),
            throwsStateError,
          );
          await session.db.transactionForUser(userId, (tx) async {
            final stored = await Stroke.db.findById(
              session,
              original.id!,
              transaction: tx,
            );
            expect(Uint8List.sublistView(stored!.payload), [0, 0xff, 7]);
          });
        },
      );
    },
    rollbackDatabase: RollbackDatabase.disabled,
    serverDirectory: postgres.serverDirectory,
    configOverride: (config) => config.copyWith(
      apiServer: ServerConfig(
        port: 0,
        publicHost: 'localhost',
        publicPort: 0,
        publicScheme: 'http',
      ),
      database: postgres.config(),
    ),
  );
}

ByteData _bytes(List<int> bytes) =>
    ByteData.sublistView(Uint8List.fromList(bytes));

Future<Stroke> _seedStroke(
  OfflineSyncDatabaseSession session,
  Transaction transaction,
  ByteData payload,
) async {
  final note = await Note.db.insertRow(
    session,
    Note(title: 'unibook#14684'),
    transaction: transaction,
  );
  return Stroke.db.insertRow(
    session,
    Stroke(
      seq: 'original',
      legacyId: 'legacy',
      payload: payload,
      noteId: note.id!,
    ),
    transaction: transaction,
  );
}
