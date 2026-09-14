# Changelog

## Unreleased

- Export `JsonSyncTransport` with JSON string and decoded-map callbacks for
  application-owned Serverpod, HTTP/OpenAPI and GraphQL clients, without SDK
  dependencies or changes to the core transport, runtime or persisted state.
- Add optional `JsonSchemaWindowProbe` with strict schema-window shape validation.
- Preserve callback error identity/stack and classify malformed successful JSON
  responses as `SyncProtocolException`; retain the original example import path.
- Add backend adapter examples and contract tests, including GraphQL partial-error
  rejection before pending acknowledgement or pull page/cursor application.
- Add `ReplicaPuller.reset()` and `ReplicaPuller.generation`; in-flight pulls now
  abort with `ReplicaPullAborted` immediately before `ReplicaStore.applyPage`, so a
  page fetched for a previous account can no longer land after a wipe.
- Add `CoSyncRuntime.deleteWithFields(table, rowId, fields)` with atomic metadata
  and tombstone writes, field-size validation and existing account/sync guards.
- Rename `co_offline_sync_client` to `co_sync`; update the Git package path and Dart import.
- Preserve the runtime API, database name, SQLite schema and persisted sync state.

## 0.1.0

- Extract the reusable Flutter runtime, Drift stores, replica puller and reactive
  queries from `coco-de/unibook`'s `package/co_sync`.
- Require application schemas and schema versions through constructor injection.
- Preserve database name, schema version, pending writes and cursor formats.
- Keep generated Serverpod clients and application schemas in the consuming app.

Source: [`coco-de/unibook@ad628db792`](https://github.com/coco-de/unibook/tree/ad628db79244d72a5004403847edeebf24ab6527/package/co_sync).
