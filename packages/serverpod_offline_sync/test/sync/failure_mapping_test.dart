import 'dart:async';

import 'package:serverpod_offline_sync/serverpod_offline_sync.dart';
import 'package:serverpod_serialization/serverpod_serialization.dart';
import 'package:test/test.dart';

import '../hlc/hlc_fixtures.dart';

/// The server-side mapping from engine failures to the one exception type
/// Serverpod forwards over a method stream.
///
/// `serverpod_test` hands a streaming endpoint's error to the test unchanged,
/// so it cannot show that a plain exception is dropped on the wire. These
/// cases pin the structure instead: the result must be a
/// [SerializableException], and it must survive the exact message round trip
/// Serverpod uses for method stream exceptions.
void main() {
  final protocol = Protocol();
  final drift = Hlc.defaultMaxDrift + const Duration(milliseconds: 1);

  ClockDriftException clockDrift(ClockDriftKind kind) => ClockDriftException(
    hlcTime.add(drift),
    hlcTime,
    Hlc.defaultMaxDrift,
    kind: kind,
    remoteNodeId: kind == ClockDriftKind.remoteAhead ? hlcSecondNodeId : null,
  );

  final violation = OfflineSyncIntegrityViolation(
    type: OfflineSyncViolationType.unauthorizedWrite,
    domainTableName: 'note',
    uuidRowId: hlcNodeId,
    incomingSpaceUuid: hlcSecondNodeId,
    operation: OfflineSyncViolationOperation.mergeInsert,
    firstSeenAt: hlcTime,
    lastSeenAt: hlcTime,
    occurrences: 1,
  );

  final mapped = <String, (Object, OfflineSyncFailureCode)>{
    'a device timestamp ahead of the server clock': (
      clockDrift(ClockDriftKind.remoteAhead),
      OfflineSyncFailureCode.clockDrift,
    ),
    'a server timestamp blocked by the server clock': (
      clockDrift(ClockDriftKind.localAhead),
      OfflineSyncFailureCode.serverClockDrift,
    ),
    'a counter overflow': (
      OverflowException(0x10000),
      OfflineSyncFailureCode.hlcOverflow,
    ),
    'a duplicate node': (
      DuplicateNodeException(hlcNodeId),
      OfflineSyncFailureCode.duplicateNode,
    ),
    'an integrity violation': (
      OfflineSyncIntegrityViolationException(violation),
      OfflineSyncFailureCode.integrityViolation,
    ),
  };

  group('Given a sync failure the wire would drop,', () {
    for (final MapEntry(key: name, value: (error, code)) in mapped.entries) {
      test(
        'when mapping $name, then it becomes a serializable '
        'OfflineSyncRemoteException with code ${code.name}.',
        () {
          final wire = toOfflineSyncWireError(error);

          expect(wire, isA<SerializableException>());
          expect(
            wire,
            isA<OfflineSyncRemoteException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.message, 'message', error.toString()),
          );
        },
      );
    }

    test(
      'when mapping a clock drift, then the drift and limit travel in milliseconds.',
      () {
        final wire =
            toOfflineSyncWireError(clockDrift(ClockDriftKind.remoteAhead))
                as OfflineSyncRemoteException;

        expect(wire.driftMs, 3600001);
        expect(wire.maxDriftMs, 3600000);
      },
    );

    test('when mapping a non-drift failure, then no drift is attached.', () {
      final wire =
          toOfflineSyncWireError(OverflowException(0x10000))
              as OfflineSyncRemoteException;

      expect(wire.driftMs, isNull);
      expect(wire.maxDriftMs, isNull);
    });

    for (final MapEntry(key: name, value: (error, code)) in mapped.entries) {
      test(
        'when $name crosses the method stream message, '
        'then the device decodes the same type and code.',
        () {
          final message = MethodStreamSerializableException.buildMessage(
            endpoint: 'offlineSync',
            method: 'sync',
            connectionId: hlcNodeId,
            object: toOfflineSyncWireError(error),
            serializationManager: protocol,
          );

          final decoded = WebSocketMessage.fromJsonString(message, protocol);

          expect(
            decoded,
            isA<MethodStreamSerializableException>().having(
              (m) => m.exception,
              'exception',
              isA<OfflineSyncRemoteException>().having((e) => e.code, 'code', code),
            ),
          );
        },
      );
    }
  });

  group('Given the wire failure code,', () {
    // A newer server may send a code this build does not know. Throwing while
    // parsing would make Serverpod's client close the whole WebSocket
    // connection, so the enum decodes it as `unknown` (`default: unknown`).
    test(
      'when decoding a code this build does not know, then it is unknown.',
      () {
        expect(
          OfflineSyncFailureCode.fromJson('aCodeAddedLater'),
          OfflineSyncFailureCode.unknown,
        );
        expect(
          OfflineSyncRemoteException.fromJson({
            'code': 'aCodeAddedLater',
            'message': 'from a newer server',
          }).code,
          OfflineSyncFailureCode.unknown,
        );
      },
    );

    test('when mapping a failure, then the server never sends unknown.', () {
      expect(
        {
          for (final (error, _) in mapped.values)
            (toOfflineSyncWireError(error) as OfflineSyncRemoteException).code,
        },
        isNot(contains(OfflineSyncFailureCode.unknown)),
      );
    });
  });

  group('Given a failure the mapping does not own,', () {
    final passthrough = <String, Object>{
      'a schema hash mismatch': const OfflineSyncTablesHashMismatchException(
        received: 'a',
        expected: 'b',
      ),
      'a state error': StateError('boom'),
      'an existing remote exception': OfflineSyncRemoteException(
        code: OfflineSyncFailureCode.clockDrift,
        message: 'already mapped',
      ),
    };

    for (final MapEntry(key: name, value: error) in passthrough.entries) {
      test('when mapping $name, then the same object is returned.', () {
        expect(toOfflineSyncWireError(error), same(error));
      });
    }
  });

  group('Given a sync stream that fails,', () {
    test(
      'when transformed with offlineSyncWireErrors, '
      'then events pass, the error is mapped, and the stack trace is kept.',
      () async {
        final event = OfflineSyncEndOfBatch();
        final stackTrace = StackTrace.current;
        final controller = StreamController<OfflineSyncStreamEvent>();
        final collected = <Object>[];
        StackTrace? collectedStackTrace;

        final done = Completer<void>();
        controller.stream
            .transform(offlineSyncWireErrors())
            .listen(
              collected.add,
              onError: (Object error, StackTrace trace) {
                collected.add(error);
                collectedStackTrace = trace;
              },
              onDone: done.complete,
            );
        controller
          ..add(event)
          ..addError(clockDrift(ClockDriftKind.remoteAhead), stackTrace);
        await controller.close();
        await done.future;

        expect(collected, hasLength(2));
        expect(collected.first, same(event));
        expect(
          collected.last,
          isA<OfflineSyncRemoteException>().having(
            (e) => e.code,
            'code',
            OfflineSyncFailureCode.clockDrift,
          ),
        );
        expect(collectedStackTrace, same(stackTrace));
      },
    );
  });
}
