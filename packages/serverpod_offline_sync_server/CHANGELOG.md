## Unreleased (co-serverpod fork)

- feat: `initializeOfflineSync(batchBudget:)` bounds what the server sends a
  device in one batch (unibook#14251), and `OfflineSyncSession.batchBudget`
  reads it. Unlimited by default, as upstream: a device syncing for the first
  time received everything in one batch, which it holds in memory before it
  merges it. With a budget, a `once` session sends the rest in more rounds
  before it closes and a continuous session one batch per round. It applies
  to every sync session of the pod and to the databases the interceptor
  wraps. A device built before `OfflineSyncEndOfBatch.hasMore` closes its
  `once` session after the first batch and gets the rest in its next
  sessions. The server always tells the device whether it has more, even
  without a budget. Row isolation is a device's and has no server setting.
  Breaking for implementations: a class that implements `OfflineSyncSession`
  must add the `batchBudget` getter.

- feat: A continuous session's wait is bounded per session (unibook#14207).
  `initializeOfflineSync(continuousSyncInterval:)` is the shortest wait a
  session can ask for and the wait of a session that asks for nothing; the
  new `maxContinuousSyncInterval` is the longest (default 30 s, or the
  interval when that is longer; below the interval throws `ArgumentError` at
  startup). The device asks in its connect frame, so the module endpoint
  `offlineSync.sync` is unchanged. `OfflineSyncSession.sync` takes
  `continuousSyncInterval` too, for an app endpoint to slow a session down on
  top of the device's request: the slower one wins. Breaking for
  implementations: a class that implements or overrides
  `OfflineSyncSession.sync` must add the parameter.

- docs: `initializeOfflineSync(maxClockDrift:)` describes the server node per
  space (unibook#14218): one device's pull reaches only its own space, and
  lowering the limit blocks writes only in the spaces whose node is ahead.
- test: A space's merge no longer waits for another space's merge holding its
  node row, a space leaving a shared node does not wait for a merge that only
  references it, and spaces leaving at once get one node each while the last
  keeps the shared one (PostgreSQL). The session databases the interceptor
  gives out assign a node per space (SQLite).
- test: Each PostgreSQL test file runs its own embedded postmaster in a
  directory of its own (`TestPostgres`), stopped and removed when the file
  ends. `serverpod_test` leaves the postmaster it started running, one per run
  on a machine that may host CI runners. With its data directory right in the
  system temp directory, it also bound the socket of the one an earlier run
  left and could not start. Adds the dev dependency
  `serverpod_embedded_postgres`.

- test: `initializeOfflineSync(continuousSyncInterval:)` reaches the wait
  between continuous rounds, and the default stays 200 ms as upstream
  (unibook#14183). No code change.
- docs: `initializeOfflineSync` warns that the generated `Serverpod`
  constructor already calls it with defaults and that each call replaces the
  engine, so a later call must pass every setting at once.

- feat: `initializeOfflineSync(maxClockDrift:)` sets the server's clock drift
  allowance (default one hour) and `OfflineSyncSession.maxClockDrift` reads it
  (unibook#14182).
- feat: `OfflineSyncSession.sync`, and so the module endpoint, maps sync
  failures with `offlineSyncWireErrors()`. A device now receives
  `OfflineSyncRemoteException` instead of a bare connection error when the
  server rejects its clock, overflows its counter, sees a duplicate node or an
  integrity violation. The original failure is logged to the session at
  `LogLevel.error`, since the device and Serverpod's own log get only the
  replacement, and an integrity violation's replacement carries no
  identifiers.
- docs: `maxClockDrift` notes the rule `C ≥ S + device lag`, the write outage
  when the limit is lowered while the server node is ahead, and the counter
  overflow exposure while it stays ahead.

## 0.0.8+co.1 (co-serverpod fork)

- chore: Depend on Serverpod `^4.1.0-beta.1` and on the forked
  `serverpod_offline_sync` through a sibling path. Regenerating with CLI
  4.1.0-beta.1 left this package's generated code unchanged.

See [`serverpod_offline_sync/CHANGELOG.md`](../serverpod_offline_sync/CHANGELOG.md)
for the fork changes and the upstream history.
