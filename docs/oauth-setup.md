# OAuth 앱 설정 가이드 (Kakao / Naver)

`serverpod_auth_idp_kakao` / `serverpod_auth_idp_naver` 를 사용하려면 각 소셜 개발자 콘솔에 OAuth 애플리케이션을 등록하고 키·redirect URI·동의 항목을 설정해야 합니다.

> ⚠️ 콘솔 앱 생성·키 발급은 **각 플랫폼 계정 로그인이 필요**한 수동 작업입니다. 이 문서는 정확한 설정 값과 절차를 정의합니다.

---

## 0. 인증 플로우 선택 (중요)

서버 provider 는 두 가지 로그인을 모두 제공합니다.

```
A. client → (브라우저/SDK로 authorization code 획득)
          → endpoint.login(code, codeVerifier, redirectUri)
          → server: code → access_token 교환 → userinfo 조회 → AuthUser/세션

B. client → (네이티브 SDK 가 access token 을 직접 반환)
          → endpoint.loginWithAccessToken(accessToken)
          → server: userinfo 조회 → AuthUser/세션
```

| 플로우 | 클라이언트가 서버로 보내는 것 | 서버 동작 | 적합 |
|--------|------------------------------|-----------|------|
| **A. Authorization Code** (`login`) | `code` + `codeVerifier` + `redirectUri` | 서버가 자기 클라이언트 자격 증명으로 code→token 교환 + userinfo | 웹 OAuth, PKCE, REST 흐름. **가능하면 이쪽을 권장** |
| **B. Access Token** (`loginWithAccessToken`) | `accessToken` (네이티브 SDK가 직접 반환) | userinfo 로 토큰 확인 | `kakao_flutter_sdk`, `flutter_naver_login` 네이티브 로그인 (flutter 패키지가 이 플로우를 씁니다) |

`kakao_flutter_sdk_user` · `flutter_naver_login` 네이티브 로그인은 보통 access token 을 직접 반환하므로 플로우 B 를 씁니다.
플로우 B 를 쓰지 않는 앱은 provider 별 선택 설정으로 범위를 좁힐 수 있습니다.

| provider | 설정 | 기본값 | 효과 |
|---|---|---|---|
| Kakao | `expectedAppId` (`passwords.yaml` 의 `kakaoAppId`) | `null` (끔) | 플로우 B 에서 Kakao 토큰 정보 API(`/v1/user/access_token_info`)의 `app_id` 가 이 값과 같을 때만 진행 |
| Naver | `allowAccessTokenLogin` | `true` | `false` 면 플로우 B 를 거부하고 플로우 A 만 허용 |

아래 redirect URI 설정은 **플로우 A** 기준입니다. 플로우 B만 쓸 경우 redirect URI는 SDK 기본값을 따릅니다.

---

## 1. Kakao (Kakao Developers)

콘솔: https://developers.kakao.com

### 1-1. 앱 생성
1. **내 애플리케이션 → 애플리케이션 추가하기** → 앱 이름/회사명 입력.
2. **요약 정보 → 앱 키**에서 **REST API 키** 확인 → 서버 `kakaoClientId`로 사용.
3. (선택) **요약 정보**의 **앱 ID**(숫자) → 서버 `kakaoAppId`로 사용. 설정하면 `loginWithAccessToken` 이 이 앱에 발급된 토큰만 받습니다. REST API 키와 다른 값입니다.

### 1-2. 카카오 로그인 활성화
1. **카카오 로그인 → 활성화 설정 ON**.
2. **Redirect URI 등록** (플로우 A): 서버/클라이언트가 사용할 콜백. 예:
   - 앱(딥링크): `kobic://oauth/kakao`
   - 웹: `https://<도메인>/auth/kakao/callback`
   - 로컬 개발: `http://localhost:8082/auth/kakao/callback`
   > 클라이언트가 `endpoint.login(redirectUri:)`로 보내는 값과 **정확히 일치**해야 합니다.

### 1-3. 동의 항목 (카카오 로그인 → 동의항목)
| 항목 | 설정 | 매핑 |
|------|------|------|
| 닉네임 (`profile_nickname`) | 필수/선택 | `name` |
| 프로필 사진 (`profile_image`) | 선택 | `image` |
| 카카오계정(이메일) (`account_email`) | 선택 (검수 필요) | `email` (없으면 null) |

> 이메일은 비즈 앱 전환 + 검수가 필요할 수 있습니다. 미동의 시 `email`은 null — provider가 정상 처리합니다.

### 1-4. Client Secret (선택)
- **카카오 로그인 → 보안 → Client Secret** 활성화 시 코드 발급 → 서버 `kakaoClientSecret`로 사용.
- 비활성화면 `kakaoClientSecret` 생략(서버 config가 nullable 처리).

### 1-5. (참고) OpenID Connect
- Kakao는 OIDC `id_token`도 지원하나, 본 패키지는 **OAuth2 code 플로우**를 사용하므로 OIDC 활성화 불필요.

---

## 2. Naver (Naver Developers)

콘솔: https://developers.naver.com

### 2-1. 앱 등록
1. **Application → 애플리케이션 등록**.
2. **사용 API**: "네이버 로그인" 선택.
3. **제공 정보 선택** (필수/추가):
   | 항목 | 매핑 |
   |------|------|
   | 이름 (`name`) | `name` |
   | 이메일 주소 (`email`) | `email` (없으면 null) |
   | 프로필 사진 (`profile_image`) | `image` |
4. 등록 후 **Client ID** / **Client Secret** 발급 → 서버 `naverClientId` / `naverClientSecret`.

### 2-2. Callback URL (플로우 A)
- **로그인 오픈 API 서비스 환경 → 서비스 URL / Callback URL** 등록. 예:
  - 웹: `https://<도메인>/auth/naver/callback`
  - 로컬: `http://localhost:8082/auth/naver/callback`
  - 앱(딥링크): `kobic://oauth/naver`
- 클라이언트 `endpoint.login(redirectUri:)`와 일치.

### 2-3. PKCE 참고
- Naver는 PKCE를 공식 문서화하지 않음. 서버 `exchangeCodeForToken`은 `codeVerifier`를 **nullable**로 받아 빈 값 허용(clientSecret 기반 confidential 교환). 클라이언트는 `state` 기반 CSRF 방어 사용.

---

## 3. 서버 시크릿 (`config/passwords.yaml`)

```yaml
# Kakao
kakaoClientId: '<카카오 REST API 키>'
kakaoClientSecret: '<카카오 Client Secret>'   # Client Secret 활성화한 경우만
kakaoAppId: '<카카오 앱 ID(숫자)>'             # 선택 — 플로우 B 의 발급 앱 확인. 생략하면 확인 안 함

# Naver
naverClientId: '<네이버 Client ID>'
naverClientSecret: '<네이버 Client Secret>'
```

> 실제 값이 든 `passwords.yaml` 은 커밋하지 않습니다. 프로덕션은 SSM/Secrets Manager 등으로 주입.

## 4. 서버 등록 코드

```dart
// server.dart 부트스트랩
AuthServices.set(
  identityProviderBuilders: [
    // ... 기존 provider
    KakaoIdpConfigFromPasswords(),  // kakaoClientId/Secret 읽음
    NaverIdpConfigFromPasswords(),  // naverClientId/Secret 읽음
  ],
);
```

## 5. 설정 체크리스트

- [ ] Kakao 앱 생성 + REST API 키 확보
- [ ] Kakao 로그인 활성화 + Redirect URI 등록 + 동의항목(닉네임/프로필사진/이메일)
- [ ] (선택) Kakao Client Secret 활성화
- [ ] Naver 앱 등록 + Client ID/Secret 확보 + 제공정보(이름/이메일/프로필사진)
- [ ] Naver Callback URL 등록
- [ ] `passwords.yaml`에 4개 키 입력 (프로덕션은 시크릿 매니저)
- [ ] redirect URI = 클라이언트 `login(redirectUri:)` 값과 일치
- [ ] (플로우 B 사용 시) Kakao 앱 ID 를 `kakaoAppId` 로 넣을지, Naver 에서 플로우 B 를 막을지(`allowAccessTokenLogin`) 결정
