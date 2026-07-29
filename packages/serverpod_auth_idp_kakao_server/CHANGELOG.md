# Changelog

## [1.0.0](https://github.com/coco-de/serverpod-auth-kr/compare/serverpod_auth_idp_kakao_server-v0.2.0...serverpod_auth_idp_kakao_server-v1.0.0) (2026-07-29)


### ⚠ BREAKING CHANGES

* **serverpod:** serverpod 4.0.0-beta.1 이상을 요구한다. 소비 측은 serverpod 계열 의존을 함께 올려야 한다.

### 기능

* **serverpod:** ⬆️ serverpod 4.0.0-beta.1 대응 — 생성 코드 재생성 ([#6](https://github.com/coco-de/serverpod-auth-kr/issues/6)) ([1266bd9](https://github.com/coco-de/serverpod-auth-kr/commit/1266bd9740716a05bdf2a10e541790c72d5e7c34))

## [0.2.0](https://github.com/coco-de/serverpod-auth-kr/compare/serverpod_auth_idp_kakao_server-v0.1.0...serverpod_auth_idp_kakao_server-v0.2.0) (2026-07-21)


### 기능

* ✨ flutter 패키지 연동 — 네이티브 SDK access token 플로우 ([b506f7c](https://github.com/coco-de/serverpod-auth-kr/commit/b506f7c364c93471c5b78bcd7285a475c4494f86))
* ✨ serverpod_auth_idp kakao/naver custom provider 스캐폴딩 ([eba33d7](https://github.com/coco-de/serverpod-auth-kr/commit/eba33d750021189689d016021cb915775e1377a9))
* 🔧 serverpod generate 활성화 + 양 server 패키지 컴파일 통과 ([54256e6](https://github.com/coco-de/serverpod-auth-kr/commit/54256e6ebe7dabc2ad95750e5a3c365ee70c4916))
* **apple:** 🔒 Apple identity provider with nonce replay protection ([#2](https://github.com/coco-de/serverpod-auth-kr/issues/2)) ([3e5a2c6](https://github.com/coco-de/serverpod-auth-kr/commit/3e5a2c641a05b5f7ff073fcf22df7d152095a80e))


### 버그 수정

* 🐛 server barrel 에 generated Endpoints 디스패처 export ([#6522](https://github.com/coco-de/serverpod-auth-kr/issues/6522)) ([b5bfbf7](https://github.com/coco-de/serverpod-auth-kr/commit/b5bfbf770e8453746ee0374a9c44944c04400aca))

## 0.1.0

- Initial scaffold of the Kakao identity provider for `serverpod_auth_idp`.
- OAuth2 authorization code flow with PKCE (`code` + `codeVerifier`).
- `KakaoIdpConfig` / `KakaoIdpConfigFromPasswords` configuration.
- `KakaoIdp.login` flow: token exchange → authenticate → user profile creation → token issuance.
- `KakaoIdpEndpoint` exposing `login` and `hasAccount`.
- `KakaoAccount` model (`serverpod_auth_idp_kakao_account`).
