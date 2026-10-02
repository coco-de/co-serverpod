# serverpod_offline_sync_server (co-serverpod 포크)

[serverpod_offline_sync](https://github.com/marcelomendoncasoares/serverpod_offline_sync)의 Serverpod
서버 모듈을 Serverpod 4.1용으로 포크한 패키지입니다. 동기화 endpoint, space 관리 API
(`session.offlineSync.spaces`), 서버 세션의 CRDT 데이터베이스 인터셉터를 제공합니다.

설치, `Model.db.watch` 사용법, 포크 기준과 변경점은
[`serverpod_offline_sync` README](../serverpod_offline_sync/README.md)를 참고하세요.

생성된 서버를 구성한 직후 `pod.initializeOfflineSyncWithSettings(syncTables: syncTables)`를
부르면 공용 `OfflineSyncSettings.boundedServer` 프리셋의 모든 설정을 함께 적용합니다.
개별 설정은 `settings: OfflineSyncSettings.boundedServer.copyWith(...)`로 바꿉니다.
생성된 서버가 사용하는 `offlineSyncDatabaseInterceptor`는 계속 필요합니다.

`session.offlineSync.schema`는 생성 모델에서 계산한 해시·테이블 목록을,
`session.offlineSync.settings`는 인터셉터와 스트림이 쓰는 실제 설정을 제공합니다.
모델을 바꿀 때 해시 사본을 수정할 필요는 없습니다. 서로 다른 스키마를 자동으로 호환시키지는 않습니다.

모듈 통합 테스트는 `config/test.yaml`의 SQLite 파일로 실행합니다. `untracked_update_test.dart`만
Serverpod 내장 PostgreSQL을 자동으로 띄우므로 별도 DB 서버는 필요 없습니다.

```bash
dart pub get
dart test --concurrency=1
```

내장 PostgreSQL 프로세스는 테스트가 끝나도 남습니다(업스트림도 동일). 로컬에서 다시 실행하기 전에
[테스트 가이드](../../docs/testing.md)의 정리 명령을 실행하세요.
