## Unreleased (co-serverpod fork)

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
