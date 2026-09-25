import 'package:serverpod_offline_sync_client/serverpod_offline_sync_client.dart';

/// Records the batches one side sends: the changes before each end-of-batch
/// frame and the frame itself.
final class BatchRecorder {
  final List<({List<CrdtMergeChange> changes, OfflineSyncEndOfBatch end})>
  _batches = [];
  var _current = <CrdtMergeChange>[];

  /// Records [event] and returns it unchanged.
  OfflineSyncStreamEvent record(OfflineSyncStreamEvent event) {
    switch (event) {
      case OfflineSyncMergeChunk(:final changes):
        _current.addAll(changes);
      case final OfflineSyncEndOfBatch end:
        _batches.add((changes: _current, end: end));
        _current = [];
      default:
        break;
    }
    return event;
  }

  /// Every end-of-batch frame.
  List<OfflineSyncEndOfBatch> get endOfBatches => [
    for (final batch in _batches) batch.end,
  ];

  /// The batches that carried changes.
  List<List<CrdtMergeChange>> get dataBatches => [
    for (final batch in _batches)
      if (batch.changes.isNotEmpty) batch.changes,
  ];

  /// The size of each batch that carried changes.
  List<int> get dataSizes => [for (final batch in dataBatches) batch.length];

  /// The `hasMore` of each batch that carried changes.
  List<bool?> get dataHasMore => [
    for (final batch in _batches)
      if (batch.changes.isNotEmpty) batch.end.hasMore,
  ];

  /// Whether every end-of-batch frame carried the flag.
  bool get everyHasMoreSet =>
      _batches.every((batch) => batch.end.hasMore != null);
}
