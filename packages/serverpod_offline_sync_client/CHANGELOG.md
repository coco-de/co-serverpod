## Unreleased (co-serverpod fork)

- feat: `OfflineSyncStatusTracker` and `OfflineSyncStatus` (unibook#14183),
  the fork's `CoSyncStatus`: `phase` (`syncOnce` running), `unsentRowCount`
  (null is unknown, not zero), `lastSuccessAt`, `lastFailure` classified by
  `OfflineSyncFailure.from` and `lastFailureAt`, with `isIdle` and
  `needsAttention`. `syncOnce` joins a running round and publishes its outcome
  with the count read after it in one event, then rethrows a failure.
  `syncContinuously` records a failure without touching the phase or the last
  success. Counts run one at a time, each started after its trigger; on SQLite
  a commit watch picks up offline writes. `countUnsentRows()` reads the count
  fresh for a sign-out warning.
- chore: Depend on `clock`.

- feat: `OfflineSyncFailure.from(error)` classifies a sync error into an
  `OfflineSyncFailureReason` with `isPermanent` and `isClockDrift`
  (unibook#14182). Server codes come from `OfflineSyncRemoteException`; a local
  `ClockDriftException` becomes `clockDriftBehind` (`remoteAhead`) or
  `clockRollback` (`localAhead`); a schema hash mismatch becomes
  `schemaMismatch` without a direction; stream failures become `transport`.
  A refused stream (`OpenMethodStreamException`) is not a transport failure:
  it becomes `authenticationFailed`, `authorizationDeclined` or
  `incompatibleEndpoint` (`endpointNotFound`, `invalidArguments`), all
  permanent. A server code this build does not know becomes `unknown`.
- test: Add the package's first tests; CI now runs `dart test` here.

## 0.0.8+co.1 (co-serverpod fork)

- chore: Depend on Serverpod `^4.1.0-beta.1` and on the forked
  `serverpod_offline_sync` through a sibling path. Regenerating with CLI
  4.1.0-beta.1 left this package's generated code unchanged.

See [`serverpod_offline_sync/CHANGELOG.md`](../serverpod_offline_sync/CHANGELOG.md)
for the fork changes and the upstream history.
