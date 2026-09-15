# co-serverpod

[Serverpod](https://serverpod.dev) 인증 확장과 offline-first 동기화 패키지 모노레포입니다.
Kakao/Naver/Apple Identity Provider, 순수 Dart 동기화 코어, Flutter 클라이언트 어댑터를 제공합니다.

공식 `serverpod_auth_idp`는 Google·Apple·Email·Microsoft·GitHub·Facebook·Firebase·Passkey만 네이티브로 지원하고 **Kakao/Naver는 미지원**입니다. 본 모노레포는 공개 API(`IdentityProviderBuilder`, `OAuth2PkceUtil`, `AuthServices`)만으로 Kakao/Naver 두 provider를 custom 구현합니다 — Serverpod 코어 fork 불필요.
Apple 은 공식 provider 를 포팅하되, 공식이 검증하지 않는 `id_token` 의 `nonce` claim 을 검증(**nonce 리플레이 방지**)하도록 확장했습니다.

## 패키지

| 패키지 | 설명 |
|--------|------|
| [`co_offline_sync`](packages/co_offline_sync/README.md) | 순수 Dart 동기화 코어 — HLC·필드별 LWW·스키마 호환 창·서버/클라이언트 계약 |
| [`co_sync`](packages/co_sync/README.md) | Flutter + Drift 클라이언트 — 영속 저장·반응형 조회·생명주기 동기화·replica |
| [`serverpod_auth_idp_kakao_server`](packages/serverpod_auth_idp_kakao_server) | Kakao 로그인 서버 provider (OAuth2 authorization code + userinfo) |
| [`serverpod_auth_idp_kakao_flutter`](packages/serverpod_auth_idp_kakao_flutter) | Kakao 로그인 Flutter 클라이언트 컨트롤러/위젯 |
| [`serverpod_auth_idp_naver_server`](packages/serverpod_auth_idp_naver_server) | Naver 로그인 서버 provider (OAuth2 authorization code + userinfo) |
| [`serverpod_auth_idp_naver_flutter`](packages/serverpod_auth_idp_naver_flutter) | Naver 로그인 Flutter 클라이언트 컨트롤러/위젯 |
| [`serverpod_auth_idp_apple_server`](packages/serverpod_auth_idp_apple_server) | Apple 로그인 서버 provider (공식 포팅 + **nonce 리플레이 방지**) |
| [`serverpod_auth_idp_apple_client`](packages/serverpod_auth_idp_apple_client) | Apple 로그인 생성 클라이언트 (protocol/client) |

## 동기화 시작하기

Flutter 앱은 [클라이언트 사용법](packages/co_sync/README.md)을,
서버 연결과 커스텀 저장소는 [코어 사용법](packages/co_offline_sync/README.md)을 참고하세요.
두 문서에 설치, 동기화 예제, 스키마 버전 관리, 계정 정리와 저장소 계약을 설명합니다.

## 인증 방식

| | Kakao | Naver | Apple |
|---|---|---|---|
| 표준 OIDC `id_token` | ✅ 지원(옵션) | ❌ 미지원 | ✅ **필수** — 서버가 서명·audience·issuer·만료·**nonce** 검증 |
| **본 패키지 채택 방식** | **OAuth2 code → token → userinfo** | **OAuth2 code → token → userinfo** | **id_token 검증 (nonce 포함)** |
| token endpoint | `https://kauth.kakao.com/oauth/token` | `https://nid.naver.com/oauth2.0/token` | `https://appleid.apple.com/auth/token` (authorization code 교환 — 실패해도 `id_token` 검증이 끝났으면 로그인 진행) |
| userinfo | `https://kapi.kakao.com/v2/user/me` | `https://openapi.naver.com/v1/nid/me` | — (`id_token` claim 사용) |

> Kakao도 OAuth2 code flow로 통일하여 두 provider가 동일한 공개 API(`OAuth2PkceUtil`)만 사용합니다. Kakao OIDC `id_token` 직접 검증 경로는 `IdTokenVerifierConfig`가 idp 내부 비공개라 현재 미채택(향후 upstream export 시 옵션 추가 가능).

## 서버 등록

```dart
AuthServices.set(
  identityProviderBuilders: [
    // ... 기존 provider
    KakaoIdpConfigFromPasswords(),
    NaverIdpConfigFromPasswords(),
    AppleIdpConfigFromPasswords(),
  ],
);

// Apple S2S 알림(계정삭제/동의철회) 라우트 — AuthServices.set 이후, pod.start() 이전에.
pod.configureAppleIdpRoutes();
```

`config/passwords.yaml`:
```yaml
kakaoClientId: 'KAKAO_REST_API_KEY'
kakaoClientSecret: 'KAKAO_CLIENT_SECRET'   # Kakao 콘솔에서 활성화한 경우
naverClientId: 'NAVER_CLIENT_ID'
naverClientSecret: 'NAVER_CLIENT_SECRET'

# Apple — 공식 provider 와 키 이름이 동일하므로 마이그레이션 시 passwords.yaml 변경 불필요
appleServiceIdentifier: 'APPLE_SERVICE_ID'
appleBundleIdentifier: 'APP_BUNDLE_ID'
appleRedirectUri: 'https://api.example.com/auth/apple/callback'
appleTeamId: 'APPLE_TEAM_ID'
appleKeyId: 'APPLE_KEY_ID'
appleKey: '-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----'
# 선택 — Android 는 필수(누락 시 콜백 라우트가 500), 웹 콜백 라우트 사용 시 필수
appleAndroidPackageIdentifier: 'com.example.app'
appleWebRedirectUri: 'https://example.com/auth/apple/callback'
```

## Apple (nonce 리플레이 방지)

공식 provider 는 `verifyIdentityToken(nonce: null)` 로 `id_token` 의 `nonce` claim 을 검증하지 않습니다(보안감사 kobic#8594). 본 패키지는 같은 포팅본에서 클라이언트가 보낸 `nonce` 를 서버까지 전달해 `id_token` 의 claim 과 직접 비교합니다.

클라이언트 계약 — 표준 `sign_in_with_apple` 패턴:

```dart
final rawNonce = /* CSPRNG 32자 */;
// rawNonce 는 클라이언트 로컬 전용 — 어디에도 전송하지 않는다.
final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

final credential = await SignInWithApple.getAppleIDCredential(
  scopes: const [
    AppleIDAuthorizationScopes.email,
    AppleIDAuthorizationScopes.fullName,
  ],
  nonce: hashedNonce,             // Apple 이 id_token 의 nonce claim 으로 echo
  webAuthenticationOptions: webAuthOptions,
);

await client.modules.appleIdp.appleIdp.login(
  identityToken: credential.identityToken!,
  authorizationCode: credential.authorizationCode,
  isNativeApplePlatformSignIn: !kIsWeb && (Platform.isIOS || Platform.isMacOS),
  nonce: hashedNonce,             // 서버가 claim 과 직접 비교
  firstName: credential.givenName,
  lastName: credential.familyName,
);
```

- `nonce` 를 생략(`null`)하면 claim 검증을 건너뜁니다 — 마이그레이션 호환용이며, 신규 클라이언트는 **항상** 보내야 합니다.
- `nonce` 불일치 시 `sign_in_with_apple_server` 가 예외를 던져 로그인이 거부됩니다(계정 생성 전에 차단).
- 네이티브(iOS/macOS)·웹·Android·데스크톱 모두 동일하게 `nonce` 를 왕복합니다. 데스크톱은 플러그인이 없어 서버 콜백(`/auth/apple/callback`) bounce 로 `id_token` 을 받습니다.
- `authorizationCode` 교환은 refresh token 확보용 **best-effort** 입니다 — 웹의 구조적 `redirect_uri` 불일치(Apple JS SDK `usePopup` 제약) 등으로 실패해도 `id_token` 검증이 끝났으면 로그인은 진행됩니다.

> ⚠️ **테이블 이름**: 공식 provider 와 같은 `serverpod_auth_idp_server` 에 의존하므로 충돌을 피하기 위해 테이블이 `serverpod_auth_idp_apple_kr_account` 입니다(공식 `serverpod_auth_idp_apple_account`). 이관 시 `userIdentifier` 기준으로 기존 행을 복사해야 기존 Apple 사용자의 `AuthUser` 가 유지됩니다.

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
