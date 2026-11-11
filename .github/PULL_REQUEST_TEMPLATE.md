## 요약

<!-- 무엇을 왜 바꿨는지 한두 문장. -->

## 변경 내용

-

## 검증

<!-- 실행한 검사와 결과. 못 돌린 것은 이유와 함께 적습니다. -->

- [ ] 변경한 패키지의 `dart format --output=none --set-exit-if-changed .` · `dart analyze --fatal-infos`
- [ ] 변경한 패키지의 `dart test` (DB 통합 테스트는 `docs/testing.md` 참고)

## 체크리스트

- [ ] 커밋 메시지가 Conventional Commits 를 따릅니다. `feat` · `fix` · `!`(BREAKING CHANGE)는 릴리스
      버전을 올리므로 타입을 정확히 씁니다(release-please).
- [ ] 동작이 바뀌는 변경은 기본값이 기존 동작을 유지하거나, 깨지는 변경이면 `!` 로 표시했습니다.
- [ ] 이 저장소는 **공개**입니다. 비밀 값 · 토큰 · 개인 경로 · 내부 시스템 식별자를 코드 · 문서 ·
      커밋 메시지 · PR 에 넣지 않았습니다.
- [ ] 워크플로를 바꿨다면 외부 액션을 태그가 아니라 40자리 커밋 SHA 로 고정했습니다.
- [ ] 보안 취약점은 PR 이 아니라 [SECURITY.md](../SECURITY.md) 의 비공개 경로로 신고했습니다.
