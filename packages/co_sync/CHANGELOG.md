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

## [0.2.0](https://github.com/coco-de/co-serverpod/compare/co_sync-v0.1.0...co_sync-v0.2.0) (2026-09-15)


### 기능

* **co-sync:** ✨ ReplicaPuller 세대 토큰 — applyPage 직전 중단 ([#25](https://github.com/coco-de/co-serverpod/issues/25)) ([9368e71](https://github.com/coco-de/co-serverpod/commit/9368e71c4e7fbc56c4c5a59c8a1f8736cc365fda))
* **co-sync:** ✨ 공용 JSON 전송 어댑터와 스키마 프로브 추가 ([#26](https://github.com/coco-de/co-serverpod/issues/26)) ([#27](https://github.com/coco-de/co-serverpod/issues/27)) ([069d21a](https://github.com/coco-de/co-serverpod/commit/069d21a789251dd78986b456006f38ae211df5d8))
* **sync:** ✨ 관측 가능한 동기화 상태 노출 — CoSyncStatus·unsentRowCount (unibook[#13737](https://github.com/coco-de/co-serverpod/issues/13737)) ([#29](https://github.com/coco-de/co-serverpod/issues/29)) ([d0d653a](https://github.com/coco-de/co-serverpod/commit/d0d653a29ad7d73f0768774de3623e8f6ded3c00))
* **sync:** ✨ 메타데이터 동반 원자 삭제 API 추가 ([#23](https://github.com/coco-de/co-serverpod/issues/23)) ([#24](https://github.com/coco-de/co-serverpod/issues/24)) ([bb9e6ab](https://github.com/coco-de/co-serverpod/commit/bb9e6abffb18930dba9f68c6ae9d0f71119397d4))


### 버그 수정

* **sync:** 🐛 영구 실패 행 격리(quarantine)·청크 진행 + H8·H9 수정 (unibook[#13736](https://github.com/coco-de/co-serverpod/issues/13736)) ([#28](https://github.com/coco-de/co-serverpod/issues/28)) ([487f9fc](https://github.com/coco-de/co-serverpod/commit/487f9fc0c26a2ef2e688a3988a27cb76a9295301))


### 리팩터링

* **co-sync:** ♻️ 공용 클라이언트 패키지 이름을 co_sync로 변경 ([#22](https://github.com/coco-de/co-serverpod/issues/22)) ([ec001b9](https://github.com/coco-de/co-serverpod/commit/ec001b955846b1291da7a8fe4efb7109f610ff9b))

## 0.1.0

- Extract the reusable Flutter runtime, Drift stores, replica puller and reactive
  queries from `coco-de/unibook`'s `package/co_sync`.
- Require application schemas and schema versions through constructor injection.
- Preserve database name, schema version, pending writes and cursor formats.
- Keep generated Serverpod clients and application schemas in the consuming app.

Source: [`coco-de/unibook@ad628db792`](https://github.com/coco-de/unibook/tree/ad628db79244d72a5004403847edeebf24ab6527/package/co_sync).
