## Unreleased (co-serverpod fork)

- docs: `initializeOfflineSync(maxClockDrift:)` describes the server node per
  space (unibook#14218): one device's pull reaches only its own space, and
  lowering the limit blocks writes only in the spaces whose node is ahead.
- test: A space's merge no longer waits for another space's merge holding its
  node row (PostgreSQL). The PostgreSQL tests share one embedded postmaster per
  process in a directory of its own: with its data directory right in the
  system temp directory, it bound the same socket as the postmaster an earlier
  run left and could not start.

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
