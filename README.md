# co-serverpod

[Serverpod](https://serverpod.dev) 인증 확장과 offline-first 동기화 패키지 모노레포입니다.
Kakao/Naver Identity Provider, 순수 Dart 동기화 코어, Flutter 클라이언트 어댑터를 제공합니다.

공식 `serverpod_auth_idp`는 Google·Apple·Email·Microsoft·GitHub·Facebook·Firebase·Passkey만 네이티브로 지원하고 **Kakao/Naver는 미지원**입니다. 본 모노레포는 공개 API(`IdentityProviderBuilder`, `OAuth2PkceUtil`, `AuthServices`)만으로 두 provider를 custom 구현합니다 — Serverpod 코어 fork 불필요.

## 패키지

| 패키지 | 설명 |
|--------|------|
| [`co_offline_sync`](packages/co_offline_sync/README.md) | 순수 Dart 동기화 코어 — HLC·필드별 LWW·스키마 호환 창·서버/클라이언트 계약 |
| [`co_sync`](packages/co_sync/README.md) | Flutter + Drift 클라이언트 — 영속 저장·반응형 조회·생명주기 동기화·replica |
| [`serverpod_auth_idp_kakao_server`](packages/serverpod_auth_idp_kakao_server) | Kakao 로그인 서버 provider (OAuth2 authorization code + userinfo) |
| [`serverpod_auth_idp_kakao_flutter`](packages/serverpod_auth_idp_kakao_flutter) | Kakao 로그인 Flutter 클라이언트 컨트롤러/위젯 |
| [`serverpod_auth_idp_naver_server`](packages/serverpod_auth_idp_naver_server) | Naver 로그인 서버 provider (OAuth2 authorization code + userinfo) |
| [`serverpod_auth_idp_naver_flutter`](packages/serverpod_auth_idp_naver_flutter) | Naver 로그인 Flutter 클라이언트 컨트롤러/위젯 |

## 동기화 시작하기

Flutter 앱은 [클라이언트 사용법](packages/co_sync/README.md)을,
서버 연결과 커스텀 저장소는 [코어 사용법](packages/co_offline_sync/README.md)을 참고하세요.
두 문서에 설치, 동기화 예제, 스키마 버전 관리, 계정 정리와 저장소 계약을 설명합니다.

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

동기화 패키지는 위 인증 workspace와 독립적으로 resolve합니다. 루트 bootstrap만으로
동기화 패키지의 의존성이 설치되지는 않습니다.

```bash
cd packages/co_offline_sync
dart pub get
dart test
cd ../co_sync
flutter pub get
flutter test test example
```

각 패키지의 pub get 후에는 루트에서 `melos run offline-sync:analyze`와
`melos run offline-sync:test`를 실행할 수도 있습니다.

## 라이선스

BSD-3-Clause © Cocode Inc.
