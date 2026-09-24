# 테스트 가이드

## 단위 테스트 (DB 불필요)

순수 파싱 로직(`parse{Kakao,Naver}Profile`, `parse*TokenResponse`) — codegen/DB 없이 즉시 실행.

```bash
cd packages/serverpod_auth_idp_naver_server && dart test test/naver_profile_test.dart
cd packages/serverpod_auth_idp_kakao_server && dart test test/kakao_profile_test.dart
```

## serverpod_offline_sync 포크 (DB 서버 불필요)

엔진 단위 테스트, 모듈 통합 테스트(`config/test.yaml`의 SQLite 파일, 1개는 Serverpod 내장 PostgreSQL 자동
기동), 생성된 `Model.db.watch` 테스트를 실행합니다. watch 테스트는 SQLite 복제본 두 개를 한 프로세스에서
동기화하며, 한쪽이 서버 endpoint 역할(authoritative)을 맡습니다.

```bash
cd packages/serverpod_offline_sync && dart pub get && dart test
cd packages/serverpod_offline_sync_client && dart pub get && dart test
cd packages/serverpod_offline_sync_server && dart pub get && dart test --concurrency=1
cd test/offline_sync_watch_test_client && dart pub get && dart test
```

| watch 케이스 | 검증 |
|---|---|
| 로컬 insert/update/delete | 삭제는 CRDT 메타데이터만 써도 다시 emit |
| `where`·`limit`/`offset` | 조건에서 빠지거나 삭제된 행이 페이지에서 사라짐 (offset 단독 포함) |
| include 목록 | 삭제된 자식이 목록에서 빠지고 가시성 조건이 누적되지 않음 |
| 롤백·무관한 동기화 테이블 쓰기 | 결과가 같으면 emit하지 않음 |
| 동기화 병합 insert/update/delete, 연속 동기화 | 다른 복제본의 변경이 병합 즉시 반영 |
| `database: client` 테이블, `unsafeWatch` | 동기화 세션을 거쳐도 동작 |

시계 오차 허용치와 실패 분류(unibook#14182)는 네 곳에서 나눠 검증합니다.

| 위치 | 검증 |
|---|---|
| 엔진 `test/hlc/hlc_max_drift_test.dart`·`test/managers/hlc_manager_test.dart` | 기본 1시간, 정확히 한도는 허용·1ms 초과는 거부(`merge`·`increment`·`adoptOwn`), 5분 사용자 값, `merge` 가 받은 스탬프 뒤 `increment` 성공(한 값 공유), `kind`·`remoteNodeId`·`toString` |
| 엔진 `test/sync/` | context·엔진의 값 전달과 충돌 `ArgumentError`, 와이어 매퍼 구조 단언과 메서드 스트림 메시지 왕복, 알 수 없는 예외 통과, 모르는 코드 → `unknown`, 1ms 미만 초과의 `driftMs` 올림, 무결성 위반 메시지에 소유 space·행·위반 id 없음(원본엔 있음을 대조), `onMapped` 순서·미호출 |
| 클라이언트 `test/failure_test.dart` | `OfflineSyncFailure.from` 전 분기(기기 로컬 무결성 위반·열기 거부 4종·모르는 서버 코드 포함), `isPermanent`·`isClockDrift` 집합, 생성 client Protocol 로 복호(모르는 코드도 연결을 닫지 않고 복호) |
| 서버 모듈 `failure_mapping_test.dart` | `initializeOfflineSync(maxClockDrift:)` 배선, 파사드 매핑과 원본의 세션 로그 기록(통과시킨 실패는 기록 안 함), 생성 endpoint 경유 `integrityViolation`(메시지에 space id 없음) |
| watch `clock_drift_test.dart` | 고정 시계(`withClock`)로 K1(기기 뒤처짐)·K2(기기 앞섬, 타입 있는 예외, 서버 노드 id 위조)·K3(로컬 역행)·허용치 차이(C < S 면 시계가 정확한 기기도 K1)·실패 회차 재전송(서버가 놓친 경우·병합한 경우 각각)·같은 한도 재래핑·감싸지 않은 DB 에 context 와 다른 한도를 넘기면 생성자 3종 모두 `ArgumentError` |

미전송 건수·동기화 상태와 연속 동기화 간격(unibook#14183)은 네 곳에서 검증합니다.

| 위치 | 검증 |
|---|---|
| 엔진 `test/database/unsent_row_count_test.dart` | `watchUnsentRowCount` 파이프라인(`countOnEachTrigger`): 실패한 셈은 오류 이벤트이고 다음 트리거로 계속, 같은 값은 오류를 건너서도 미방출, 셈은 한 번에 하나씩 트리거 순서로 — 실 DB 에서는 워치를 살린 채 셈만 실패시킬 수 없어 여기서 본다 |
| 클라이언트 `test/sync_status_test.dart` | `OfflineSyncStatus` 의 `isIdle`(건수 `null` 이면 거짓)·`needsAttention`(일시 실패 거짓·열기 거부 참)·`copyWith(clearLastFailure·clearUnsentRowCount)`·값 동등성 |
| 서버 모듈 `continuous_sync_interval_test.dart` | `initializeOfflineSync(continuousSyncInterval:)` 가 회차 사이 대기로 쓰이고(기본값 아님), 생략하면 200ms — zone `createTimer` 기록 |
| watch `sync_status_test.dart` | 오프라인 쓰기 행 단위 계수(동기화 전 삭제 포함)·동기화된 행의 오프라인 삭제·성공과 0건을 한 이벤트로·서버 작성 행 제외·재시작 복원(대조군)·K2 거부 시 유지·서버 병합 후 기기 실패 시 유지하고 재전송 없이 0·데이터를 잃은 서버 핸드셰이크로 전량 복귀·백업에서 복원한 서버의 더 낮은(null 아님) 체크포인트로 덮어쓰기·공유 space 까지 회차가 모두 확인·셈 도중 내려간 체크포인트 재검증(훅 `debugOnUnsentRowCheckpointsRead` — null 로 지운 경우·null 아닌 더 낮은 값·세 번 모두 내려가면 자기 행 전부(상한)로 폴백)·회차가 변경을 모으는 도중 커밋된 삽입·갱신이 유실되지 않음(회차 뒤 2건, 다음 회차에 둘 다 전송 — 수집 스냅샷. 첫 청크에서 멈춘 경우와 삽입·갱신 조회 사이에 커밋한 경우(훅 `debugOnPendingRowsRead`) 둘 다)·레지스트리가 바뀐 프로세스의 유휴 회차 재투영 0회(`debugProjectionRebuildCount`)·`watchUnsentRowCount`(구독 시·오프라인 쓰기·같은 값 미방출·회차 뒤 0)·셈 실패는 0 도 직전 값도 아닌 `null`·회차 전에 읽은 셈을 붙잡아도 성공 이벤트는 회차 뒤 셈(`unsentRowCounter`)·발행 순서와 합류 호출 1회 전송·실패 발행·연속 동기화 실패 기록·연속 동기화 정상 종료 시 재계수(워치 끔)·`dispose` |
| watch `continuous_sync_interval_test.dart` | `OfflineSyncDatabaseSession.wraps(continuousSyncInterval:)` 가 그 복제본의 대기로 쓰임 |

공용 하네스(`peerOf`·`errorOf`·`eventually`)는 `test/offline_sync_watch_test_client/test/support/sync_harness.dart` 에 있습니다.

> **하네스 한계**: `serverpod_test` 는 스트리밍 endpoint 의 오류를 원본 그대로 넘기므로, 실제 소켓에서
> `SerializableException` 이 아닌 예외가 사라지는 것을 재현하지 못합니다 — 그래서 매퍼가 메서드 스트림
> 메시지 왕복을 따로 단언합니다. watch 하네스는 두 복제본을 한 프로세스에서 직접 잇기 때문에, 기기
> iterator 가 서버 생성기를 `yield` 에서 멈춰 둡니다. 기기 병합이 실패한 회차에 서버가 기기 배치를 읽지
> 못하는 것은 이 하네스의 성질이며, WebSocket 에서는 다를 수 있습니다. 그래서 재전송 테스트는 WebSocket 쪽
> 경우를 `peerOf(holdServerDataUntil:)` 로 따로 강제합니다 — 서버는 back-pressure 없이 달리고, 기기는 서버가
> 기기 배치를 병합해 체크포인트를 남긴 뒤에야 서버 배치를 받습니다. 관측한 상태로 기대값을 고르지 마세요.
>
> 보낼 변경 수집의 스냅샷(unibook#14183)은 SQLite 에서는 쓰기 잠금이, PostgreSQL 에서는 `repeatable read` 가
> 만듭니다. 수집을 돌리는 테스트는 모두 SQLite 라서 **PostgreSQL 쪽 격리 수준 인자는 검증하지 않습니다** —
> 그 인자를 지운 변이는 전 테스트를 통과합니다(SQLite 는 `isolationLevel` 을 무시). 동기화 모델이 PostgreSQL
> 에 올라가는 단계(unibook#14186)에서 서버 수집 테스트로 메우세요.

> **로컬 재실행 주의**: 서버 모듈의 `untracked_update_test.dart`는 Serverpod 내장 PostgreSQL을 띄우는데,
> 테스트가 끝나도 그 프로세스가 남습니다(업스트림 Serverpod 4.0.0에서도 동일). 남은 프로세스가 있으면
> 다음 실행이 2분 뒤 `Serverpod did not start within the timeout`으로 실패합니다. 재실행 전에 정리하세요.
> CI는 매번 새 러너라 영향이 없습니다.
>
> ```bash
> pkill -INT -f 'offline_sync_updates_postgres_'
> rm -rf "${TMPDIR:-/tmp}"/offline_sync_updates_postgres_*
> ```

## 통합 테스트 (withServerpod + PostgreSQL)

`authenticate()` 전체 흐름을 **실 PostgreSQL 테스트 DB**에 대해 검증 — userinfo HTTP는 `MockClient`로 목킹, AuthUser/Account 생성·dedup을 실제 DB row로 확인.

### 사전 준비 (패키지별)

```bash
cd packages/serverpod_auth_idp_naver_server   # 또는 _kakao_server

# 1. 시크릿 파일 생성 (gitignore — 로컬 전용)
cp config/passwords.example.yaml config/passwords.yaml

# 2. serverpod 코드 생성 + 마이그레이션 (최초 1회)
dart pub get
serverpod generate
serverpod create-migration   # 이미 migrations/ 있으면 생략 가능

# 3. 테스트 DB 기동 (naver=9090, kakao=9092)
docker compose up -d postgres_test

# 4. 통합 테스트 실행 (withServerpod가 마이그레이션 자동 적용)
dart test test/integration
```

> **docker client/daemon API 불일치 시**: `DOCKER_API_VERSION=1.44 docker compose ...` / `DOCKER_API_VERSION=1.44 dart test ...`.

### 검증 범위

| 케이스 | 검증 |
|--------|------|
| 신규 사용자 | AuthUser + `{Provider}Account` row 생성, userIdentifier·email(소문자) 매핑 |
| 동일 id 재인증 | AuthUser 재사용(dedup), account row 1개 유지 |
| 이메일 미동의(Kakao) | email null 저장 |
| 미인증 세션 getAccount | null 반환 |

### 정리

```bash
docker compose down            # 컨테이너 중지
docker compose down -v         # 볼륨까지 삭제(DB 초기화)
```

## 현재 커버리지

| 패키지 | 단위 | 통합 | 합계 |
|--------|------|------|------|
| naver_server | 10 | 3 | 13 |
| kakao_server | 9 | 3 | 12 |
