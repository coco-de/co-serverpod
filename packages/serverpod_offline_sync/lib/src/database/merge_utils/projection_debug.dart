import 'package:serverpod_serialization/serverpod_serialization.dart';

/// What a foreign key projection pass read, for tests (fork,
/// co-serverpod#41).
///
/// A merge pass loads the rows its seeds can reach through foreign keys and
/// unique claims. Only the seeds and the rows the pass writes read every
/// column the pass names; a row it merely reaches, such as a stored sibling of
/// the merged child, reads the foreign key and unique columns alone. That
/// narrowing does not change any merge result, so no result-based test can
/// tell it is gone: without it, a pass reads every sibling's payload again and
/// costs in proportion to them. These hooks let a test pin what was read and
/// time the passes apart from the rest of a sync.
///
/// Tests only: leave both null in production, where they cost one null check
/// per pass and per read.
abstract final class OfflineSyncProjectionDebug {
  /// Called for every domain read a merge pass makes while it walks its
  /// closure, with the rows read and the columns read for them.
  ///
  /// A pass that loads whole tables, such as a rebuild, does not call it.
  static void Function(
    String tableName,
    Set<UuidValue> rowIds,
    List<String> columnNames,
  )?
  onClosureColumnsRead;

  /// Called when a projection pass ends, with how long it took, how many rows
  /// it loaded, and whether it walked a closure from its seed rows, as a merge
  /// does, rather than loading whole tables, as a rebuild does.
  static void Function({
    required Duration elapsed,
    required int rowCount,
    required bool seeded,
  })?
  onPass;
}
