# Serverpod 버전 호환성

## 요약

현재 지원 범위는 **Serverpod `^4.1.0`** 입니다. 인증 패키지 8개와 `serverpod_offline_sync` 포크 3개가 모두 같은 범위를 씁니다.

| | 버전 | 비고 |
|---|------|------|
| 본 패키지 의존 | `serverpod ^4.1.0`, `serverpod_auth_idp_server ^4.1.0`, `serverpod_auth_core_server ^4.1.0` (pub.dev stable) | 독립 개발/배포 기준 |
| 본 패키지 검증 | serverpod_cli **4.1.0** 로 `dart pub get` + `serverpod generate`(재실행 드리프트 0) + `dart analyze --fatal-infos`(0 issue) + 단위 테스트(19 green) | ✅ |
| 소비처(kobic) | serverpod **3.5.0-beta.9** (git ref `435fb29`) | dependency_overrides로 통합 — 2026-06 당시 기록 |

> 이 아래 본문은 3.x 시기(Kakao/Naver 최초 도입)에 남긴 호환성 검증 기록이라 그대로 보존합니다.
> 현재 지원 범위는 위 요약을 따릅니다.

## 왜 3.4.8(stable)을 타깃하는가

재사용 가능한 공개 패키지는 **stable**을 타깃하는 것이 표준입니다. pub.dev에 publish 가능하고, 특정 베타에 고정되지 않습니다.

## beta.9(kobic)와 호환되는 근거

### 1. API 호환 — 구성상 보장(proven by construction)
provider 구현은 **kobic이 사용하는 바로 그 serverpod git ref(`435fb29`, = 3.5.0-beta 계열) 소스의 `github` provider를 미러링**해 작성했습니다. 따라서 사용하는 모든 공개 API가 beta.9에 **존재가 보장**됩니다:

- `IdentityProviderBuilder<T>` / `AuthServices`
- `OAuth2PkceUtil`, `OAuth2PkceServerConfig`, `OAuth2PkceTokenResponse`, `OAuth2*Exception`
- `AuthUsers.create/get`, `UserProfiles.createUserProfile/setUserImageFromUrl`
- `TokenIssuer.issueToken`, `AuthSuccess`, `AuthUserModel`, `UserProfileData`, `UserImageFromUrl`

동일한 코드가 **3.4.8 stable에서도** `serverpod generate` + `analyze`(0건) + `test`(19건) 통과 → 본 패키지가 의존하는 공개 API 표면은 **3.4.8 ↔ beta.9에서 동일**합니다.

### 2. 소스는 버전 비종속
패키지 `lib/` 소스는 위 안정적 공개 API만 사용합니다. 생성 코드(`lib/src/generated/**`, client `lib/src/protocol/**`)만 serverpod 버전에 종속됩니다.

### 3. 생성 코드는 소비처 버전으로 재생성
kobic에 통합되면 kobic의 `serverpod generate`(= beta.9 CLI)가 모듈 protocol을 **beta.9에 맞춰 재생성**합니다. 저장소에 커밋된 3.4.8 기준 생성 코드는 독립 사용/참조용입니다.

## kobic(beta.9) 통합 방법

kobic은 git ref serverpod를 쓰므로, kakao/naver 패키지를 추가할 때 **`dependency_overrides`로 serverpod 계열을 동일 git ref로 정렬**합니다. (git ref serverpod 프로젝트가 serverpod 의존 패키지를 소비하는 표준 패턴 — `^3.4.8` 제약은 override가 우회)

```yaml
# kobic 의 pubspec.yaml
dependencies:
  serverpod_auth_idp_kakao_server:
    git:
      url: https://github.com/coco-de/serverpod-auth-kr.git
      path: packages/serverpod_auth_idp_kakao_server
  serverpod_auth_idp_naver_server:
    git: { url: ..., path: packages/serverpod_auth_idp_naver_server }

dependency_overrides:
  # kobic 이 이미 쓰는 serverpod git ref 로 정렬 (예시 — 실제 ref 는 kobic 기준)
  serverpod:
    git: { url: https://github.com/serverpod/serverpod, ref: <kobic-ref>, path: packages/serverpod }
  serverpod_auth_idp_server:
    git: { url: ..., ref: <kobic-ref>, path: modules/serverpod_auth/serverpod_auth_idp/serverpod_auth_idp_server }
  serverpod_auth_core_server:
    git: { url: ..., ref: <kobic-ref>, path: modules/serverpod_auth/serverpod_auth_core/serverpod_auth_core_server }
  # client 측도 동일하게 정렬
```

통합 후 kobic 루트에서 `serverpod generate` 1회 → 모든 모듈 protocol이 beta.9 기준으로 재생성됩니다.

## beta.9 소스 호환 검증 결과 (2026-06-04, #6521)

`pubspec_overrides.yaml`(dev 전용, gitignore)로 양 server 패키지의 serverpod 계열을 **3.5.0-beta.9**(kobic 버전, pub.dev hosted)로 강제 후 검증:

```yaml
dependency_overrides:
  serverpod: 3.5.0-beta.9
  serverpod_auth_idp_server: 3.5.0-beta.9
  serverpod_auth_core_server: 3.5.0-beta.9
  serverpod_serialization: 3.5.0-beta.9
  serverpod_test: 3.5.0-beta.9
```

| 패키지 | `dart pub get` (beta.9) | `dart analyze lib` | 단위 테스트 |
|--------|------------------------|--------------------|------------|
| naver_server | ✅ 해석 | ✅ **0건** | ✅ **10/10** |
| kakao_server | ✅ 해석 | ✅ **0건** | ✅ **9/9** |

→ **우리 손으로 작성한 provider 소스(idp/config/utils/endpoint/profile)는 serverpod 3.5.0-beta.9에서 컴파일·동작 확인.** 공개 API 표면(`IdentityProviderBuilder`/`OAuth2PkceUtil`/`AuthUsers`/`TokenIssuer`/`UserProfiles`)이 3.4.8 ↔ beta.9 동일함이 실측으로 확인됨.

> 모든 serverpod_auth_* 패키지가 pub.dev에 **3.5.0-beta.9로 발행**되어 있어(serverpod/idp_server/core_server/idp_client/core_client/serverpod_test) git ref 없이 hosted 버전 override만으로 검증 가능. kobic도 hosted beta.9 사용(git ref 아님).

### 잔여 (Phase 2)

- **generated 코드** 는 소비처(kobic)의 beta.9 `serverpod_cli`가 재생성(`serverpod generate`) — 본 검증은 `analyze`에서 generated 제외(source 한정). 통합/withServerpod 테스트의 beta.9 재실행은 beta.9 cli regen 후 (Story #6522).
- **실 OAuth 라운드트립 E2E** 는 콘솔 키 + 디바이스 필요 (Story #6521 잔여 AC).

## 체크리스트 (Phase 2 통합)

- [ ] kobic pubspec 에 kakao/naver server+client+flutter 패키지 git 의존 추가
- [ ] `dependency_overrides` 로 serverpod / serverpod_auth_idp_server / serverpod_auth_core_server (+ client) 를 kobic git ref 로 정렬
- [ ] `serverpod generate`(kobic) 재실행 → 모듈 protocol beta.9 재생성
- [ ] `AuthServices.set(identityProviderBuilders: [..., KakaoIdpConfigFromPasswords(), NaverIdpConfigFromPasswords()])`
- [ ] `melos run analyze` + 통합 테스트
