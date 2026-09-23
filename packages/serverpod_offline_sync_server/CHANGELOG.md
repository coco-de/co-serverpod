## Unreleased (co-serverpod fork)

- feat: `initializeOfflineSync(maxClockDrift:)` sets the server's clock drift
  allowance (default one hour) and `OfflineSyncSession.maxClockDrift` reads it
  (unibook#14182).
- feat: `OfflineSyncSession.sync`, and so the module endpoint, maps sync
  failures with `offlineSyncWireErrors()`. A device now receives
  `OfflineSyncRemoteException` instead of a bare connection error when the
  server rejects its clock, overflows its counter, sees a duplicate node or an
  integrity violation.

## 0.0.8+co.1 (co-serverpod fork)

- chore: Depend on Serverpod `^4.1.0-beta.1` and on the forked
  `serverpod_offline_sync` through a sibling path. Regenerating with CLI
  4.1.0-beta.1 left this package's generated code unchanged.

See [`serverpod_offline_sync/CHANGELOG.md`](../serverpod_offline_sync/CHANGELOG.md)
for the fork changes and the upstream history.
