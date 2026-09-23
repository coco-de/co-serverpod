import 'dart:async';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:test/test.dart';

import 'test_tools/serverpod_test_tools.dart';

/// Server module wiring for the drift limit and the wire failure mapping.
///
/// `serverpod_test` hands a streaming endpoint's error to the test unchanged,
/// so these cases cannot show that a plain exception is dropped on a real
/// socket. They pin that the facade and the generated endpoint emit the
/// serializable [OfflineSyncRemoteException]; the shared package's
/// `failure_mapping_test.dart` pins that it survives the wire.
void main() {
  withServerpod('[Offline sync drift and failure mapping]', (
    sessionBuilder,
    endpoints,
  ) {
    late Session session;

    setUp(() {
      session = sessionBuilder.build();
      session.serverpod.initializeOfflineSync(syncTables: []);
    });

    group('Given initializeOfflineSync,', () {
      test('when no drift is passed, then the session uses the one-hour default.', () {
        expect(session.offlineSync.maxClockDrift, Hlc.defaultMaxDrift);
      });

      test('when a drift is passed, then the session engine uses it.', () {
        session.serverpod.initializeOfflineSync(
          syncTables: [],
          maxClockDrift: const Duration(minutes: 5),
        );

        expect(session.offlineSync.maxClockDrift, const Duration(minutes: 5));
      });
    });

    group('Given the session facade over an engine that fails,', () {
      Future<Object> firstErrorOf(Object error) async {
        final events = OfflineSyncSession(session, _FailingEngine(error)).sync(
          userId: const Uuid().v7obj(),
          inbound: const Stream.empty(),
          mode: OfflineSyncPeerMode.authoritative,
        );
        final received = <Object>[];
        await events.handleError(received.add).drain<void>();
        expect(received, hasLength(1));
        return received.single;
      }

      test(
        'when a device timestamp is ahead of the server clock, '
        'then the stream fails with a clockDrift remote exception.',
        () async {
          final error = await firstErrorOf(
            _drift(ClockDriftKind.remoteAhead),
          );

          expect(
            error,
            isA<OfflineSyncRemoteException>()
                .having((e) => e.code, 'code', OfflineSyncFailureCode.clockDrift)
                .having((e) => e.driftMs, 'driftMs', 3600001),
          );
        },
      );

      test(
        'when the server cannot issue its own timestamp, '
        'then the stream fails with a serverClockDrift remote exception.',
        () async {
          final error = await firstErrorOf(_drift(ClockDriftKind.localAhead));

          expect(
            error,
            isA<OfflineSyncRemoteException>().having(
              (e) => e.code,
              'code',
              OfflineSyncFailureCode.serverClockDrift,
            ),
          );
        },
      );

      test(
        'when the failure is not a sync failure, then it passes unchanged.',
        () async {
          final failure = StateError('unrelated');

          expect(await firstErrorOf(failure), same(failure));
        },
      );
    });

    group('Given a user who may only read a shared space,', () {
      test(
        'when the device pushes a change into that space through the endpoint, '
        'then the stream fails with an integrityViolation remote exception.',
        () async {
          final user = const Uuid().v7obj();
          final readOnlySpace = await session.offlineSync.spaces.createFor(
            user,
            role: OfflineSyncSpaceRole.readOnly,
          );
          final device = StreamController<OfflineSyncStreamEvent>();
          addTearDown(device.close);

          final server = StreamIterator(
            endpoints.offlineSync.sync(
              sessionBuilder.copyWith(
                authentication: AuthenticationOverride.authenticationInfo(
                  user.uuid,
                  {},
                ),
              ),
              changes: device.stream,
              once: true,
            ),
          );
          addTearDown(server.cancel);

          expect(await server.moveNext(), isTrue);
          final serverConnect = server.current as OfflineSyncConnect;
          device
            ..add(
              OfflineSyncConnect(
                localNodeId: const Uuid().v7obj(),
                syncTablesHash: serverConnect.syncTablesHash,
              ),
            )
            ..add(OfflineSyncSpaceSet(spaces: []))
            ..add(
              OfflineSyncMergeChunk(
                changes: [
                  CrdtMergeInsert(
                    uuidSpaceId: readOnlySpace,
                    hlcDatetime: DateTime.now().toUtc(),
                    hlcCounter: 0,
                    tableName: 'note',
                    uuidRowId: const Uuid().v7obj(),
                    uuidNodeId: const Uuid().v7obj(),
                    data: const <String, dynamic>{},
                  ),
                ],
              ),
            )
            ..add(OfflineSyncEndOfBatch());

          Object? failure;
          try {
            while (await server.moveNext()) {}
          } on Object catch (error) {
            failure = error;
          }

          expect(
            failure,
            isA<OfflineSyncRemoteException>().having(
              (e) => e.code,
              'code',
              OfflineSyncFailureCode.integrityViolation,
            ),
          );
        },
      );
    });
  });
}

ClockDriftException _drift(ClockDriftKind kind) {
  final wallTime = DateTime.utc(2026, 9, 23);
  return ClockDriftException(
    wallTime.add(Hlc.defaultMaxDrift + const Duration(milliseconds: 1)),
    wallTime,
    Hlc.defaultMaxDrift,
    kind: kind,
  );
}

/// An engine whose sync stream sends one event and then fails with [_error].
class _FailingEngine implements OfflineSyncEngine {
  _FailingEngine(this._error);

  final Object _error;

  @override
  Stream<OfflineSyncStreamEvent> sync(
    DatabaseSession session, {
    required UuidValue userId,
    required Stream<OfflineSyncStreamEvent> inbound,
    required OfflineSyncPeerMode mode,
    bool once = false,
    OfflineSyncOnMergeSuccess? onMergeSuccess,
  }) async* {
    yield OfflineSyncEndOfBatch();
    yield* Stream<OfflineSyncStreamEvent>.error(_error);
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
