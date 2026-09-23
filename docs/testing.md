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
