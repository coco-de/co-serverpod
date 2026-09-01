# co_offline_sync

Cocode 앱용 offline-first 동기화 엔진 **코어**. 순수 Dart(백엔드 불가지론)로,
하이브리드 논리 시계(HLC) · 필드 단위 LWW 병합 · tombstone · 커서 기반 델타
프로토콜 · 저장소/전송 계약을 제공합니다.

> **설계 배경**: coco-de/unibook#12634 (Serverpod Offline Sync 전면 전환
> Project) 의 S1 설계 문서 `docs/architecture-offline-sync-crdt-s1.md` §8
> **B안(자체 구축)** 채택 산출물입니다. `serverpod_offline_sync` 0.0.4 의
> delta-CRDT 설계와 `sql_crdt`(Cachapa) 의 HLC·LWW 모델,
> `offline_sync_engine` 의 오퍼레이션 로그 구조를 참고했습니다 — 셋 다
> **의존하지 않습니다** (설계 참조만).

## 왜 자체 구축인가 (요약)

| 축 | 이 패키지 |
|---|---|
| 반응형 (R2) | 저장소 계약이 **테이블 단위 변경 스트림**을 1급으로 노출 — drift 구현 시 watch 가 그대로 반응형 계층이 된다 |
| 스키마 침습 (S2) | 서버 테이블의 PK 를 바꾸지 않는다 — 행 식별은 전역 고유 `rowId` 문자열(권장: UUID v7 **컬럼**)로, 기존 int PK 에 **가산적** |
| 병합 | 필드 단위 LWW join-semilattice — 교환·결합·멱등이 property 테스트로 고정 (`test/merge_test.dart`) |
| 삭제 | tombstone 을 예약 필드 `$deleted` 의 LWW 로 표현. "동시 편집 vs 삭제" 는 [TombstonePolicy] **뷰** 로 해석 (deleteWins 기본 / editWins) — 저장 상태가 같아 정책 변경에 마이그레이션 불요 |
| 재시도 안전 | 변경 단위가 델타가 아니라 **행 상태 전체** — 중복 전달·재시도가 구조적으로 멱등 |
| 다중 인스턴스 | 서버 상태(행·seq 커서)는 전부 `ServerSyncStore` 뒤 — **반드시 DB 구현**을 쓸 것 (EC2 다중 인스턴스 · sticky 없음 전제) |

## 구성

```
Hlc / HlcClock            하이브리드 논리 시계 (packed 문자열이 사전순 정렬 가능,
                          재시작 복원용 initial/seed 제공)
RowState / mergeRowStates 필드 단위 LWW 병합 (join)
RowChange / Sync*         와이어 프로토콜 (JSON)
computeSchemaSignature    동기화 스키마 서명 — 불일치 시 동기화 거부
ClientSyncStore           클라 저장소 계약 (pending 부기 + 변경 스트림 + 커서 + maxHlc)
ServerSyncStore           서버 저장소 계약 (행 + 단조 seq)
CoSyncClient              로컬 쓰기 스탬핑·검증 · push/pull · 병합 · 시계 자동 시드
CoSyncServer              push 적용(멱등·페이로드 검증) · pull 페이지네이션
SyncTransport             전송 추상화 (+ InProcessTransport 테스트용)
InMemory*Store            참조 구현 (테스트·프로토타이핑 전용)
```

## 사용 예 (인메모리)

```dart
const syncSchema = {
  'bookmark': ['title', 'page'],
};

final server = CoSyncServer(
  store: InMemoryServerSyncStore(), // 프로덕션: DB 구현으로 교체
  clock: HlcClock(nodeId: 'server'),
  syncSchema: syncSchema,
);

final client = CoSyncClient(
  store: InMemoryClientSyncStore(), // 프로덕션: drift/SQLite 구현으로 교체
  transport: InProcessTransport(server), // 프로덕션: Serverpod 엔드포인트 어댑터
  clock: HlcClock(nodeId: '<기기 고유 UUID>'),
  syncSchema: syncSchema,
);

// 오프라인에서도 즉시 반영 + 변경 스트림 통지
await client.upsert('bookmark', rowId, {'title': '1장', 'page': 10});
client.changes.listen((c) => print('changed: ${c.table}/${c.rowId}'));

// 온라인 복귀 시
await client.sync();
```

## 로드맵 (unibook Project #12634)

| 단계 | 내용 | 위치 |
|---|---|---|
| S3 | `ServerSyncStore` Postgres 구현 + Serverpod 스트리밍/엔드포인트 어댑터 (동기화 커서는 DB) | unibook backend |
| S3 | `ClientSyncStore` drift 구현 (`co_offline_sync_drift` 후보) — watch 기반 반응형 | 이 리포 또는 unibook |
| S7 | 테이블 변경 스트림 → SWR/BLoC 반응형 계층 배선 | unibook |

## 운영 노트 (알려진 한계 — 2026-09-01 적대적 리뷰 반영)

- **시계 드리프트 스탬프의 격리 없음**: 벽시계가 크게 빠른 노드의 스탬프가 서버에
  수용되면(허용 한도 1h 이내), 시계가 느린 다른 노드는 pull 중
  `ClockDriftException` 으로 해당 행 앞에서 멈춘다 — 시간이 지나면 자가 해소되지만
  그동안 sync 가 전면 대기한다. 행 단위 스킵/격리는 소비 측 요구가 생기면 추가한다.
- **필드 값은 JSON-안정 값만**: `jsonEncode` 왕복으로 타입이 보존되는 값을 쓸 것.
  웹(dart2js)에서는 `2.0` 이 `2` 로 직렬화되므로 int/double 구분에 의미를 두지 말 것.
- `sync()` 는 인스턴스 내부에서 직렬화된다 — 하지만 **서로 다른 두 인스턴스**로
  같은 저장소를 동시에 sync 하는 것은 지원하지 않는다.

## 비범위 (명시적)

- 인증·권한(scope/grant) — 소비 측(Serverpod 세션)이 판단한다. 이 코어는
  "누가 이 행을 받을 수 있는가" 를 모른다.
- blob 동기화 — 필기 이미지 등 대용량 payload 는 별도 채널(S3 presigned)로.
- 자동 폴링/백그라운드 스케줄 — 호출 시점은 소비 측이 정한다.
