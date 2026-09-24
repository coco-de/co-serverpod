import 'package:serverpod_database/serverpod_database.dart';
import 'package:uuid/uuid.dart';

import '../database/recorder.dart';
import '../generated/protocol.dart';
import '../hlc/hlc.dart';

/// A manager for [OfflineSyncSpace] instances.
///
/// How a space gets its [CrdtNode] depends on the database, see
/// [OfflineSyncDatabaseContext.assignsNodePerSpace]:
///
/// * A device shares one node, the replica identity of the install, across all
///   its spaces. A space that points at another node is moved onto it, and the
///   node keeps the later of the two clocks.
/// * A server gives every space its own node (fork, unibook#14218). A space
///   that shares its node with another space, as every space did on a server
///   before, gets a new node. Its clock starts at the later of the shared
///   node's clock and the latest timestamp stored in the space: the reverse of
///   the device move, so neither move lets a node issue a timestamp at or below
///   one the space already holds.
class OfflineSyncSpaceManager {
  /// Creates a [OfflineSyncSpaceManager] bound to a database session.
  ///
  /// [context] decides whether spaces share a node, see
  /// [OfflineSyncDatabaseContext.assignsNodePerSpace].
  OfflineSyncSpaceManager(
    this._session, {
    required OfflineSyncDatabaseContext context,
  }) : _databaseContext = context;

  final DatabaseSession _session;
  final OfflineSyncDatabaseContext _databaseContext;

  final Map<UuidValue, OfflineSyncSpace> _instances = {};

  /// On a device, the canonical [CrdtNode] every space shares.
  CrdtNode? _cachedCurrentNode;

  /// Returns the cached [OfflineSyncSpace] for the given space ID.
  OfflineSyncSpace getCached(UuidValue uuidSpaceId) =>
      _instances[uuidSpaceId] ??
      (throw StateError(
        'Space $uuidSpaceId not found in cache. '
        'Ensure OfflineSyncSpaceManager.getOrCreate() is called before getCached().',
      ));

  /// Clears the in-memory cache so state is reloaded from the store.
  void clearCache() {
    _instances.clear();
    _cachedCurrentNode = null;
  }

  /// Returns the [OfflineSyncSpace] for the given space ID.
  ///
  /// Will create a new [OfflineSyncSpace] if no space is found.
  Future<OfflineSyncSpace> getOrCreate(UuidValue uuidSpaceId) async {
    return _instances[uuidSpaceId] ??= await _session.db.transaction(
      (transaction) => _databaseContext.assignsNodePerSpace
          ? _getOrCreateWithOwnNode(uuidSpaceId, transaction)
          : _getOrCreateOnSharedNode(uuidSpaceId, transaction),
    );
  }

  Future<OfflineSyncSpace?> _findSpace(
    UuidValue uuidSpaceId,
    Transaction transaction,
  ) => OfflineSyncSpace.db.findFirstRow(
    _session,
    where: (t) => t.uuidSpaceId.equals(uuidSpaceId),
    include: OfflineSyncSpace.include(currentNode: CrdtNode.include()),
    transaction: transaction,
  );

  Future<OfflineSyncSpace> _getOrCreateOnSharedNode(
    UuidValue uuidSpaceId,
    Transaction transaction,
  ) async {
    var space = await _findSpace(uuidSpaceId, transaction);

    space ??= await OfflineSyncSpace.db.insertRow(
      _session,
      OfflineSyncSpace(uuidSpaceId: uuidSpaceId),
      transaction: transaction,
    );

    var currentNode = await _getOrCreateCurrentNode(transaction);

    currentNode = await _preserveLatestCurrentNodeHlc(
      currentNode,
      space.currentNode,
      transaction,
    );
    if (space.currentNodeId != currentNode.id) {
      await OfflineSyncSpace.db.attachRow.currentNode(
        _session,
        space,
        currentNode,
        transaction: transaction,
      );
    }

    await _ensureSpaceNode(space.id!, currentNode.id!, transaction);

    _cachedCurrentNode = currentNode;

    return space.copyWith(
      currentNodeId: currentNode.id,
      currentNode: currentNode,
    );
  }

  /// A server space with a node of its own, attaching one when the space has
  /// none or shares its node with another space.
  Future<OfflineSyncSpace> _getOrCreateWithOwnNode(
    UuidValue uuidSpaceId,
    Transaction transaction,
  ) async {
    var space = await _findSpace(uuidSpaceId, transaction);
    if (space == null) {
      space = await OfflineSyncSpace.db.insertRow(
        _session,
        OfflineSyncSpace(uuidSpaceId: uuidSpaceId),
        transaction: transaction,
      );
      return _attachOwnNode(space, null, transaction);
    }
    if (await _ownsItsNode(space, transaction)) {
      await _ensureSpaceNode(space.id!, space.currentNodeId!, transaction);
      return space;
    }

    // Two sessions can get here for the same space at once. Lock its row and
    // look again, so the later one keeps the node the earlier one attached
    // instead of attaching a second one.
    final spaceId = space.id!;
    await OfflineSyncSpace.db.lockRows(
      _session,
      where: (t) => t.id.equals(spaceId),
      lockMode: LockMode.forUpdate,
      transaction: transaction,
    );
    space = (await _findSpace(uuidSpaceId, transaction))!;
    if (await _ownsItsNode(space, transaction)) {
      await _ensureSpaceNode(spaceId, space.currentNodeId!, transaction);
      return space;
    }

    final currentNodeId = space.currentNodeId;
    // Lock the node the space leaves as well: an in-flight write on it may
    // still stamp this space, and the new clock has to start after it.
    final sharedNode = currentNodeId == null
        ? null
        : await CrdtNode.db.findById(
            _session,
            currentNodeId,
            transaction: transaction,
            lockMode: LockMode.forUpdate,
          );
    return _attachOwnNode(space, sharedNode, transaction);
  }

  /// Whether [space] has a node and no other space points at that node.
  Future<bool> _ownsItsNode(
    OfflineSyncSpace space,
    Transaction transaction,
  ) async {
    final nodeId = space.currentNodeId;
    if (nodeId == null || space.currentNode == null) return false;
    final sharing = await OfflineSyncSpace.db.findFirstRow(
      _session,
      where: (t) => t.currentNodeId.equals(nodeId) & t.id.notEquals(space.id),
      transaction: transaction,
    );
    return sharing == null;
  }

  /// Attaches a new node to [space], replacing [sharedNode] when given.
  ///
  /// The new clock starts at the later of [sharedNode]'s clock and the latest
  /// timestamp stored in the space, never at the wall clock. A device of this
  /// space may have pushed a timestamp ahead of the wall clock that the shared
  /// clock took in. Starting lower would let the next server write in the
  /// space take a smaller timestamp and lose LWW to it, although it came
  /// later. This mirrors [_preserveLatestCurrentNodeHlc], which moves a
  /// device's space the other way, onto the shared node.
  Future<OfflineSyncSpace> _attachOwnNode(
    OfflineSyncSpace space,
    CrdtNode? sharedNode,
    Transaction transaction,
  ) async {
    final uuidNodeId = const Uuid().v7obj();
    final storedHlc = await _latestStoredHlc(space.id!, uuidNodeId, transaction);
    final initialHlc = sharedNode?.lastHlc
        ?.copyWith(nodeId: uuidNodeId)
        .maxBetween(storedHlc);

    final node = await CrdtNode.db.insertRow(
      _session,
      CrdtNode(uuidNodeId: uuidNodeId, lastHlc: initialHlc ?? storedHlc),
      transaction: transaction,
    );
    await OfflineSyncSpace.db.attachRow.currentNode(
      _session,
      space,
      node,
      transaction: transaction,
    );
    await _ensureSpaceNode(space.id!, node.id!, transaction);
    if (sharedNode != null) {
      await _retireSharedNode(space.id!, sharedNode, transaction);
    }

    return space.copyWith(currentNodeId: node.id, currentNode: node);
  }

  /// The latest timestamp stored in the space, under [uuidNodeId].
  ///
  /// Row, field and tombstone stamps are the timestamps a space holds. The
  /// attempted values carry none of their own.
  Future<Hlc?> _latestStoredHlc(
    int spaceId,
    UuidValue uuidNodeId,
    Transaction transaction,
  ) async {
    final stamps = <BaseHlc?>[
      await CrdtDataRow.db.findFirstRow(
        _session,
        where: (t) => t.spaceId.equals(spaceId),
        orderByList: (t) => [t.hlcDatetime.desc(), t.hlcCounter.desc()],
        transaction: transaction,
      ),
      await CrdtDataField.db.findFirstRow(
        _session,
        where: (t) => t.row.spaceId.equals(spaceId),
        orderByList: (t) => [t.hlcDatetime.desc(), t.hlcCounter.desc()],
        transaction: transaction,
      ),
      await CrdtDataDeleted.db.findFirstRow(
        _session,
        where: (t) => t.row.spaceId.equals(spaceId),
        orderByList: (t) => [t.hlcDatetime.desc(), t.hlcCounter.desc()],
        transaction: transaction,
      ),
    ];
    Hlc? latest;
    for (final stamp in stamps.nonNulls) {
      latest = stamp.toHlcForNode(uuidNodeId).maxBetween(latest);
    }
    return latest;
  }

  /// Records that the space holds every change of [sharedNode] up to its
  /// clock.
  ///
  /// The server wrote those changes itself, so they are all in its database.
  /// Without the checkpoint, the server's next handshake for the space would
  /// report none of them, and each device would send all of them back once.
  Future<void> _retireSharedNode(
    int spaceId,
    CrdtNode sharedNode,
    Transaction transaction,
  ) async {
    final lastHlc = sharedNode.lastHlc;
    if (lastHlc == null) return;
    final nodeId = sharedNode.id!;
    final spaceNode = await OfflineSyncSpaceNode.db.findFirstRow(
      _session,
      where: (t) => t.spaceId.equals(spaceId) & t.nodeId.equals(nodeId),
      transaction: transaction,
    );
    if (spaceNode == null) {
      await OfflineSyncSpaceNode.db.insertRow(
        _session,
        OfflineSyncSpaceNode(
          spaceId: spaceId,
          nodeId: nodeId,
          lastReceivedHlc: lastHlc,
        ),
        transaction: transaction,
      );
      return;
    }
    final received = spaceNode.lastReceivedHlc;
    if (received != null && received >= lastHlc) return;
    await OfflineSyncSpaceNode.db.updateRow(
      _session,
      spaceNode.copyWith(lastReceivedHlc: lastHlc),
      columns: (t) => [t.lastReceivedHlc],
      transaction: transaction,
    );
  }

  Future<CrdtNode> _getOrCreateCurrentNode(Transaction transaction) async {
    final cachedId = _cachedCurrentNode?.id;
    if (cachedId != null) {
      final node = await CrdtNode.db.findById(
        _session,
        cachedId,
        transaction: transaction,
      );
      if (node != null) return node;
      _cachedCurrentNode = null;
    }

    final existingSpace = await OfflineSyncSpace.db.findFirstRow(
      _session,
      where: (t) => t.currentNodeId.notEquals(null),
      orderBy: (t) => t.id,
      include: OfflineSyncSpace.include(currentNode: CrdtNode.include()),
      transaction: transaction,
    );

    final existingNode = existingSpace?.currentNode;
    if (existingNode != null) {
      return _cachedCurrentNode = existingNode;
    }

    return _cachedCurrentNode = await CrdtNode.db.insertRow(
      _session,
      CrdtNode(),
      transaction: transaction,
    );
  }

  Future<CrdtNode> _preserveLatestCurrentNodeHlc(
    CrdtNode currentNode,
    CrdtNode? spaceCurrentNode,
    Transaction transaction,
  ) async {
    final spaceLastHlc = spaceCurrentNode?.lastHlc;
    if (spaceLastHlc == null || spaceCurrentNode?.id == currentNode.id) {
      return currentNode;
    }

    final currentLastHlc = currentNode.lastHlc;
    if (currentLastHlc != null && currentLastHlc >= spaceLastHlc) {
      return currentNode;
    }

    final updatedNode = currentNode.copyWith(
      lastHlc: spaceLastHlc.copyWith(nodeId: currentNode.uuidNodeId),
    );
    await CrdtNode.db.updateRow(
      _session,
      updatedNode,
      columns: (t) => [t.lastHlc],
      transaction: transaction,
    );
    return updatedNode;
  }

  Future<void> _ensureSpaceNode(
    int spaceId,
    int nodeId,
    Transaction transaction,
  ) async {
    await OfflineSyncSpaceNode.db.insert(
      _session,
      [OfflineSyncSpaceNode(spaceId: spaceId, nodeId: nodeId)],
      transaction: transaction,
      ignoreConflicts: true,
    );
  }
}
