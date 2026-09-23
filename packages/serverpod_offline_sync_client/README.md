# serverpod_offline_sync_client (co-serverpod 포크)

[serverpod_offline_sync](https://github.com/marcelomendoncasoares/serverpod_offline_sync)의 클라이언트
전송 어댑터를 Serverpod 4.1용으로 포크한 패키지입니다. 앱의 생성 클라이언트가 이 패키지에 의존하면
`client.createSyncSession(...)`과 `client.offlineSync.syncOnce`/`syncContinuously`를 쓸 수 있습니다.

설치, `Model.db.watch` 사용법, 포크 기준과 변경점은
[`serverpod_offline_sync` README](../serverpod_offline_sync/README.md)를 참고하세요.
