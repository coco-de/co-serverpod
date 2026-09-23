import 'dart:async';

import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

/// [OfflineSyncFailure.from] is the one place a sync error becomes an app
/// decision. The clock drift cases carry the risk: the same
/// [ClockDriftException] kind means the opposite on each side, and the server's
/// kinds reach the device only through [OfflineSyncRemoteException].
void main() {
  final wallTime = DateTime.utc(2026, 9, 23);
  final nodeId = UuidValue.withValidation('11111111-1111-4111-8111-111111111111');
  const overLimit = Duration(hours: 1, milliseconds: 1);

  ClockDriftException localDrift(ClockDriftKind kind) => ClockDriftException(
    wallTime.add(overLimit),
    wallTime,
    Hlc.defaultMaxDrift,
    kind: kind,
    remoteNodeId: kind == ClockDriftKind.remoteAhead ? nodeId : null,
  );

  OfflineSyncRemoteException remote(OfflineSyncFailureCode code) =>
      OfflineSyncRemoteException(
        code: code,
        message: 'server',
        driftMs: 3600001,
        maxDriftMs: 3600000,
      );

  final violation = OfflineSyncIntegrityViolation(
    type: OfflineSyncViolationType.unauthorizedWrite,
    domainTableName: 'note',
    uuidRowId: nodeId,
    incomingSpaceUuid: nodeId,
    operation: OfflineSyncViolationOperation.mergeInsert,
    firstSeenAt: wallTime,
    lastSeenAt: wallTime,
    occurrences: 1,
  );

  final cases = <String, (Object, OfflineSyncFailureReason)>{
    'a server clockDrift': (
      remote(OfflineSyncFailureCode.clockDrift),
      OfflineSyncFailureReason.clockDrift,
    ),
    'a server serverClockDrift': (
      remote(OfflineSyncFailureCode.serverClockDrift),
      OfflineSyncFailureReason.serverClockDrift,
    ),
    'a server hlcOverflow': (
      remote(OfflineSyncFailureCode.hlcOverflow),
      OfflineSyncFailureReason.hlcOverflow,
    ),
    'a server duplicateNode': (
      remote(OfflineSyncFailureCode.duplicateNode),
      OfflineSyncFailureReason.duplicateNode,
    ),
    'a server integrityViolation': (
      remote(OfflineSyncFailureCode.integrityViolation),
      OfflineSyncFailureReason.integrityViolation,
    ),
    'a server code this build does not know': (
      remote(OfflineSyncFailureCode.unknown),
      OfflineSyncFailureReason.unknown,
    ),
    'a local remoteAhead drift (this device is behind)': (
      localDrift(ClockDriftKind.remoteAhead),
      OfflineSyncFailureReason.clockDriftBehind,
    ),
    'a local localAhead drift (this clock moved back)': (
      localDrift(ClockDriftKind.localAhead),
      OfflineSyncFailureReason.clockRollback,
    ),
    'a local counter overflow': (
      OverflowException(0x10000),
      OfflineSyncFailureReason.hlcOverflow,
    ),
    'a local duplicate node': (
      DuplicateNodeException(nodeId),
      OfflineSyncFailureReason.duplicateNode,
    ),
    'a local integrity violation': (
      OfflineSyncIntegrityViolationException(violation),
      OfflineSyncFailureReason.integrityViolation,
    ),
    'a schema hash mismatch': (
      const OfflineSyncTablesHashMismatchException(received: 'a', expected: 'b'),
      OfflineSyncFailureReason.schemaMismatch,
    ),
    'a stream refused as unauthenticated': (
      OpenMethodStreamException(
        OpenMethodStreamResponseType.authenticationFailed,
      ),
      OfflineSyncFailureReason.authenticationFailed,
    ),
    'a stream refused as unauthorized': (
      OpenMethodStreamException(
        OpenMethodStreamResponseType.authorizationDeclined,
      ),
      OfflineSyncFailureReason.authorizationDeclined,
    ),
    'a stream refused for a missing endpoint': (
      OpenMethodStreamException(OpenMethodStreamResponseType.endpointNotFound),
      OfflineSyncFailureReason.incompatibleEndpoint,
    ),
    'a stream refused for invalid arguments': (
      OpenMethodStreamException(OpenMethodStreamResponseType.invalidArguments),
      OfflineSyncFailureReason.incompatibleEndpoint,
    ),
    'a closed method stream': (
      const ConnectionClosedException(),
      OfflineSyncFailureReason.transport,
    ),
    'a failed WebSocket connect': (
      const WebSocketConnectException('refused'),
      OfflineSyncFailureReason.transport,
    ),
    'a stream closed mid-handshake': (
      const OfflineSyncStreamClosedException(phase: 'OfflineSyncConnect'),
      OfflineSyncFailureReason.transport,
    ),
    'a timeout': (TimeoutException('slow'), OfflineSyncFailureReason.transport),
    'an unrelated error': (StateError('boom'), OfflineSyncFailureReason.unknown),
  };

  group('Given a sync error,', () {
    for (final MapEntry(key: name, value: (error, reason)) in cases.entries) {
      test('when classifying $name, then the code is ${reason.name}.', () {
        final failure = OfflineSyncFailure.from(error);

        expect(failure.code, reason);
        expect(failure.error, same(error));
      });
    }
  });

  group('Given the classified reasons,', () {
    test(
      'when asking which need the device clock checked, '
      'then only the three device clock reasons do.',
      () {
        expect(
          {
            for (final reason in OfflineSyncFailureReason.values)
              if (reason.isClockDrift) reason,
          },
          {
            OfflineSyncFailureReason.clockDrift,
            OfflineSyncFailureReason.clockDriftBehind,
            OfflineSyncFailureReason.clockRollback,
          },
        );
      },
    );

    test(
      'when asking which are permanent, '
      'then only a duplicate node, an integrity violation and a refused '
      'stream are.',
      () {
        expect(
          {
            for (final reason in OfflineSyncFailureReason.values)
              if (reason.isPermanent) reason,
          },
          {
            OfflineSyncFailureReason.duplicateNode,
            OfflineSyncFailureReason.integrityViolation,
            OfflineSyncFailureReason.authenticationFailed,
            OfflineSyncFailureReason.authorizationDeclined,
            OfflineSyncFailureReason.incompatibleEndpoint,
          },
        );
      },
    );
  });

  group('Given a clock drift failure,', () {
    test('when it came from the server, then its drift is carried over.', () {
      final failure = OfflineSyncFailure.from(
        remote(OfflineSyncFailureCode.clockDrift),
      );

      expect(failure.drift, overLimit);
      expect(failure.maxDrift, Hlc.defaultMaxDrift);
      expect(failure.isClockDrift, isTrue);
      expect(failure.isPermanent, isFalse);
    });

    test('when it came from this device, then its drift is carried over.', () {
      final failure = OfflineSyncFailure.from(localDrift(ClockDriftKind.localAhead));

      expect(failure.drift, overLimit);
      expect(failure.maxDrift, Hlc.defaultMaxDrift);
    });
  });

  group('Given the method stream exception message the server sends,', () {
    test(
      'when the generated client protocol decodes it, '
      'then the failure keeps the server code.',
      () {
        final message = MethodStreamSerializableException.buildMessage(
          endpoint: 'serverpod_offline_sync.offlineSync',
          method: 'sync',
          connectionId: nodeId,
          object: remote(OfflineSyncFailureCode.clockDrift),
          serializationManager: Protocol(),
        );

        final decoded = WebSocketMessage.fromJsonString(message, Protocol());
        final exception = (decoded as MethodStreamSerializableException).exception;

        expect(
          OfflineSyncFailure.from(exception).code,
          OfflineSyncFailureReason.clockDrift,
        );
      },
    );

    // Without `default: unknown` on the wire enum, a code this build does not
    // know throws while the message is parsed. Serverpod's client then closes
    // the whole WebSocket connection, not just this stream.
    test(
      'when it carries a code this build does not know, '
      'then it still decodes and the failure is unknown.',
      () {
        final message = MethodStreamSerializableException.buildMessage(
          endpoint: 'serverpod_offline_sync.offlineSync',
          method: 'sync',
          connectionId: nodeId,
          object: remote(OfflineSyncFailureCode.clockDrift),
          serializationManager: Protocol(),
        );
        const sent = '"code":"clockDrift"';
        expect(message, contains(sent));
        final fromNewerServer = message.replaceFirst(
          sent,
          '"code":"aCodeAddedLater"',
        );

        final decoded = WebSocketMessage.fromJsonString(
          fromNewerServer,
          Protocol(),
        );
        final exception =
            (decoded as MethodStreamSerializableException).exception
                as OfflineSyncRemoteException;

        expect(exception.code, OfflineSyncFailureCode.unknown);
        expect(exception.driftMs, 3600001);
        expect(
          OfflineSyncFailure.from(exception).code,
          OfflineSyncFailureReason.unknown,
        );
      },
    );
  });
}
