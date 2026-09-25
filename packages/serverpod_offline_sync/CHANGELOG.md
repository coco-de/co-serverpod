## Unreleased (co-serverpod fork)

- feat: A batch budget splits a round into several batches (unibook#14251).
  Upstream sends every pending change of a round in one batch, closed by one
  `OfflineSyncEndOfBatch`, and the receiver holds a batch in memory until it
  ends. A device back after a long time offline, or a server sending a new
  device everything, could exceed what the receiver accepts, and the same
  batch was built again every session. `OfflineSyncBatchBudget` (`maxChanges`,
  `maxPayloadChars` with `measurePayload`) ends the batch before the next
  change would exceed a limit; the rest goes in the next rounds. Limits are
  inclusive. `OfflineSyncEngine`, `OfflineSyncDatabase`,
  `OfflineSyncDatabaseSession` and `OfflineSyncDatabaseSession.wraps` take
  `batchBudget`; `OfflineSyncBatchBudget.unlimited`, the default, keeps the
  upstream collection and order.
  - Order and cuts (`planOutboundUnits`, `@internal`): with a budget the
    changes go in HLC order, so every batch is an HLC prefix and a checkpoint
    that moves to the last change sent skips none. Cut in the upstream order
    (inserts first), a batch would move the checkpoint past an update stamped
    before a later insert, and no round would send it again. A batch never
    ends between changes with the same HLC, nor between a row's insert and a
    change of that row stamped before it (a receiver drops an update or delete
    of a row it does not have, and defers a delete only within one batch).
    It also avoids two cuts, falling back to the rules above only when the
    group alone exceeds the budget. A node's run of delete tombstones that
    holds a cascade delete stays together from its first tombstone to its last
    cascade delete, so a parent delete and its cascade go in one batch. A
    node's consecutive changes of one row, each stamped right after the one
    before (same datetime, next counter: the shape one write leaves, such as
    an update of several columns), stay together, so a receiver does not show
    the row half written until the next batch. A unit that alone exceeds the
    budget goes group by group: in a delete run, the group starts at the user
    deletes stamped right before the first cascade delete (its parents), so
    unrelated deletes made just before may go one batch earlier while the
    parents and their cascade still go together when they fit. A part that
    alone exceeds the budget goes in a batch of its own: the receiver decides,
    the sender never stops.
  - Wire: one nullable field, `OfflineSyncEndOfBatch.hasMore`, which a peer
    built with it always sets. A `once` session runs another round when either
    peer set it, so both peers decide alike (`OfflineSyncCycleBatch
    .peerHasMore`). A peer built before the field sends none and ignores it; a
    peer that reads none closes, and the rest goes in its next session (one
    batch per session, no error). Regenerated
    `generated/sync/end_of_batch.dart`. A continuous session sends one batch
    per round and keeps its wait.
  - The server side is the same loop (authoritative mode); see the server
    package for `initializeOfflineSync(batchBudget:)`.
  - Cost: each round reads the pending metadata again (the upstream queries)
    and sorts it, so a backlog of N changes sent maxChanges at a time costs
    about N² / maxChanges. The change limit picks the units a batch can take
    before anything is resolved, and only their inserts' attempted values are
    read (`OfflineSyncEngine.debugOnAttemptedValuesRead` shows it). A unit that
    did not fit the payload limit had its domain values read for nothing; the
    next round reads them again. Measured on the SQLite fixture (a device
    sends N inserts in one `once` session, mean of two runs): unlimited
    1.2 s / 1.6 s / 3.3 s and `maxChanges: 100` 1.9 s / 5.3 s / 17.9 s for
    N = 2,000 / 4,000 / 8,000 (18.3 s before reading only the batch's
    attempted values). At N = 8,000 the 80 rounds spend about 6.5 s re-reading
    the sender's pending changes, 6.8 s in the receiving server's own
    per-round collection scan and 3 s in its per-batch merges. Reading pending
    changes by HLC keyset would cut the sender's part but must extend each
    read until every open hard and soft unit closes; it is left until
    production-scale numbers ask for it (unibook#14192 measures on staging).
    The default path is pinned by a SQLite test (upstream order, one batch);
    the PostgreSQL snapshot is covered by unibook's integration tests.
  - A change that writes a foreign key stays in one part with the pending
    insert of the parent it names when that insert sorts after it, and every
    change between them (`OutboundDependency`, `planOutboundUnits
    (dependencies:)`). Restoring a row (inserting it again with its id) stamps
    its insert anew, so a child's insert, or an update of a child's foreign
    key column, written before the restore sorts before the parent's insert.
    The receiver merges one batch in one transaction with deferred foreign
    keys: a batch that ended between them failed its commit with
    `DatabaseForeignKeyViolationException`, and the sender built the same
    first batch every session, stopping the account's sync for good. Before
    anything is resolved, the engine picks without reads the changes that may
    depend on a later insert (an insert, or a foreign key column update, whose
    parent table has a pending insert sorted after it), reads the foreign keys
    of those in the units the batch can take (one query per table for the
    domain columns, one for their attempted values: the value sent is the
    attempted one), plans again when a parent's insert it names sorts after
    it (one sorted before already goes in that batch or an earlier one, and
    plans nothing again), and repeats until the units hold no change not yet
    read, so a parent a dependency brings in brings its own restored parent
    too. Only keys to a parent's `id` are
    followed. Nothing is read without a limit (one batch). A part that alone
    exceeds the budget still goes whole in an empty batch; this one can span
    everything written between the child and the restore. A parent that is
    isolated is never sent, and its children still fail the receiver: isolate
    them too. `OfflineSyncEngine.debugOnForeignKeysRead` (`@visibleForTesting`)
    reports the reads.
  - Where the batch still splits a group that alone exceeds the budget, the
    receiver shows it half applied until the next batch: one write's changes
    of a row larger than `maxChanges`, or a delete run whose cascade group
    (from the first cascade's parents to the last cascade delete) holds
    several cascading deletes, where a later parent and its cascade may go in
    different batches.
  - The change limit is what lets a batch read only its own units: with a
    payload limit only (`maxChanges: null`), every round reads the attempted
    values and the foreign key candidates of every unit.
  - Breaking for implementations: a class that implements `OfflineSyncEngine`
    or `OfflineSyncDatabase` must add the getters `batchBudget` and
    `rowIsolation`, unless it forwards missing members through `noSuchMethod`.
- feat: Row isolation (unibook#14251). A receiver that rejects one row stopped
  the whole account: the batch never merged, and every later session sent the
  same row first. `OfflineSyncRowIsolation` (`isolatedRows`, `releasedRows`,
  `onReleasedRowsConfirmed`), passed as `rowIsolation` like `batchBudget`,
  leaves the isolated rows out of every batch. Once a later change of the same
  node merges, the receiver's checkpoint is past them, so leaving isolation is
  not enough to send them again: a released row goes in full, every change of
  it read from the same snapshot whatever the checkpoints, once per session. A
  `once` session that ended with the peer's close and nothing left to send
  reports the released rows it sent to `onReleasedRowsConfirmed`; a continuous
  session, a failed one, or one closed early by an old peer reports nothing.
  A row in both sets is isolated. The implementation must keep both sets
  across restarts: an isolated row whose isolation is lost is silently no
  longer synced. `unsentRowCount` counts every row of both sets that exists
  locally, so a sign-out check does not drop them, also in the every-row
  fallback of a checkpoint that keeps going back. `watchUnsentRowCount` and
  `watchUnsentRowCountTriggers` count again once `onReleasedRowsConfirmed`
  returned: the session's commits come before it, so a count they started
  could still hold the released rows. Other changes to the sets commit
  nothing: count again after them. Deleting a row does not
  release it (the hidden domain row keeps the rejected value, which the insert
  carries); rewrite the rejected column, then delete and release.
  - The three pending-change streams are split into the checks
    (`_sendsInsert`/`Update`/`Delete`) and the resolvers
    (`_resolveInsert`/`Update`/`Delete`) that the planned collection shares;
    the upstream path behaves as before.

- feat: A continuous session can ask for a longer wait between rounds
  (unibook#14207). `OfflineSyncClient.syncContinuously`,
  `OfflineSyncDatabase.sync` and `OfflineSyncEngine.sync` take
  `continuousSyncInterval`, which travels to the other peer in the new
  nullable `OfflineSyncConnect.continuousSyncInterval`. Each peer waits the
  slower of the two requests, never below its configured
  `continuousSyncInterval` and never above the new
  `maxContinuousSyncInterval`, so a request only slows a session down. With
  no request a peer waits its configured interval, as before. A `once`
  session sends no request and ignores the peer's; `syncOnce` has no such
  parameter.
  - `maxContinuousSyncInterval` defaults to
    `defaultMaxContinuousSyncInterval` (30 s), or to the configured interval
    when that is longer, so a longer interval configured before keeps
    working. A value below the interval throws `ArgumentError`
    (`resolveMaxContinuousSyncInterval`). `OfflineSyncDatabase`,
    `OfflineSyncDatabaseSession` and `OfflineSyncDatabaseSession.wraps` take
    it and check it on construction; like `continuousSyncInterval` it is
    ignored when the session is given an already wrapped `OfflineSyncDatabase`.
    The generated `createSyncSession` forwards neither.
  - Wire: one nullable field on the connect frame, left out when null. A peer
    built before it sends none and ignores one (generated `fromJson` reads
    known keys only), so a new device on an old server gets the server's
    configured interval without notice. The module endpoint, the generated
    client and `OfflineSyncTransport` are unchanged. Regenerated
    `generated/sync/connect.dart` and `generated/sync/stream_event.dart`
    (the `_Undefined` sentinel of the nullable `copyWith`).
  - A session that asks for nothing runs at the configured interval, the
    fastest any request allows. Configure that interval for the load you
    accept; requests cannot make up for a low one.
  - While it waits, a peer does not read the other side, so a session whose
    device left ends up to one interval later, after one more round (space
    reconcile and the pending-change query). The maximum bounds that, and
    the number of such sessions after a burst of reconnects grows with it.
    Racing the wait against the peer closing would remove it but changes the
    loop: resuming the inbound subscription during the wait restarts the idle
    timeout, whose marker would then end the next round's batch at once.
  - Adds `OfflineSyncEngine.continuousSyncInterval`,
    `maxContinuousSyncInterval` and `@visibleForTesting
    resolveContinuousSyncInterval`.
  - Breaking for implementations: a class that implements
    `OfflineSyncEngine` must add the getters `continuousSyncInterval` and
    `maxContinuousSyncInterval` and the method
    `resolveContinuousSyncInterval`, unless it forwards missing members
    through `noSuchMethod`. A class that implements or overrides
    `OfflineSyncEngine.sync`, `OfflineSyncDatabase.sync` or
    `OfflineSyncClient.syncContinuously` must add the `continuousSyncInterval`
    parameter; `noSuchMethod` does not cover a declared override.

- feat!: A server gives every space its own CRDT node (unibook#14218).
  Upstream shared one node across all spaces of a database. On a server that
  node is persisted and shared by every instance, so a device clock pulling it
  ahead (up to `maxClockDrift`) moved the server's timestamps for every other
  user: their writes won LWW against newer edits, other users' devices stopped
  with a remote-ahead drift, all users drew on one 65,535 counter, and every
  merge waited on the one node row lock. The node, its clock, its counter and
  its row lock are now the space's. No schema or migration change: spaces
  already reference their node (`offline_sync_spaces.currentNodeId`).
  - A database opened without a persistent user (the server) assigns nodes per
    space. A device, opened with one, keeps one node for the install, shared by
    its spaces as before. There is no setting: the first database to use an
    `OfflineSyncDatabaseContext` decides it for good
    (`assignsNodePerSpace`), and a context that gave its spaces a node each
    refuses a persistent user with `StateError` instead of moving every space
    of the server back onto one node.
  - A space that still shares its node with another space (a server database
    written before) gets a new node on its next use. Its clock starts at the
    later of the shared node's clock and the latest timestamp stored in the
    space (row, field and tombstone stamps), never at the wall clock, the
    reverse of the device move onto a shared node. The space records the
    shared node's changes as held, so devices do not send them back. The move
    locks the space's row `FOR NO KEY UPDATE`, which a merge that only
    references the space does not wait on, reads the stored stamps, then locks
    the node and checks again: two sessions never give one space two nodes,
    and of the spaces moving off a node at once the last keeps it.
  - A server remembers, per context, the spaces it found holding their node
    alone (at most 100,000, oldest out first). Checking scans
    `offline_sync_spaces`, whose `currentNodeId` has no index, and a sync
    session gets its spaces several times; now a process checks a space once.
    An index would need a migration.
  - Deploys: a server of the version before still moves spaces onto one node
    (the first space's), and the two versions move spaces back and forth while
    both run. Clocks only rise, so LWW stays correct, but for that window a
    device can again pull the clock of other users' spaces. Do not run the two
    versions side by side against one database. A session that cached a space
    before its move also stamps with the old node until it ends.
  - A session over several spaces has one server node per space while the
    connect frame names one (the user's personal space's). Checkpoints are per
    space and node, so it stays consistent, and it is not rejected. A
    remote-ahead drift in one space still stops the whole session.
  - Residual within one space: a device's pull reaches the other devices of
    the same space, so between them the rule `C ≥ S + lag` still holds.
  - Breaking: a follower sync on a database without a persistent user throws
    `StateError`. A follower is a device: its own checkpoints and unsent row
    count follow the one node its connect frame names.
  - Breaking: a persistent user on a context that already gave its spaces a
    node each throws `StateError`.
  - Breaking: `OfflineSyncSpaceManager` takes the `context`.

- fix: The checkpoint a peer records for the other side's connect node holds
  only that node's own changes (unibook#14218). Upstream recorded the batch
  maximum, whichever node authored it, and the stored timestamp kept that
  node's id: the next handshake named that node and left the connect node
  without a checkpoint, so its changes in the space went out again every
  session until it wrote a later one. With a server node per space, the node a
  connect frame names can hold history in a space it no longer writes in (a
  space that left a shared node), where that never happens. A checkpoint
  stored under another node's id now gives way to the node's own changes, so
  one already stored that way stops the resend after one more.

- feat: Unsent row count for a device (unibook#14183). The protocol has no
  acknowledgement, so a device (follower) now keeps what the server confirmed
  in its own node's `offline_sync_space_nodes.lastReceivedHlc` per space. No
  schema, migration or wire change: handshakes never send that row.
  - The server's handshake checkpoint for this device replaces the recorded one
    each session, even when lower (a server that lost data).
  - A `once` session records the highest change it sent only after the
    server's `OfflineSyncClose` arrives; the server closes only after merging
    the last batch, so a failed round records nothing.
  - `OfflineSyncDatabase.unsentRowCount()` counts rows (not changes) of the
    synced tables with a change this node wrote after that checkpoint, with
    the collection filters narrowed to this node (three queries, row ids
    united). It reads the checkpoints before the rows and again after them,
    and counts again from the new ones when one went back meanwhile, so a
    concurrent sync can make it high, never low. `watchUnsentRowCount()` and
    `watchUnsentRowCountTriggers()` (SQLite only) re-count on commits, one
    count at a time; a failed count is an error event and the stream goes on.
  - The device writes those checkpoints through a recorder over the plain
    database, not a new `OfflineSyncDatabase` wrapper: a wrapper's first
    operation re-projects every space while the schema registry changed in
    this process, which made every idle round pay it once per handshaken space
    plus one.
  - `OfflineSyncEngine.countUnsentRows`, `@internal replaceSyncCheckpoint` on
    the database and the recorder.
  - Test hooks (`@visibleForTesting`):
    `CrdtMutationRecorder.debugProjectionRebuildCount` and
    `OfflineSyncEngine.debugOnUnsentRowCheckpointsRead`.
  - The count can stay high until the next successful `once` session: after a
    round the server merged but the device failed, during continuous sync, and
    for a space the server no longer syncs with the user.

- fix: A sync round no longer loses a local write committed while it collects
  its changes (unibook#14183). Upstream ran the insert, update and delete
  queries as each stream started, so a write committed between two of them
  was seen by the later one only: an update read after a missed insert
  advanced the node's checkpoint past the insert, and no later session sent
  it. The three queries now read one snapshot (a repeatable read transaction
  on PostgreSQL, the write lock on SQLite) before the first change is
  yielded. A node's writes commit in HLC order, so a snapshot holds all of a
  node's changes up to some HLC; later writes wait for the next round.
  Test hook (`@visibleForTesting`):
  `OfflineSyncEngine.debugOnPendingRowsRead`, between the insert and update
  queries.

- feat: Configurable clock drift allowance (unibook#14182). Upstream hard-coded
  one minute; the fork defaults to one hour (`Hlc.defaultMaxDrift`).
  - `Hlc.increment` and `Hlc.merge` take `maxDrift`. The one-minute literal in
    `increment` is gone, so both checks share one limit and a timestamp `merge`
    accepts no longer blocks the next local write. The local clock rollback
    check in `increment` stays as upstream.
  - `OfflineSyncDatabaseContext.maxClockDrift` (must be positive) holds the
    value; `OfflineSyncEngine`, `OfflineSyncDatabase` and
    `OfflineSyncDatabaseSession` (+ `.wraps`) take `maxClockDrift` and throw
    `ArgumentError` when it conflicts with a shared context or an already
    wrapped database. `HlcManager.forSpace(maxDrift:)` applies it.
  - BREAKING: `ClockDriftException` requires `kind` (`ClockDriftKind.remoteAhead`
    from `merge`, `localAhead` from `increment`) and carries `remoteNodeId`. Its
    `toString` no longer prints "ms" after a `Duration`, and keeps a
    sub-millisecond part (`3600000.600 ms`) instead of truncating it to the
    limit.
- fix: A merge bounds this node's own returning timestamps by the drift limit
  (`Hlc.adoptOwn`, `HlcManager.adoptOwn`). Upstream checked only the batch
  maximum and adopted it unchecked when it carried the receiver's node id, so a
  peer sending one change under the server's node id moved the clock every
  space shares arbitrarily far ahead and let the rest of the batch skip the
  check. The other nodes' maximum is now merged (and checked) first.
- feat: Typed sync failures on the wire. Serverpod forwards only
  `SerializableException`s from a streaming endpoint, so a server-side
  `ClockDriftException` reached the device as a plain connection error.
  - New models `OfflineSyncRemoteException` (`code`, `message`, `driftMs`,
    `maxDriftMs`) and `OfflineSyncFailureCode` (`clockDrift`,
    `serverClockDrift`, `hlcOverflow`, `duplicateNode`, `integrityViolation`,
    `unknown`). The enum decodes a code it does not know as `unknown`
    (`default: unknown`): throwing instead would make Serverpod's client close
    the whole WebSocket connection when a newer server adds a code.
  - `driftMs` is rounded up and `maxDriftMs` truncated, so a rejected drift
    always has `driftMs > maxDriftMs` (`merge` compares at microseconds).
  - `toOfflineSyncWireError` and the `offlineSyncWireErrors()` stream
    transformer map server-side failures and pass anything else through. A
    schema hash mismatch is not mapped.
  - An integrity violation reaches the device as a fixed message without
    identifiers. The server message names the space that owns the row, which
    for a personal space is another user's id, and the persisted violation id.
    `offlineSyncWireErrors(onMapped:)` hands the original to the caller, after
    the replacement is emitted, so the server can log it.
  - A build that predates `OfflineSyncRemoteException` cannot decode it, and
    Serverpod's client then closes the whole WebSocket connection: `unknown`
    covers new codes, not new classes. Ship apps that know a new wire class
    before the server sends it.

## 0.0.8+co.1 (co-serverpod fork)

Forked from upstream
[`96271a2`](https://github.com/marcelomendoncasoares/serverpod_offline_sync/commit/96271a25ab22c44dd3d94c6cd3fe910f63354609).

- feat: Support Serverpod `^4.1.0-beta.1`. `OfflineSyncDatabase` implements
  `watch` and `unsafeWatch`, so the generated `Model.db.watch(session, ...)` works
  on sync sessions.
  - Re-queries on commits to the CRDT visibility tables (`crdt_data_rows`,
    `offline_sync_spaces`, `offline_sync_space_members`), because deletes and
    merged tombstones never touch the domain row.
  - Every emission re-runs the CRDT-aware `find`, so tombstone and space
    predicates are rebuilt instead of frozen at subscription.
  - Skips results that serialize identically to the previous emission.
  - Restores `IncludeList.where` before each re-run so visibility predicates do
    not accumulate.
- chore: Regenerate the module with CLI 4.1.0-beta.1, which adds `watch` to every
  table repository.
- chore: Leave the upstream workspace, depend on sibling packages by path and
  set `publish_to: none`.

### Unreleased upstream changes included since 0.0.8

- fix: Author column values written by set-based updates (#147)
- fix: Preserve space state across export round trips (#148)
- fix: Repair foreign keys on columns that also carry a unique claim (#151)
- fix: Refresh node clocks across sync wrappers (#152)

## 0.0.8

- fix: BREAKING. Reject unique-text values ending in `__conflict__<UUID>`,
  `__hidden__<UUID>`, or `__park__<UUID>`, and unique version-8 UUIDs (except
  primary keys, foreign keys, and nullable UUID columns). Local writes and
  incoming sync throw `OfflineSyncReservedValueException` for these values.
- fix: Enforce database unique constraints on local writes and restores, and
  reject upsert batches that target the same record more than once.
- fix: Retain upserted values and explicit nulls when replacing a conflicting
  value, including upserts matched through another unique index.
- fix: Treat restored rows as fresh writes so field values and conflict ages
  stay consistent across sync and bootstrap.
- fix: Preserve UUID-shaped text and binary values during conflict resolution
  and sync, and encode restored values according to their column types.
- fix: Show UUIDs correctly in errors for references to deleted records.

## 0.0.7

- fix: Keep non-synced `updateRow` calls in the test harness transaction.
- fix: Allow generated client sync sessions to close their SQLite connections.
- fix: Resolve shared-package models and enums during projection and sync.
- fix: Preserve boolean types when syncing SQLite column updates.
- fix: Preserve JSON and JSONB field types and values through inserts, updates,
  and explicit nulls.

## 0.0.6

- refactor: BREAKING. Rename integration APIs and ownership scopes:
  - Rename `CrdtDatabase*` wrappers to `OfflineSyncDatabase*`.
  - Rename `CrdtSync` to `OfflineSyncEngine` and `CrdtSyncSession` to
    `OfflineSyncSubscription`.
  - Access sync through `.offlineSync` and `.offlineSyncDb` instead of
    `.crdt` and `.crdtDb`.
  - Replace `CrdtScope*` models and services with `OfflineSyncSpace*`
  - Change access to shared spaces through `.spaces` instead of `.scopes`.
  - Use `spaceId` in models and indexes, and `offline_sync_spaces` in
    ownership relations.
  - Initialize with `initializeOfflineSync` and use `offlineSyncDatabaseInterceptor`.
  - Import client helpers from `offline_sync.dart` instead of `crdt.dart`.
  - Rename the synchronization endpoint, serialized events, and space metadata
  tables.
- fix: Recompute `onDelete=SetDefault` repairs when default targets are
  inserted, deleted, restored, or hidden to preserve authored values.
- fix: Reject local deletes atomically when a needed `SetDefault` target is
  missing, hidden, owned by another space, or deleted in the same batch.
- fix: Preserve projection-selected nulls during inserts instead of reapplying
  column defaults, and apply fixed UUID foreign-key defaults in local upserts.
- fix: Resolve composite unique conflicts when only a fixed discriminator
  column changes.
- perf: Avoid redundant foreign-key projection for ordinary local writes and
  primary-key upserts, and batch dependency checks and field-clock writes.
- perf: Overlap independent membership reads and skip unnecessary space lookups
  for untracked tables.
- chore: Update Serverpod to `4.0.0` and use the published CLI.

## 0.0.5

- fix: BREAKING. Rebuilds foreign key and unique projection from authored facts.
- perf: Increases unique-conflict merge throughput by ~40%.
- perf: Increases foreign-key chain insert merge throughput by ~3.3×.
- perf: Increases foreign-key chain delete merge throughput by ~44%.
- perf: Reduces storage used by CRDT metadata on relations.
- chore: Updated Serverpod to `4.0.0-rc.2`.

## 0.0.4

- chore: Updated Serverpod to `4.0.0-rc.1`.

## 0.0.3

- fix: Requires non-nullable foreign keys to be `deferred`.
- fix: Rejects `onDelete=Restrict` on synced tables in favor of `onDelete=NoAction`.
- fix: Throws proper `DatabaseException` instead of bare `Exception` on the database.
- chore: Updated Serverpod to `4.0.0-rc.1`.

## 0.0.2

- fix: Skips tracking FKs for relations with non-sync tables.
- fix: Fixes batch `insert` of previously tombstoned rows not being tracked correctly.
- refactor: Moves the core implementation to the `serverpod_offline_sync` shared package.
- chore: Updated Serverpod to `4.0.0-beta.2`.

## 0.0.1

- chore: Initial version.
