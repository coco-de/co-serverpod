import 'dart:async';

/// Counts once per event of [triggers] with [count] and emits each count that
/// differs from the last one emitted.
///
/// Fork (unibook#14183): the pipeline behind
/// `OfflineSyncDatabase.watchUnsentRowCount`. Counts run one at a time, each
/// after the event that asked for it, so an older count never follows a newer
/// one. A failed count is emitted as an error and the stream goes on with the
/// next event; the error does not reset what counts as a change.
Stream<int> countOnEachTrigger(
  Stream<void> triggers,
  Future<int> Function() count,
) => triggers.asyncMap((_) => count()).distinct();

/// Emits every event of [source] and of [extra], and ends when [source] ends
/// (fork, unibook#14251).
///
/// Pausing the result pauses both, so a count that runs holds back the next
/// trigger as it did with [source] alone.
Stream<void> mergeTriggers(Stream<void> source, Stream<void> extra) {
  StreamSubscription<void>? sourceSubscription;
  StreamSubscription<void>? extraSubscription;
  late final StreamController<void> controller;
  controller = StreamController<void>(
    onListen: () {
      extraSubscription = extra.listen(controller.add);
      sourceSubscription = source.listen(
        controller.add,
        onError: controller.addError,
        onDone: () async {
          await extraSubscription?.cancel();
          await controller.close();
        },
      );
    },
    onPause: () {
      sourceSubscription?.pause();
      extraSubscription?.pause();
    },
    onResume: () {
      sourceSubscription?.resume();
      extraSubscription?.resume();
    },
    onCancel: () async {
      await extraSubscription?.cancel();
      await sourceSubscription?.cancel();
    },
  );
  return controller.stream;
}
