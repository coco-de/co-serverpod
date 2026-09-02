# Changelog

## [0.3.0](https://github.com/coco-de/co-serverpod/compare/co_offline_sync-v0.2.0...co_offline_sync-v0.3.0) (2026-09-02)


### 기능

* **offline-sync:** ✨ 스키마 버전 호환 창 — SchemaRegistry · pull 투영 · 불일치 원인 분류 ([#19](https://github.com/coco-de/co-serverpod/issues/19)) ([139e2eb](https://github.com/coco-de/co-serverpod/commit/139e2eb59b361b7e8fcaddf569513e1d4ff007fc))
* **offline-sync:** ✨ 클라이언트 청크 push 분할·행 단위 직렬화 (unibook[#12839](https://github.com/coco-de/co-serverpod/issues/12839)) ([#20](https://github.com/coco-de/co-serverpod/issues/20)) ([792de07](https://github.com/coco-de/co-serverpod/commit/792de0784e04747cfd09293b3a30c0334c72f8ca))

## [0.2.0](https://github.com/coco-de/co-serverpod/compare/co_offline_sync-v0.1.0...co_offline_sync-v0.2.0) (2026-09-01)


### 기능

* **offline-sync:** ✨ co_offline_sync 코어 패키지 신설 — HLC·필드 LWW 병합·커서 델타 프로토콜 ([#14](https://github.com/coco-de/co-serverpod/issues/14)) ([367a638](https://github.com/coco-de/co-serverpod/commit/367a63882ee7260007fde700e87e5c11d39dbd30))

## 0.1.0

- 최초 릴리스 — offline-first 동기화 엔진 코어.
  - `Hlc`/`HlcClock` 하이브리드 논리 시계 (드리프트 가드·카운터 오버플로 검출,
    packed 문자열 사전순 == 비교 순서)
  - `RowState`/`mergeRowStates` 필드 단위 LWW 병합 (교환·결합·멱등 property
    테스트 고정) + `$deleted` tombstone, `TombstonePolicy` (deleteWins/editWins 뷰)
  - 커서 기반 델타 프로토콜 (`SyncPush*`/`SyncPull*`, 행 상태 전체 전송으로
    재시도 멱등) + `schemaSignature` 불일치 거부
  - `ClientSyncStore`/`ServerSyncStore` 계약 + 인메모리 참조 구현,
    테이블 단위 변경 스트림 (반응형 계층 접점)
  - `CoSyncClient`/`CoSyncServer`/`InProcessTransport` — 전송 중 로컬 편집
    pending 보존, 커서 페이지네이션, echo 무시
  - 적대적 리뷰(2026-09-01) 6건 반영: pull 진행 가드·limit 검증(무한 루프 차단),
    HLC 시계 재시작 시드(`HlcClock.seed`/`initial` + 저장소 `maxHlc()` 자동 시드
    — 재시작 후 로컬 편집 lost-update 차단), 스키마 서명 JSON 정준화(구분자 주입
    차단), 서버/클라 페이로드 검증(`syncSchema` 기반 — 예약 필드·미지 테이블·컬럼
    거부), `Hlc.parse` 엄격화(소문자 hex 고정폭), `sync()` 동시 호출 직렬화
