import 'dart:async';

import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';
import 'package:test/test.dart';

/// Syncs through [server] acting as the authoritative peer. With [wire], the
/// server stream maps its failures the way the server module facade does.
/// Every change the device sends is appended to [sent]. With [rewrite], each
/// change the device sends reaches the server as [rewrite] returns it.
///
/// With [holdServerDataUntil], the server runs without back-pressure from
/// the device, as over a WebSocket, and the device receives nothing from the
/// server's first merge chunk on until the returned future completes.
///
/// [mapServerStream] is called once per opened session with the server stream
/// the device is about to read, and the device reads what it returns.
///
/// [mapDeviceEvent] is called with every event the device sends, before
/// [sent] and [rewrite], and the server reads what it returns.
///
/// [userId] is the user the server syncs with. Leave it out for a [server]
/// opened with a persistent user; pass it for one opened without, which holds
/// many users like the Serverpod server does.
OfflineSyncClient peerOf(
  OfflineSyncDatabaseSession server, {
  UuidValue? userId,
  bool wire = false,
  List<CrdtMergeChange>? sent,
  CrdtMergeChange Function(CrdtMergeChange change)? rewrite,
  Future<void> Function()? holdServerDataUntil,
  Stream<OfflineSyncStreamEvent> Function(
    Stream<OfflineSyncStreamEvent> stream,
  )?
  mapServerStream,
  OfflineSyncStreamEvent Function(OfflineSyncStreamEvent event)? mapDeviceEvent,
}) {
  return OfflineSyncClient(({required changes, required once}) {
    final inbound = changes.map((deviceEvent) {
      final event = mapDeviceEvent == null
          ? deviceEvent
          : mapDeviceEvent(deviceEvent);
      if (event is! OfflineSyncMergeChunk) return event;
      sent?.addAll(event.changes);
      if (rewrite == null) return event;
      return OfflineSyncMergeChunk(
        changes: event.changes.map(rewrite).toList(),
      );
    });
    var stream = server.db.sync(
      userId: userId,
      inbound: inbound,
      once: once,
      mode: OfflineSyncPeerMode.authoritative,
    );
    if (wire) stream = stream.transform(offlineSyncWireErrors());
    if (holdServerDataUntil != null) {
      stream = _holdDataUntil(stream, holdServerDataUntil);
    }
    return mapServerStream == null ? stream : mapServerStream(stream);
  });
}

/// Forwards [source] without back-pressure on it, holding back every event
/// from the first [OfflineSyncMergeChunk] on until [release] completes.
///
/// Cancelling the returned stream cancels [source] without waiting for it:
/// the device's teardown must not inherit the server's own failure.
Stream<OfflineSyncStreamEvent> _holdDataUntil(
  Stream<OfflineSyncStreamEvent> source,
  Future<void> Function() release,
) {
  final controller = StreamController<OfflineSyncStreamEvent>();
  final held = <void Function()>[];
  var holding = false;
  var released = false;
  StreamSubscription<OfflineSyncStreamEvent>? subscription;

  void deliver(void Function() emit) => holding ? held.add(emit) : emit();

  controller
    ..onListen = () {
      subscription = source.listen(
        (event) {
          if (event is OfflineSyncMergeChunk && !holding && !released) {
            holding = true;
            unawaited(
              release().then((_) {
                released = true;
                holding = false;
                for (final emit in held) {
                  emit();
                }
                held.clear();
              }),
            );
          }
          deliver(() => controller.add(event));
        },
        onError: (Object error, StackTrace stackTrace) {
          deliver(() => controller.addError(error, stackTrace));
        },
        onDone: () => deliver(() => unawaited(controller.close())),
      );
    }
    ..onCancel = () {
      subscription?.cancel().ignore();
    };
  return controller.stream;
}

/// The error [future] completes with, or null when it succeeds.
Future<Object?> errorOf(Future<Object?> future) async {
  try {
    await future;
    return null;
  } on Object catch (error) {
    return error;
  }
}

/// Polls [condition] until it holds, failing after [timeout].
///
/// Uses the real clock, so it also works inside `withClock`.
Future<void> eventually(
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
