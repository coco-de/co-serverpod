# serverpod_offline_sync_client (co-serverpod 포크)

[serverpod_offline_sync](https://github.com/marcelomendoncasoares/serverpod_offline_sync)의 클라이언트
전송 어댑터를 Serverpod 4.1용으로 포크한 패키지입니다. 앱의 생성 클라이언트가 이 패키지에 의존하면
`client.createSyncSession(...)`과 `client.offlineSync.syncOnce`/`syncContinuously`를 쓸 수 있습니다.

설치, `Model.db.watch` 사용법, 포크 기준과 변경점은
[`serverpod_offline_sync` README](../serverpod_offline_sync/README.md)를 참고하세요.

모델별 해시·테이블 목록을 별도 공유 패키지에 복사하지 않으려면 공용 `OfflineSyncSchema`를
사용합니다. 설정도 `OfflineSyncSettings.boundedClient` 프리셋으로 일괄 적용할 수 있습니다.

```dart
final raw = await client.createSession(databasePath);
final session = OfflineSyncDatabaseSession.wrapsWithSettings(
  raw,
  syncTables: syncTables,
  persistentUserId: userId,
);
await session.db.initialize();
final schema = session.db.syncSchema;
// 사용이 끝나면 await session.close();
```

자세한 자동 메타데이터·설정·제품 규칙 경계는 공용 README의
[공유 상수 없이 사용하기](../serverpod_offline_sync/README.md#스키마--설정을-프로젝트별-공유-상수-없이-사용하기)를
참고하세요. 생성된 `createSyncSession`의 기본 동작은 그대로이며, 새 진입점에는 일반 `createSession`을 줍니다.
