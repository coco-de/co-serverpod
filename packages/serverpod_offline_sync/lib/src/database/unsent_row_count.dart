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
