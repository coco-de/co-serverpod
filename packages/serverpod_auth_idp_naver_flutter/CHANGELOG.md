# Changelog

## [0.2.0](https://github.com/coco-de/serverpod-auth-kr/compare/serverpod_auth_idp_naver_flutter-v0.1.0...serverpod_auth_idp_naver_flutter-v0.2.0) (2026-07-21)


### 기능

* ✨ flutter 패키지 연동 — 네이티브 SDK access token 플로우 ([b506f7c](https://github.com/coco-de/serverpod-auth-kr/commit/b506f7c364c93471c5b78bcd7285a475c4494f86))
* ✨ SDK SignInService 참조 구현 + E2E 런북 ([#6521](https://github.com/coco-de/serverpod-auth-kr/issues/6521)) ([9f54b2b](https://github.com/coco-de/serverpod-auth-kr/commit/9f54b2bcd59ac098a4bb8f61b6d920ef72daab13))
* ✨ serverpod_auth_idp kakao/naver custom provider 스캐폴딩 ([eba33d7](https://github.com/coco-de/serverpod-auth-kr/commit/eba33d750021189689d016021cb915775e1377a9))
* **apple:** 🔒 Apple identity provider with nonce replay protection ([#2](https://github.com/coco-de/serverpod-auth-kr/issues/2)) ([3e5a2c6](https://github.com/coco-de/serverpod-auth-kr/commit/3e5a2c641a05b5f7ff073fcf22df7d152095a80e))

## 0.1.0

- 초기 스켈레톤 릴리스.
- `NaverAuthController`: GitHub 정본 컨트롤러를 미러링한 인증 플로우 컨트롤러
  (SDK / 엔드포인트 호출부는 TODO 주석 + 시그니처로 표기).
- `NaverSignInButton`: Naver 브랜드 녹색(#03C75A) + 흰색 텍스트 버튼 위젯.
