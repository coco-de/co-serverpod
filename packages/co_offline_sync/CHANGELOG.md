# Changelog

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
