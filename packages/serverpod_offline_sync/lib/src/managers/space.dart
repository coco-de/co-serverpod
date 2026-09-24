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
///   one the space already holds. Of the spaces on one node, the last keeps it.
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
    final cached = _instances[uuidSpaceId];
    if (cached != null) return cached;
    if (!_databaseContext.assignsNodePerSpace) {
      return _instances[uuidSpaceId] = await _session.db.transaction(
        (transaction) => _getOrCreateOnSharedNode(uuidSpaceId, transaction),
      );
    }
    final space = await _session.db.transaction(
      (transaction) => _getOrCreateWithOwnNode(uuidSpaceId, transaction),
    );
    // Committed, so the space holds its node alone from now on.
    _databaseContext.rememberSpaceOwnsNode(space.id!, space.currentNodeId!);
    return _instances[uuidSpaceId] = space;
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
      return _attachOwnNode(space, const Uuid().v7obj(), null, null, transaction);
    }
    if (await _ownsItsNode(space, transaction, known: true)) {
      await _ensureSpaceNode(space.id!, space.currentNodeId!, transaction);
      return space;
    }

    // Lock the space's row so no other session moves the space meanwhile.
    // FOR NO KEY UPDATE, not FOR UPDATE: inserting a row that references the
    // space takes FOR KEY SHARE on it, and a merge into the space doing so
    // while it holds the shared node (a server of the version before, during a
    // deploy) would otherwise wait on this lock while this one waits on the
    // node.
    final spaceId = space.id!;
    await OfflineSyncSpace.db.lockRows(
      _session,
      where: (t) => t.id.equals(spaceId),
      lockMode: LockMode.forNoKeyUpdate,
      transaction: transaction,
    );
    space = (await _findSpace(uuidSpaceId, transaction))!;

    // Read before locking the node, so the scan does not hold up the merges
    // of the other spaces on it. Nothing lands unseen in between: every write
    // that stamps the space under the node holds the node's row lock and
    // leaves the node's clock at or above its stamps, and the clock is read
    // under the lock below.
    final uuidNodeId = const Uuid().v7obj();
    final storedHlc = await _latestStoredHlc(spaceId, uuidNodeId, transaction);
    final currentNodeId = space.currentNodeId;
    if (currentNodeId == null) {
      return _attachOwnNode(space, uuidNodeId, storedHlc, null, transaction);
    }

    // Lock the node the space would leave as well: an in-flight write on it
    // may still stamp this space, and a new clock has to start after it.
    final node = await CrdtNode.db.findById(
      _session,
      currentNodeId,
      transaction: transaction,
      lockMode: LockMode.forUpdate,
    );
    if (node == null) throw StateError('CRDT node $currentNodeId is missing.');
    space = space.copyWith(currentNode: node);

    // Look again under the node's lock. Another session may have attached a
    // node of its own to this space meanwhile, or moved the other spaces off
    // this node: then the node stays with this space, and no two sessions give
    // one space two nodes or leave a node without a space.
    if (await _ownsItsNode(space, transaction)) {
      await _ensureSpaceNode(spaceId, currentNodeId, transaction);
      return space;
    }
    return _attachOwnNode(space, uuidNodeId, storedHlc, node, transaction);
  }

  /// Whether [space] has a node and no other space points at that node.
  ///
  /// With [known], a pair [OfflineSyncDatabaseContext.knowsSpaceOwnsNode]
  /// holds skips the query, which scans `offline_sync_spaces`.
  Future<bool> _ownsItsNode(
    OfflineSyncSpace space,
    Transaction transaction, {
    bool known = false,
  }) async {
    final nodeId = space.currentNodeId;
    if (nodeId == null || space.currentNode == null) return false;
    if (known && _databaseContext.knowsSpaceOwnsNode(space.id!, nodeId)) {
      return true;
    }
    final sharing = await OfflineSyncSpace.db.findFirstRow(
      _session,
      where: (t) => t.currentNodeId.equals(nodeId) & t.id.notEquals(space.id),
      transaction: transaction,
    );
    return sharing == null;
  }

  /// Attaches a new node [uuidNodeId] to [space], replacing [sharedNode] when
  /// given.
  ///
  /// The new clock starts at the later of [sharedNode]'s clock and [storedHlc],
  /// the latest timestamp stored in the space, never at the wall clock. A
  /// device of this space may have pushed a timestamp ahead of the wall clock
  /// that the shared clock took in. Starting lower would let the next server
  /// write in the space take a smaller timestamp and lose LWW to it, although
  /// it came later. This mirrors [_preserveLatestCurrentNodeHlc], which moves a
  /// device's space the other way, onto the shared node.
  Future<OfflineSyncSpace> _attachOwnNode(
    OfflineSyncSpace space,
    UuidValue uuidNodeId,
    Hlc? storedHlc,
    CrdtNode? sharedNode,
    Transaction transaction,
  ) async {
    final sharedHlc = sharedNode?.lastHlc?.copyWith(nodeId: uuidNodeId);
    final node = await CrdtNode.db.insertRow(
      _session,
      CrdtNode(
        uuidNodeId: uuidNodeId,
        lastHlc: sharedHlc?.maxBetween(storedHlc) ?? storedHlc,
      ),
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
