## Unreleased (co-serverpod fork)

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
