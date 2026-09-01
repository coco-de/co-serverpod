# Changelog

## [2.0.2](https://github.com/coco-de/co-serverpod/compare/serverpod_auth_idp_apple_server-v2.0.1...serverpod_auth_idp_apple_server-v2.0.2) (2026-09-01)


### 버그 수정

* **apple:** 🐛 웹 신규 로그인도 authorization code 교환 실패를 non-fatal 로 처리 ([#16](https://github.com/coco-de/co-serverpod/issues/16)) ([e2900b9](https://github.com/coco-de/co-serverpod/commit/e2900b99de887e4890342bb49091062867e4c735))


### 문서

* 📝 레포 이름 변경(serverpod-auth-kr → co-serverpod) 반영 ([#12](https://github.com/coco-de/co-serverpod/issues/12)) ([5d2ede7](https://github.com/coco-de/co-serverpod/commit/5d2ede7f5c27076bbeb75dcc33f3bff10eb123bb))

## [2.0.1](https://github.com/coco-de/serverpod-auth-kr/compare/serverpod_auth_idp_apple_server-v2.0.0...serverpod_auth_idp_apple_server-v2.0.1) (2026-08-31)


### 버그 수정

* **apple:** 🐛 네이티브 iOS/macOS 신규 로그인 redirect_uri mismatch 수정 ([#10](https://github.com/coco-de/serverpod-auth-kr/issues/10)) ([847620c](https://github.com/coco-de/serverpod-auth-kr/commit/847620c4a2c01192f4bd13d7f59fa29f71304fa0))

## [2.0.0](https://github.com/coco-de/serverpod-auth-kr/compare/serverpod_auth_idp_apple_server-v1.0.0...serverpod_auth_idp_apple_server-v2.0.0) (2026-08-12)


### ⚠ BREAKING CHANGES

* **serverpod:** ⬆️ serverpod 4.0.0-beta.2 대응 — IdentityProvider 계약 구현 ([#8](https://github.com/coco-de/serverpod-auth-kr/issues/8))

### 기능

* **serverpod:** ⬆️ serverpod 4.0.0-beta.2 대응 — IdentityProvider 계약 구현 ([#8](https://github.com/coco-de/serverpod-auth-kr/issues/8)) ([db72656](https://github.com/coco-de/serverpod-auth-kr/commit/db7265643c8e34aa7a81f0986a7014096718adc4))

## [1.0.0](https://github.com/coco-de/serverpod-auth-kr/compare/serverpod_auth_idp_apple_server-v0.2.0...serverpod_auth_idp_apple_server-v1.0.0) (2026-07-29)


### ⚠ BREAKING CHANGES

* **serverpod:** serverpod 4.0.0-beta.1 이상을 요구한다. 소비 측은 serverpod 계열 의존을 함께 올려야 한다.

### 기능

* **serverpod:** ⬆️ serverpod 4.0.0-beta.1 대응 — 생성 코드 재생성 ([#6](https://github.com/coco-de/serverpod-auth-kr/issues/6)) ([1266bd9](https://github.com/coco-de/serverpod-auth-kr/commit/1266bd9740716a05bdf2a10e541790c72d5e7c34))

## [0.2.0](https://github.com/coco-de/serverpod-auth-kr/compare/serverpod_auth_idp_apple_server-v0.1.0...serverpod_auth_idp_apple_server-v0.2.0) (2026-07-21)


### 기능

* **apple:** 🔒 Apple identity provider with nonce replay protection ([#2](https://github.com/coco-de/serverpod-auth-kr/issues/2)) ([3e5a2c6](https://github.com/coco-de/serverpod-auth-kr/commit/3e5a2c641a05b5f7ff073fcf22df7d152095a80e))
