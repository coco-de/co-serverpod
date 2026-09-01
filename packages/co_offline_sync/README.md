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

## 스키마 버저닝 — 호환 창 (compatibility window)

서명 대조는 전부-아니면-전무라, 서버가 컬럼 하나를 더하는 순간 아직 업데이트하지
않은 앱의 동기화가 **영구 실패**한다. `SchemaRegistry` 는 서버가 현행뿐 아니라
이전 버전 N개를 함께 받아 주게 한다.

```dart
final registry = SchemaRegistry([
  SchemaVersion(version: 1, tables: {'bookmark': ['title', 'page']}),
  SchemaVersion(version: 2, tables: {'bookmark': ['title', 'page', 'note']}),
]);

final server = CoSyncServer.withRegistry(
  store: ..., clock: ..., registry: registry,
);

final client = CoSyncClient(
  ..., syncSchema: registry.current.tables, schemaVersion: registry.current.version,
);
```

| 규칙 | 내용 |
|---|---|
| **서명이 정본** | 요청은 서명으로 어느 버전인지 확정된다. 버전 번호는 불일치 시 원인 분류(`SchemaMismatchReason`)용 힌트일 뿐이다 |
| **가산적 진화만** | 창 안의 각 버전은 직전 버전의 상위집합이어야 한다 (테이블·컬럼 추가만). 위반은 `SchemaRegistry` 생성 시 `ArgumentError` |
| **신 컬럼은 optional** | 구 클라이언트가 만든 행에는 그 필드가 없다 — nullable 이거나 앱 기본값이 있어야 한다 (소비 측 규약) |
| **push 검증 = 레지스트리가 아는 컬럼 전체** | 어느 버전도 모르는 컬럼·예약 필드만 프로토콜 위반. 롤링 배포 중 구 인스턴스가 투영 없이 내려준 신 컬럼을 구 클라이언트가 되실어도 거부하지 않는다(그 값은 서버가 준 것이라 LWW 에서 no-op) |
| **pull 투영** | 구 클라이언트에는 그 버전의 컬럼만 내려간다 (`$deleted` 는 값과 무관하게 보존 — 삭제·되살림 대칭). 모르는 테이블의 변경은 빠지되 커서는 전진. 응답 `hlc` 로 투영 전 최대 스탬프를 함께 내려 구 클라이언트 시계가 뒤처지지 않게 한다 |
| **클라 방어선** | `_pull` 은 받은 상태를 자기 컬럼으로 투영하고, **본 적 없는 행**에 앱 필드가 없고 tombstone 도 아니면 저장하지 않는다(phantom 방지). `_push` 도 자기 컬럼으로 투영해 보낸다 |
| **유실 0** | 구 클라이언트의 편집은 자기 컬럼만 나르고 필드 단위 LWW 가 나머지를 보존한다 (`test/schema_versioning_test.dart` "유실 0") |
| **창 닫기** | 목록에서 빼면 그 버전은 `clientOutdated` 로 거부 — 앱 강제 업데이트와 같은 시점에 |

제거·이름 변경이 정말 필요하면 새 테이블/컬럼을 추가하고 옛 것을 창이 닫힐 때까지
병존시킨다. 단일 스키마 생성자 `CoSyncServer(syncSchema:)` 는 버전 1개짜리
레지스트리와 같다.

알려진 한계: `TombstonePolicy.editWins` 는 창 안에서 버전 간 뷰가 갈릴 수 있다
(구 클라이언트는 신 컬럼의 스탬프를 못 본다) — 창 운영 중에는 `deleteWins` 권장.
`protocolVersion` 을 올리면 창 안 모든 서명이 바뀌어 창이 통째로 닫힌다.

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
