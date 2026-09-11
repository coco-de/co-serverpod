# Changelog

## Unreleased

- Add `ReplicaPuller.reset()` and `ReplicaPuller.generation`; in-flight pulls now
  abort with `ReplicaPullAborted` immediately before `ReplicaStore.applyPage`, so a
  page fetched for a previous account can no longer land after a wipe.
- Add `CoSyncRuntime.deleteWithFields(table, rowId, fields)` with atomic metadata
  and tombstone writes, field-size validation and existing account/sync guards.
- Rename `co_offline_sync_client` to `co_sync`; update the Git package path and Dart import.
- Preserve the runtime API, database name, SQLite schema and persisted sync state.

## [0.2.0](https://github.com/coco-de/co-serverpod/compare/co_sync-v0.1.0...co_sync-v0.2.0) (2026-09-11)


### 기능

* **co-sync:** ✨ ReplicaPuller 세대 토큰 — applyPage 직전 중단 ([#25](https://github.com/coco-de/co-serverpod/issues/25)) ([9368e71](https://github.com/coco-de/co-serverpod/commit/9368e71c4e7fbc56c4c5a59c8a1f8736cc365fda))
* **sync:** ✨ 메타데이터 동반 원자 삭제 API 추가 ([#23](https://github.com/coco-de/co-serverpod/issues/23)) ([#24](https://github.com/coco-de/co-serverpod/issues/24)) ([bb9e6ab](https://github.com/coco-de/co-serverpod/commit/bb9e6abffb18930dba9f68c6ae9d0f71119397d4))


### 리팩터링

* **co-sync:** ♻️ 공용 클라이언트 패키지 이름을 co_sync로 변경 ([#22](https://github.com/coco-de/co-serverpod/issues/22)) ([ec001b9](https://github.com/coco-de/co-serverpod/commit/ec001b955846b1291da7a8fe4efb7109f610ff9b))

## 0.1.0

- Extract the reusable Flutter runtime, Drift stores, replica puller and reactive
  queries from `coco-de/unibook`'s `package/co_sync`.
- Require application schemas and schema versions through constructor injection.
- Preserve database name, schema version, pending writes and cursor formats.
- Keep generated Serverpod clients and application schemas in the consuming app.

Source: [`coco-de/unibook@ad628db792`](https://github.com/coco-de/unibook/tree/ad628db79244d72a5004403847edeebf24ab6527/package/co_sync).
