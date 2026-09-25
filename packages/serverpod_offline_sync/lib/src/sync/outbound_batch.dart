import 'dart:async';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../generated/protocol.dart';
import '../hlc/hlc.dart';

/// Measures the payload of one outbound change in the unit of
/// [OfflineSyncBatchBudget.maxPayloadChars] (fork, unibook#14251).
///
/// Called with the change as the peer is about to send it: an insert carries
/// the whole row, an update one column, a delete no value. Must not return a
/// negative number.
typedef OfflineSyncChangePayloadMeasure = int Function(CrdtMergeChange change);

/// How much one outbound batch may carry: the changes a peer sends in one
/// round, closed by its [OfflineSyncEndOfBatch] (fork, unibook#14251).
///
/// The receiving peer holds a whole batch in memory before it merges it, so a
/// round that sends every pending change at once, as upstream does, can exceed
/// what the receiver accepts: a device back after a long time offline, or a
/// server sending a new device everything. With a budget, the peer ends its
/// batch before the next change would take it over a limit and sends the rest
/// in the next rounds of the same session. A `once` session runs those rounds
/// before it closes ([OfflineSyncEndOfBatch.hasMore]); a continuous session
/// sends one batch per round.
///
/// A batch is always a prefix of the pending changes in HLC order, cut where
/// the peer may resume from its checkpoints without skipping a change: never
/// between changes with the same HLC, and never between a row's insert and a
/// change of that row stamped before it (a receiver that does not have the row
/// drops such a change). Never either between a change that writes a foreign
/// key and the pending insert of the parent it names when that insert is
/// stamped after it, as a restore stamps it (the receiver checks foreign keys
/// when it commits a batch, and would fail the same batch every session). It
/// also avoids cutting a delete from the cascade deletes it caused, and one
/// write's changes of a row from each other (the receiver would show the row
/// half written until the next batch), unless that group alone exceeds the
/// budget.
///
/// A change that alone exceeds the budget is sent in a batch of its own: the
/// receiver decides, the sender does not stop. Limits are inclusive: a batch
/// exactly at a limit fits.
///
/// [unlimited], the default everywhere, keeps the upstream behavior: every
/// pending change in one batch, in the upstream order.
final class OfflineSyncBatchBudget {
  /// Limits a batch to [maxChanges] changes and to [maxPayloadChars] of
  /// payload as [measurePayload] measures it. Either may be null (no limit on
  /// that axis), not both: use [unlimited].
  ///
  /// Throws [ArgumentError] for a limit below 1, for no limit at all, and for
  /// [maxPayloadChars] without [measurePayload].
  factory OfflineSyncBatchBudget({
    int? maxChanges,
    int? maxPayloadChars,
    OfflineSyncChangePayloadMeasure? measurePayload,
  }) {
    if (maxChanges != null && maxChanges < 1) {
      throw ArgumentError.value(maxChanges, 'maxChanges', 'Must be >= 1');
    }
    if (maxPayloadChars != null && maxPayloadChars < 1) {
      throw ArgumentError.value(maxPayloadChars, 'maxPayloadChars', 'Must be >= 1');
    }
    if (maxChanges == null && maxPayloadChars == null) {
      throw ArgumentError(
        'A budget needs maxChanges or maxPayloadChars. Use '
        'OfflineSyncBatchBudget.unlimited for no limit.',
      );
    }
    if (maxPayloadChars != null && measurePayload == null) {
      throw ArgumentError.notNull('measurePayload');
    }
    return OfflineSyncBatchBudget._(
      maxChanges: maxChanges,
      maxPayloadChars: maxPayloadChars,
      measurePayload: measurePayload,
    );
  }

  const OfflineSyncBatchBudget._({
    this.maxChanges,
    this.maxPayloadChars,
    this.measurePayload,
  });

  /// No limit: one batch per round with every pending change, as upstream.
  static const OfflineSyncBatchBudget unlimited = OfflineSyncBatchBudget._();

  /// The most changes one batch carries, or null for no limit.
  final int? maxChanges;

  /// The most payload one batch carries, as [measurePayload] measures it, or
  /// null for no limit.
  final int? maxPayloadChars;

  /// Measures one change for [maxPayloadChars]. Null only without that limit.
  final OfflineSyncChangePayloadMeasure? measurePayload;

  /// Whether this budget sets no limit.
  bool get isUnlimited => maxChanges == null && maxPayloadChars == null;
}

/// A row of a synchronized table (fork, unibook#14251).
typedef OfflineSyncRowKey = ({String tableName, UuidValue rowId});

/// Rows a peer does not send, and rows it sends once more in full after it
/// stopped holding them back (fork, unibook#14251).
///
/// Without it, a receiver that rejects one row (a value over its limit, a
/// table the device may not write) stops the whole account: the rejected
/// batch never merges, and every later session sends the same row first. An
/// isolated row is left out of every outbound batch, so the rest keeps
/// syncing.
///
/// ⚠️ **The checkpoints pass an isolated row.** Once a later change of the same
/// node is merged, the receiver's checkpoint is past the isolated row's
/// changes and no collection sends them again. Only [releasedRows] brings them
/// back: a released row is sent in full, from its first change, whatever the
/// checkpoints. So both sets are **durable state the implementation owns**:
/// keep them across restarts (next to the database file, for example). A row
/// that leaves [isolatedRows] without entering [releasedRows] is never sent
/// again.
///
/// The engine reads both sets at the start of every collection and never
/// changes them. A row in both counts as isolated. The unsent row count
/// (`OfflineSyncDatabase.unsentRowCount`) counts every row of both sets that
/// exists locally, so a sign-out check does not drop them. Its watch counts
/// again on commits and after [onReleasedRowsConfirmed] returns; refresh it
/// after changing the sets any other way.
///
/// Deleting an isolated row does not clear what the receiver rejected: a
/// delete only writes a tombstone and keeps the hidden domain row, whose
/// values a released row's insert carries. Rewrite the rejected column within
/// the receiver's limits first, then delete, then release.
abstract interface class OfflineSyncRowIsolation {
  /// The rows this peer does not send.
  Set<OfflineSyncRowKey> get isolatedRows;

  /// The rows this peer sends in full once more: every change it holds for
  /// them, including those its checkpoints are past.
  ///
  /// A session sends each of them once. They stay here, and later sessions
  /// send them again, until [onReleasedRowsConfirmed] reports them.
  Set<OfflineSyncRowKey> get releasedRows;

  /// Called after a `once` session that sent [rows] from [releasedRows] ended
  /// with the peer's close, which comes only after the peer merged every batch.
  /// Remove them from [releasedRows] here.
  ///
  /// A continuous session never confirms. A session that fails, or that closed
  /// before it sent everything (a peer built before
  /// [OfflineSyncEndOfBatch.hasMore]), confirms nothing.
  FutureOr<void> onReleasedRowsConfirmed(Set<OfflineSyncRowKey> rows);
}

/// The kind of an outbound change, in the order changes with the same HLC are
/// sent.
@internal
enum OutboundChangeKind {
  /// A [CrdtMergeInsert].
  insert,

  /// A [CrdtMergeUpdate].
  update,

  /// A [CrdtMergeDelete].
  delete,
}

/// What the outbound batch planner needs to know about one pending change.
@internal
typedef OutboundChangeRef = ({
  Hlc hlc,
  OutboundChangeKind kind,
  String tableName,
  UuidValue rowId,
  String? columnName,
  CrdtDataDeletedReason? deleteReason,
});

/// Two changes the receiver must get in one batch when `prerequisite` sorts
/// after `dependent`: `dependent` names the row `prerequisite` creates. Both
/// are indices into the planned list.
///
/// The engine gives one for each foreign key a pending change writes (a
/// child's insert, or an update of its foreign key column) that names a row
/// whose pending insert sorts after the change: a receiver merges one batch
/// with deferred foreign keys, so a child whose parent is neither in that
/// batch nor already in its database fails the whole batch.
@internal
typedef OutboundDependency = ({int dependent, int prerequisite});

/// Changes that travel together when the budget allows it: the batch never
/// ends inside a unit that fits.
@internal
final class OutboundUnit {
  /// Creates a unit of [groups].
  OutboundUnit(this.groups);

  /// The unit's changes as indices into the planned list, in send order.
  ///
  /// A unit that alone exceeds the budget is sent group by group, and the
  /// batch still never ends inside a group that fits. A group that alone
  /// exceeds it is sent part by part. A part (a list of indices) is never
  /// split.
  final List<List<List<int>>> groups;

  /// The unit's parts, in send order, across its groups.
  List<List<int>> get parts => [for (final group in groups) ...group];

  /// Every index of the unit, in send order.
  Iterable<int> get indices => groups.expand((group) => group.expand((part) => part));

  /// The number of changes in the unit.
  int get length => indices.length;
}

/// Plans where a peer may end an outbound batch (fork, unibook#14251).
///
/// Returns the changes of [changes] as units in send order: HLC order, so that
/// every prefix of the units is a prefix of every node's changes and a
/// checkpoint that moves to the last change sent skips none. Changes with the
/// same HLC are ordered insert, update, delete, then by table, row and column.
///
/// A part (the smallest piece a batch ends between) keeps:
///
/// * changes with the same HLC together. The checkpoint query resumes after
///   the checkpoint (`>`), so a cut between two of them would skip the second.
/// * a row's insert with every change of that row sorted before it. A receiver
///   that does not have the row drops an update or delete that arrives before
///   the insert (it defers a delete only within one batch), and a delete of a
///   later generation can carry an older HLC than a concurrent re-insertion.

/// * each change of [dependencies] with its prerequisite sorted after it, and
///   every change in between. The receiver merges a batch in one transaction
///   whose foreign keys it checks at commit: a child's insert whose parent's
///   insert comes in a later batch fails that commit, and every retry builds
///   the same batch. A parent's insert sorts after its child's when the parent
///   was deleted and inserted again with its id after the child was written:
///   the restore stamps the insert anew. Each dependency adds one range; ranges
///   that overlap make one part, so a parent that names a grandparent inserted
///   after it joins the grandparent's part through its own dependency.
///
/// A unit also keeps together what one local write stamped, which the
/// recorder stamps as consecutive changes of one node: each HLC it issues is
/// the previous one's datetime with the next counter, until the wall clock
/// moves on. That shape, "stamped right after", is the only trace a write
/// leaves; a cut inside it is allowed but avoided:
///
/// * one write's changes of a row: an update stamps each changed column in
///   turn. Consecutive changes of a node to the same row, each stamped right
///   after the one before, stay together, so a receiver does not show the row
///   half written between two batches. They are also a group (below).
/// * a delete with the cascade deletes it caused: the deleted parents first,
///   then their cascade children. A run of consecutive delete tombstones of a
///   node (reason [CrdtDataDeletedReason.userDelete] or
///   [CrdtDataDeletedReason.userCascadeDelete]) that holds a cascade delete
///   stays together from its first tombstone to its last cascade delete. It
///   may hold unrelated deletes the node made just before, which adjacency
///   alone cannot tell from the parents.
///
/// A unit that alone exceeds the budget falls back to its groups: the batch
/// may end between two groups, never inside one that fits. In a delete run,
/// the group is its tail: the first cascade delete with the user deletes
/// stamped right before it in an unbroken chain (the parents of that delete,
/// and any delete the same write or one in the same millisecond made), to
/// the last cascade delete. The deletes before the tail may go in an earlier
/// batch. A chain the wall clock broke leaves some parents out of the tail;
/// then they may go one batch before their cascade, as any part may.
@internal
List<OutboundUnit> planOutboundUnits(
  List<OutboundChangeRef> changes, {
  Iterable<OutboundDependency> dependencies = const [],
}) {
  final order = List<int>.generate(changes.length, (index) => index)
    ..sort((left, right) => _compareOutbound(changes[left], changes[right]));
  final count = order.length;
  if (count == 0) return const [];

  // Cut "after position i" is forbidden while a range covers i. Each list is a
  // difference array over positions: hard for parts, grouped for groups,
  // soft for units. Every grouped range is also soft, so groups nest in units.
  final hard = List<int>.filled(count + 1, 0);
  final grouped = List<int>.filled(count + 1, 0);
  final soft = List<int>.filled(count + 1, 0);
  void forbid(List<int> delta, int from, int to) {
    if (to <= from) return;
    delta[from]++;
    delta[to]--;
  }

  // Same HLC (datetime, counter and node): never apart.
  for (var position = 0; position + 1 < count; position++) {
    if (changes[order[position]].hlc == changes[order[position + 1]].hlc) {
      forbid(hard, position, position + 1);
    }
  }

  // A row's insert with every change of that row sorted before it.
  final firstPositionByRow = <(String, UuidValue), int>{};
  final insertPositionByRow = <(String, UuidValue), int>{};
  for (var position = 0; position < count; position++) {
    final change = changes[order[position]];
    final row = (change.tableName, change.rowId);
    firstPositionByRow.putIfAbsent(row, () => position);
    if (change.kind == OutboundChangeKind.insert) {
      insertPositionByRow[row] = position;
    }
  }
  for (final MapEntry(key: row, value: insertPosition) in insertPositionByRow.entries) {
    forbid(hard, firstPositionByRow[row]!, insertPosition);
  }

  // A dependent change with its prerequisite sorted after it.
  if (dependencies.isNotEmpty) {
    final positionOf = List<int>.filled(count, 0);
    for (var position = 0; position < count; position++) {
      positionOf[order[position]] = position;
    }
    for (final (:dependent, :prerequisite) in dependencies) {
      forbid(hard, positionOf[dependent], positionOf[prerequisite]);
    }
  }

  final positionsByNode = <UuidValue, List<int>>{};
  for (var position = 0; position < count; position++) {
    positionsByNode
        .putIfAbsent(changes[order[position]].hlc.nodeId, () => [])
        .add(position);
  }
  for (final positions in positionsByNode.values) {
    OutboundChangeRef at(int index) => changes[order[positions[index]]];
    bool stampedRightAfter(int index) =>
        _isStampedRightAfter(at(index - 1).hlc, at(index).hlc);

    // One write's changes of a row.
    for (var index = 1; index < positions.length; index++) {
      final previous = at(index - 1);
      final change = at(index);
      if (previous.rowId == change.rowId &&
          previous.tableName == change.tableName &&
          stampedRightAfter(index)) {
        forbid(grouped, positions[index - 1], positions[index]);
        forbid(soft, positions[index - 1], positions[index]);
      }
    }

    // A run of delete tombstones with its cascade deletes, by index into
    // positions.
    int? runStart;
    int? firstCascade;
    int? lastCascade;
    void closeRun() {
      if (runStart != null && firstCascade != null && lastCascade != null) {
        var tailStart = firstCascade!;
        while (tailStart > runStart! && stampedRightAfter(tailStart)) {
          tailStart--;
        }
        forbid(grouped, positions[tailStart], positions[lastCascade!]);
        forbid(soft, positions[runStart!], positions[lastCascade!]);
      }
      runStart = null;
      firstCascade = null;
      lastCascade = null;
    }

    for (var index = 0; index < positions.length; index++) {
      final change = at(index);
      final reason = change.deleteReason;
      final inRun =
          change.kind == OutboundChangeKind.delete &&
          (reason == CrdtDataDeletedReason.userDelete ||
              reason == CrdtDataDeletedReason.userCascadeDelete);
      if (!inRun) {
        closeRun();
        continue;
      }
      runStart ??= index;
      if (reason == CrdtDataDeletedReason.userCascadeDelete) {
        firstCascade ??= index;
        lastCascade = index;
      }
    }
    closeRun();
  }

  final units = <OutboundUnit>[];
  var groups = <List<List<int>>>[];
  var parts = <List<int>>[];
  var part = <int>[];
  var hardDepth = 0;
  var groupedDepth = 0;
  var softDepth = 0;
  for (var position = 0; position < count; position++) {
    hardDepth += hard[position];
    groupedDepth += grouped[position];
    softDepth += soft[position];
    part.add(order[position]);
    final isLast = position + 1 == count;
    if (isLast || hardDepth == 0) {
      parts.add(part);
      part = <int>[];
    }
    if (isLast || (hardDepth == 0 && groupedDepth == 0)) {
      groups.add(parts);
      parts = <List<int>>[];
    }
    if (isLast || (hardDepth == 0 && softDepth == 0)) {
      units.add(OutboundUnit(groups));
      groups = <List<List<int>>>[];
    }
  }
  return units;
}

/// Whether [next] is the HLC a node issues right after [previous] within one
/// millisecond: the shape one local write leaves (see [planOutboundUnits]).
bool _isStampedRightAfter(Hlc previous, Hlc next) =>
    next.datetime.isAtSameMomentAs(previous.datetime) &&
    next.counter == previous.counter + 1;

/// The longest prefix of [units] an empty batch can take under the change
/// limit of [budget] (fork, unibook#14251): the first unit whatever its size
/// (a unit that alone exceeds the limit is sent in part), then each unit while
/// the total stays within [OfflineSyncBatchBudget.maxChanges]. Every unit
/// without that limit.
///
/// The payload limit may end the batch earlier: it needs the changes resolved.
@internal
List<OutboundUnit> takeUnitsWithinChangeLimit(
  List<OutboundUnit> units,
  OfflineSyncBatchBudget budget,
) {
  final maxChanges = budget.maxChanges;
  if (maxChanges == null) return units;
  var changes = 0;
  var taken = 0;
  for (final unit in units) {
    if (taken > 0 && changes + unit.length > maxChanges) break;
    changes += unit.length;
    taken++;
  }
  return units.sublist(0, taken);
}

int _compareOutbound(OutboundChangeRef left, OutboundChangeRef right) {
  final byHlc = left.hlc.compareTo(right.hlc);
  if (byHlc != 0) return byHlc;
  final byKind = left.kind.index - right.kind.index;
  if (byKind != 0) return byKind;
  final byTable = left.tableName.compareTo(right.tableName);
  if (byTable != 0) return byTable;
  final byRow = left.rowId.uuid.compareTo(right.rowId.uuid);
  if (byRow != 0) return byRow;
  return (left.columnName ?? '').compareTo(right.columnName ?? '');
}

/// Counts one outbound batch against an [OfflineSyncBatchBudget].
@internal
final class OutboundBatchMeter {
  /// Starts an empty batch under [budget].
  OutboundBatchMeter(this.budget);

  /// The budget this batch is counted against.
  final OfflineSyncBatchBudget budget;

  /// The changes counted so far.
  int get changes => _changes;
  var _changes = 0;

  /// The payload counted so far.
  int get payloadChars => _payloadChars;
  var _payloadChars = 0;

  /// Whether nothing has been counted yet.
  bool get isEmpty => _changes == 0;

  /// The payload of [change] as the budget measures it, 0 without a payload
  /// limit.
  int payloadOf(CrdtMergeChange change) {
    if (budget.maxPayloadChars == null) return 0;
    final chars = budget.measurePayload!(change);
    if (chars < 0) {
      throw StateError(
        'OfflineSyncBatchBudget.measurePayload returned $chars for a change '
        'of ${change.tableName}; a payload cannot be negative.',
      );
    }
    return chars;
  }

  /// Whether [changes] more changes fit on the change axis.
  bool fitsChanges(int changes) {
    final max = budget.maxChanges;
    return max == null || _changes + changes <= max;
  }

  /// Whether [changes] more changes with [payloadChars] of payload fit.
  bool fits({required int changes, required int payloadChars}) {
    final maxPayload = budget.maxPayloadChars;
    return fitsChanges(changes) &&
        (maxPayload == null || _payloadChars + payloadChars <= maxPayload);
  }

  /// Counts [changes] changes with [payloadChars] of payload.
  void add({required int changes, required int payloadChars}) {
    _changes += changes;
    _payloadChars += payloadChars;
  }
}
