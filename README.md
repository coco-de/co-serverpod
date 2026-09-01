# co-serverpod

[Serverpod](https://serverpod.dev) `serverpod_auth_idp`용 **한국 소셜(Kakao / Naver) Identity Provider** 패키지 모노레포.

공식 `serverpod_auth_idp`는 Google·Apple·Email·Microsoft·GitHub·Facebook·Firebase·Passkey만 네이티브로 지원하고 **Kakao/Naver는 미지원**입니다. 본 모노레포는 공개 API(`IdentityProviderBuilder`, `OAuth2PkceUtil`, `AuthServices`)만으로 두 provider를 custom 구현합니다 — Serverpod 코어 fork 불필요.

## 패키지

| 패키지 | 설명 |
|--------|------|
| [`serverpod_auth_idp_kakao_server`](packages/serverpod_auth_idp_kakao_server) | Kakao 로그인 서버 provider (OAuth2 authorization code + userinfo) |
| [`serverpod_auth_idp_kakao_flutter`](packages/serverpod_auth_idp_kakao_flutter) | Kakao 로그인 Flutter 클라이언트 컨트롤러/위젯 |
| [`serverpod_auth_idp_naver_server`](packages/serverpod_auth_idp_naver_server) | Naver 로그인 서버 provider (OAuth2 authorization code + userinfo) |
| [`serverpod_auth_idp_naver_flutter`](packages/serverpod_auth_idp_naver_flutter) | Naver 로그인 Flutter 클라이언트 컨트롤러/위젯 |

## 인증 방식

| | Kakao | Naver |
|---|---|---|
| 표준 OIDC `id_token` | ✅ 지원(옵션) | ❌ 미지원 |
| **본 패키지 채택 방식** | **OAuth2 code → token → userinfo** | **OAuth2 code → token → userinfo** |
| token endpoint | `https://kauth.kakao.com/oauth/token` | `https://nid.naver.com/oauth2.0/token` |
| userinfo | `https://kapi.kakao.com/v2/user/me` | `https://openapi.naver.com/v1/nid/me` |

> Kakao도 OAuth2 code flow로 통일하여 두 provider가 동일한 공개 API(`OAuth2PkceUtil`)만 사용합니다. Kakao OIDC `id_token` 직접 검증 경로는 `IdTokenVerifierConfig`가 idp 내부 비공개라 현재 미채택(향후 upstream export 시 옵션 추가 가능).

## 서버 등록

```dart
AuthServices.set(
  identityProviderBuilders: [
    // ... 기존 provider
    KakaoIdpConfigFromPasswords(),
    NaverIdpConfigFromPasswords(),
  ],
);
```

`config/passwords.yaml`:
```yaml
kakaoClientId: 'KAKAO_REST_API_KEY'
kakaoClientSecret: 'KAKAO_CLIENT_SECRET'   # Kakao 콘솔에서 활성화한 경우
naverClientId: 'NAVER_CLIENT_ID'
naverClientSecret: 'NAVER_CLIENT_SECRET'
```

## 개발

```bash
dart pub global activate melos
melos bootstrap
melos run generate   # serverpod 모델/엔드포인트 코드 생성
melos run analyze
melos run test
```

## 라이선스

BSD-3-Clause © Cocode Inc.
