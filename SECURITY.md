# 보안 정책 (Security Policy)

## 지원 버전

이 저장소의 패키지는 각자 버전을 갖습니다(`pubspec.yaml` 의 `version`, 릴리스는 GitHub Releases).
보안 수정은 각 패키지의 **가장 최근 릴리스**에 반영합니다.

## 취약점 신고

보안 취약점을 발견했다면 **공개 이슈 · PR · 토론에 올리지 말고** 저장소 관리자에게 비공개로 알려 주세요.

1. 이 저장소의 **Security 탭 → Advisories → Report a vulnerability**
   ([GitHub 비공개 보안 권고](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately))로
   신고합니다.
2. 위 버튼이 보이지 않으면, 취약점 내용은 적지 말고 비공개로 연락할 방법을 요청하는 이슈를 엽니다.
   관리자가 비공개 채널을 안내합니다.

신고에는 다음을 담아 주세요.

- 영향받는 패키지와 버전
- 재현 절차 또는 개념 증명
- 영향 범위, 알고 있다면 제안하는 완화 방법

신고에 **실제 서비스의 토큰 · 키 · 비밀번호 · 사용자 정보를 담지 마세요.** 재현에는 테스트용 값을 씁니다.
신고를 확인하면 회신하고, 수정과 릴리스 시점은 신고하신 분과 조율합니다.

## 범위

- 인증 공급자 서버 패키지(`serverpod_auth_idp_{kakao,naver,apple}_server`)와 클라이언트 패키지
- `serverpod_offline_sync` 포크 패키지
- 이 저장소의 CI 워크플로와 릴리스 설정

공급자(Kakao · Naver · Apple)나 Serverpod 자체의 취약점은 해당 프로젝트에 신고해 주세요.

---

## English summary

Please do not report security vulnerabilities through public issues, pull requests or discussions.
Use GitHub's private vulnerability reporting (**Security → Advisories → Report a vulnerability**).
If that option is not available, open an issue that asks for a private contact channel **without any
technical details**, and a maintainer will follow up privately. Security fixes are applied to the latest
release of each package.
