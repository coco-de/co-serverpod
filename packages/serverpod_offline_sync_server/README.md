# serverpod_offline_sync_server (co-serverpod 포크)

[serverpod_offline_sync](https://github.com/marcelomendoncasoares/serverpod_offline_sync)의 Serverpod
서버 모듈을 Serverpod 4.1용으로 포크한 패키지입니다. 동기화 endpoint, space 관리 API
(`session.offlineSync.spaces`), 서버 세션의 CRDT 데이터베이스 인터셉터를 제공합니다.

설치, `Model.db.watch` 사용법, 포크 기준과 변경점은
[`serverpod_offline_sync` README](../serverpod_offline_sync/README.md)를 참고하세요.

모듈 통합 테스트는 `config/test.yaml`의 SQLite 파일로 실행합니다. `untracked_update_test.dart`만
Serverpod 내장 PostgreSQL을 자동으로 띄우므로 별도 DB 서버는 필요 없습니다.

```bash
dart pub get
dart test --concurrency=1
```

내장 PostgreSQL 프로세스는 테스트가 끝나도 남습니다(업스트림도 동일). 로컬에서 다시 실행하기 전에
[테스트 가이드](../../docs/testing.md)의 정리 명령을 실행하세요.
