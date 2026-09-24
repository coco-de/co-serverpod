# serverpod_offline_sync (co-serverpod 포크)

[marcelomendoncasoares/serverpod_offline_sync](https://github.com/marcelomendoncasoares/serverpod_offline_sync)를
**Serverpod 4.1**용으로 포크한 패키지입니다. 생성된 `Model.db.watch(session, ...)`가 동기화 세션에서도
drift의 `watch()`처럼 로컬 쓰기와 동기화 병합을 화면에 자동으로 반영합니다.

| 패키지 | 역할 |
|---|---|
| `serverpod_offline_sync` | 공용 CRDT 엔진·모델 (watch 패치 위치) |
| [`serverpod_offline_sync_client`](../serverpod_offline_sync_client/README.md) | 생성 클라이언트용 동기화 전송 |
| [`serverpod_offline_sync_server`](../serverpod_offline_sync_server/README.md) | Serverpod 서버 모듈 |

엔진 자체의 개념(space, 충돌 처리, 모델링 제약, 예약 값)은 기준 커밋의
[업스트림 README](https://github.com/marcelomendoncasoares/serverpod_offline_sync/blob/96271a25ab22c44dd3d94c6cd3fe910f63354609/README.md)와
[설계 문서](https://github.com/marcelomendoncasoares/serverpod_offline_sync/tree/96271a25ab22c44dd3d94c6cd3fe910f63354609/docs)를 따릅니다.
업스트림 README에는 "not yet ready for production use"라고 적혀 있습니다.

## 왜 포크인가

- 업스트림 0.0.8은 Serverpod `4.0.0`을 정확히 고정합니다. 4.1.0-beta.1에서 `Database`에 추가된
  `watch`/`unsafeWatch`를 구현하지 않아서, 4.1에서는 **컴파일되지 않습니다**
  (`OfflineSyncDatabase implements Database`).
- `watch`를 내부 DB에 그대로 넘기면 **삭제가 화면에 반영되지 않습니다.** 로컬 삭제와 병합된 tombstone은
  도메인 행을 건드리지 않고 `crdt_data_rows`·`crdt_data_tombstone`에만 씁니다. 가시성 필터는 raw SQL
  `Expression`이라 Serverpod가 트리거 테이블로 수집하지도 않습니다.

- 앱이 의존하는 **포크 전용 API·동작**이 늘었습니다(업스트림에 없음). 시계 오차 허용치 설정(`maxClockDrift`,
  unibook#14182), 와이어 실패 코드와 분류기(`OfflineSyncRemoteException`·`offlineSyncWireErrors`·
  `OfflineSyncFailure`, unibook#14182), 동기화 상태와 미전송 건수(`OfflineSyncStatusTracker`·
  `unsentRowCount`·`watchUnsentRowCount`, 그 근거인 기기의 서버 확인 체크포인트 기록, unibook#14183)입니다.
  목록은 [변경점 표](#업스트림-기준과-변경점)가 정본입니다.

그래서 업스트림이 Serverpod 4.1과 watch를 지원하는 것만으로는 이 포크를 지울 수 없습니다. 위 포크 전용 API·동작의
대응물이 업스트림에 생기거나 업스트림에 넣은 뒤에 pub 패키지로 돌아갑니다([포크 제거](#포크-제거)).

## 업스트림 기준과 변경점

기준 커밋은 [`96271a2`](https://github.com/marcelomendoncasoares/serverpod_offline_sync/commit/96271a25ab22c44dd3d94c6cd3fe910f63354609)입니다.
0.0.8 이후 미릴리스 수정(#147·#148·#151·#152)을 포함합니다. 라이선스는 업스트림 BSD-3-Clause
(`LICENSE`)를 그대로 유지합니다. 업스트림 대비 변경은 다음이 전부입니다.

| 대상 | 변경 |
|---|---|
| `lib/src/database/database.dart` | `watch`·`unsafeWatch` 구현, 트리거 테이블 수집·include 복원 헬퍼 |
| `lib/src/generated/**` | CLI 4.1.0-beta.1로 재생성. 테이블 저장소마다 `watch`가 추가되고 삭제된 줄은 없음. 아래 새 모델 2개(`sync/failure_code.dart`·`sync/remote_exception.dart`)와 그 `protocol.dart` 등록(import·export·역직렬화 분기)도 재생성 산출물 |
| 세 패키지 `pubspec.yaml` | Serverpod `^4.1.0-beta.1`, 형제 path 의존, 워크스페이스 해제, `publish_to: none` |
| 세 패키지 `analysis_options.yaml` | 업스트림 루트 린트를 `analysis_options.upstream.yaml`로 옮겨 include |
| `README.md`·`CHANGELOG.md` | 업스트림 루트를 가리키던 심볼릭 링크를 실제 파일로 교체 |
| `lib/src/hlc/hlc.dart` | 시계 오차 허용치: 업스트림의 1분 고정(`_maxDrift` + `increment` 의 `Duration(minutes: 1)` 리터럴)을 `Hlc.defaultMaxDrift`(**1시간**)와 `increment`·`merge` 의 `maxDrift` 인자로 교체. 검사 구조(로컬 역행 검사 포함)는 그대로. 자기 노드 스탬프를 같은 한도로 받는 `adoptOwn` 신설 ([시계 오차](#시계-오차-허용치와-동기화-실패-분류)) |
| `lib/src/hlc/exceptions.dart` | `ClockDriftException` 에 `kind`(`ClockDriftKind.remoteAhead`·`localAhead`)·`remoteNodeId` 추가, `toString` 의 `Duration` 뒤 `ms` 표기 오류 수정·1ms 미만 부분 표기 |
| `lib/src/managers/hlc.dart` | `HlcManager.forSpace(maxDrift:)` — `increment`·`peekNext`·`merge`·`adoptOwn` 에 같은 값 전달 |
| `lib/src/database/merge.dart` | `_updateHlcFromIncomingOperations`: 배치 최대값 하나만 보던 것을 다른 노드 최대값 `merge` → 자기 노드 최대값 `adoptOwn` 순서로 나눔. 업스트림은 최대값이 자기 노드 id 면 검사 없이 채택했다 ([위조 노드 id](#시계-오차-허용치와-동기화-실패-분류)) |
| `lib/src/database/recorder.dart`·`merge_utils/recorder_context.dart` | `OfflineSyncDatabaseContext.maxClockDrift`(0 이하 `ArgumentError`)·`resolve`, `hlcManagerFor` 가 그 값을 전달 |
| `lib/src/database/database.dart`·`session.dart`·`lib/src/sync/engine.dart` | `maxClockDrift` named 인자(공유 context 와 다르면 `ArgumentError`)와 getter. 동기화 루프·프로토콜은 무변경 |
| `lib/src/sync/engine.dart`·`space_state.dart` | 미전송 건수의 근거(unibook#14183): 기기(follower)가 서버 핸드셰이크의 자기 노드 체크포인트로 (space, 자기 노드) `offline_sync_space_nodes.lastReceivedHlc` 를 **덮어쓰고**(A), `once` 세션에서 서버 `OfflineSyncClose` 를 받은 뒤에만 보낸 변경의 최대값을 기록한다(B). 동기화 루프에 기기 쪽 DB 쓰기가 늘었고, 와이어 프로토콜·스키마·권위 피어 동작은 무변경. 이 쓰기는 새 `OfflineSyncDatabase` 래퍼가 아니라 plain DB 위의 recorder 로 한다(래퍼의 첫 작업은 레지스트리가 바뀐 프로세스에서 전 space 를 재투영한다). `countUnsentRows`(수집 필터를 자기 노드로 좁힌 3쿼리, 행을 읽은 뒤 체크포인트를 다시 읽어 내려갔으면 다시 셈), 테스트 훅 `@visibleForTesting debugOnUnsentRowCheckpointsRead`, `OfflineSyncSpaceState.checkpointOf`·`handshakenSpaceIds` ([동기화 상태](#동기화-상태와-미전송-건수)) |
| `lib/src/sync/engine.dart` (`_readPendingChanges`) | 보낼 변경 수집의 **유실 수정**(unibook#14183): 업스트림은 삽입·갱신·삭제 쿼리를 각 스트림이 시작할 때 따로 돌려, 그 사이 커밋된 쓰기를 뒤 쿼리만 봤다. 뒤에 읽힌 갱신이 먼저 놓친 삽입보다 높은 HLC 로 체크포인트를 올려 그 삽입은 다음 세션에도 보내지지 않았다. 세 쿼리를 첫 변경을 내기 전에 **한 스냅샷**(PostgreSQL repeatable read · SQLite 쓰기 잠금 트랜잭션)에서 읽는다. 와이어·스키마 무변경. 테스트 훅 `@visibleForTesting debugOnPendingRowsRead`(삽입과 갱신 조회 사이) |
| `lib/src/database/database.dart`·`recorder.dart`·`unsent_row_count.dart` (신규, 배럴 미export) | `unsentRowCount`·`watchUnsentRowCount`(파이프라인 `countOnEachTrigger`)·`watchUnsentRowCountTriggers`, `@internal replaceSyncCheckpoint`(단조 증가가 아닌 덮어쓰기), 테스트 훅 `@visibleForTesting CrdtMutationRecorder.debugProjectionRebuildCount` |
| `lib/src/sync/failure_code.spy.yaml`·`remote_exception.spy.yaml`·`failure_mapping.dart` (신규) | 와이어 예외 `OfflineSyncRemoteException`·`OfflineSyncFailureCode`(`unknown` + `default: unknown`), 매퍼 `toOfflineSyncWireError`(`driftMs` 올림, 무결성 위반은 식별자 없는 고정 문구)·`offlineSyncWireErrors(onMapped:)`. 생성 코드 2개 추가 |
| `lib/serverpod_offline_sync.dart` (배럴) | `src/sync/failure_mapping.dart` export 추가 — 공개 API 가 늘어남 |
| `test/hlc/hlc_fixtures.dart`·`hlc_increment_test.dart`·`hlc_merge_test.dart` (업스트림 테스트) | 1분 초과를 거부하던 케이스를 "기본값에서는 통과" 로 바꾸고 거부 경계를 1시간(`Hlc.defaultMaxDrift`)으로 옮김, `kind` 단언 추가, fixture 주석(밀리초 정렬 이유) |
| `serverpod_offline_sync_server` `business/offline_sync.dart` | `initializeOfflineSync(maxClockDrift:)`, `OfflineSyncSession.sync` 에 매퍼 적용·바꾼 실패의 원본을 세션 로그(`LogLevel.error`)에 기록, `maxClockDrift` getter. `initializeOfflineSync` dartdoc 에 "설정은 한 번에 모두" 경고(unibook#14183, 동작 무변경) |
| `serverpod_offline_sync_client` `lib/src/sync/failure.dart` (신규) | 앱 분류기 `OfflineSyncFailure.from`·`OfflineSyncFailureReason` (열기 거부 `OpenMethodStreamException` 3종 포함) |
| `serverpod_offline_sync_client` `lib/src/sync/sync_status.dart` (신규)·`pubspec.yaml` | 상태 API `OfflineSyncStatusTracker`·`OfflineSyncStatus`·`OfflineSyncPhase` (unibook#14183), 테스트용 `@visibleForTesting unsentRowCounter`, `clock`·`meta` 의존 추가 |
| `serverpod_offline_sync_client` `lib/offline_sync.dart`·`lib/serverpod_offline_sync_client.dart` (배럴) | `src/sync/failure.dart`·`src/sync/sync_status.dart` export 추가 — 공개 API 가 늘어남 |
| **포크 전용 테스트** (업스트림에 없음) | 엔진 `test/hlc/hlc_max_drift_test.dart`·`test/managers/hlc_manager_test.dart`·`test/sync/failure_mapping_test.dart`·`test/sync/max_clock_drift_config_test.dart`·`test/database/unsent_row_count_test.dart`, 클라이언트 `test/failure_test.dart`·`test/sync_status_test.dart`, 서버 모듈 `test/integration/failure_mapping_test.dart`·`test/integration/continuous_sync_interval_test.dart`. 업스트림을 새로 풀면 **지워진다** — [업스트림 따라가기](#업스트림-따라가기) 1단계 |

## 설치

앱 서버와 클라이언트 모두 Serverpod와 CLI를 **4.1.0-beta.1**로 맞춥니다. `ref`는 검증한 커밋 SHA로
고정하세요. 형제 패키지 `serverpod_offline_sync`는 같은 저장소·커밋에서 path 의존으로 따라옵니다.

```yaml
# my_app_server/pubspec.yaml
dependencies:
  serverpod: ^4.1.0-beta.1
  serverpod_offline_sync_server:
    git:
      url: https://github.com/coco-de/co-serverpod.git
      ref: <COMMIT_SHA>
      path: packages/serverpod_offline_sync_server
```

```yaml
# my_app_client/pubspec.yaml
dependencies:
  serverpod_client: ^4.1.0-beta.1
  serverpod_offline_sync_client:
    git:
      url: https://github.com/coco-de/co-serverpod.git
      ref: <COMMIT_SHA>
      path: packages/serverpod_offline_sync_client
```

모듈 등록과 동기화 모델 정의는 업스트림과 같습니다.

```yaml
# my_app_server/config/generator.yaml
modules:
  serverpod_offline_sync:
    nickname: offline_sync

experimental_features:
  databaseSync: true
```

```yaml
# my_app_server/lib/src/models/note.spy.yaml
class: Note
table: note
database: sync
fields:
  title: String
  archived: bool, default=false
```

CLI 4.1.0-beta.1로 `serverpod generate`를 실행하면 모든 테이블 모델에 `watch`가 생깁니다.

## 사용법

```dart
final session = await client.createSyncSession(
  databasePath,
  isDebugMode: kDebugMode,
  persistentUserId: userId,
);

// 첫 결과를 바로 내보내고, 결과가 바뀔 때마다 다시 내보냅니다.
final Stream<List<Note>> notes = Note.db.watch(
  session,
  where: (t) => t.archived.equals(false),
  orderBy: (t) => t.title,
);

// 쓰기는 평소처럼 합니다. 네트워크를 기다리지 않고 watch에 반영됩니다.
await Note.db.insertRow(session, Note(title: '초안'));

// 다른 기기의 변경도 병합되는 즉시 반영됩니다.
final live = client.offlineSync.syncContinuously(session);
```

BLoC에서는 `emit.forEach(Note.db.watch(session, ...), onData: ...)`로, 위젯에서는 `StreamBuilder`로
연결합니다. 스트림은 `build`에서 매번 만들지 말고 한 번 만들어 보관하세요. `include`,
`limit`/`offset`, `database: client` 전용 테이블도 같은 방식으로 동작합니다.

## 시계 오차 허용치와 동기화 실패 분류

업스트림은 HLC 시계 오차 한도를 **1분**으로 고정했습니다. 포크는 기본값을 `co_offline_sync` 와 같은
**1시간**(`Hlc.defaultMaxDrift`)으로 두고, 데이터베이스마다 바꿀 수 있게 했습니다 (unibook#14182).

```dart
// 서버: 기기 스탬프를 받아 주는 한도(S)
pod.initializeOfflineSync(syncTables: syncTables, maxClockDrift: const Duration(hours: 1));

// 기기: 생성된 createSyncSession 은 이 인자를 넘기지 않으므로, 값을 바꿀 때는 직접 연다(C).
final session = OfflineSyncDatabaseSession.wraps(
  await client.createSession(path),
  syncTables: syncTables,
  persistentUserId: userId,
  maxClockDrift: const Duration(hours: 1),
);
await session.db.initialize();
```

한 값이 세 검사를 함께 정합니다. `increment` 와 `merge` 가 같은 값을 써야 `merge` 가 받아 준 스탬프 때문에
바로 다음 로컬 쓰기가 막히지 않습니다(업스트림은 `increment` 에만 리터럴이 따로 있었습니다).

| 어디서 | 무엇이 막히나 | 기기가 받는 것 | `OfflineSyncFailure.from(e).code` |
|---|---|---|---|
| 기기 병합 (K1) | 서버 스탬프가 기기 벽시계보다 C 초과 앞섬 — **기기가 뒤처짐**, 또는 **같은 계정(같은 space)** 의 다른 기기가 그 space 의 서버 노드를 끌어올림, 드물게 서버 인스턴스 사이 시계 차이(기기는 구분하지 못함) | `ClockDriftException(remoteAhead)` | `clockDriftBehind` |
| 서버 병합 (K2) | 기기 스탬프가 서버 벽시계보다 S 초과 앞섬 — **기기가 앞섬** | `OfflineSyncRemoteException(clockDrift)` | `clockDrift` |
| 서버 로컬 증가 | 서버 노드 시계가 서버 벽시계보다 S 초과 앞섬 — 기기 탓이 아님 | `OfflineSyncRemoteException(serverClockDrift)` | `serverClockDrift` |
| 기기 로컬 쓰기 (K3) | 기기 벽시계가 마지막 스탬프보다 C 초과 뒤로 감 | `ClockDriftException(localAhead)` (ORM 쓰기에서) | `clockRollback` |

- **K2 의 타입**: Serverpod 스트리밍 endpoint 는 `SerializableException` 만 기기로 보냅니다. 그 밖의 예외는
  `ConnectionClosedException` 이 되어 네트워크 끊김과 구분되지 않습니다. 서버 파사드
  `session.offlineSync.sync` 가 `offlineSyncWireErrors()` 로 시계 오차·카운터 오버플로·중복 노드·무결성
  위반을 `OfflineSyncRemoteException` 으로 바꿉니다. **앱 endpoint 는 이 파사드를 써야 합니다** — 엔진을
  직접 부르면(`session.offlineSyncDb.sync(...)` — 서버 `Session` 은 `DatabaseSession` 이고 인터셉터가
  `session.db` 를 `OfflineSyncDatabase` 로 감싸므로 이 호출이 컴파일된다) 타입이 다시 사라집니다. 스키마 해시
  불일치는 매핑하지 않습니다. 각 피어가 상대 해시를 직접 검증해 이미 타입 있는 예외를 받고, 방향 판정은 앱
  몫입니다.
- **무결성 위반은 코드와 고정 문구만**: 서버 쪽 원래 메시지는 행을 소유한 space(개인 space 면 **다른 사용자
  id**)와 영속된 위반 행 id 를 담습니다. 그래서 기기에는 `integrityViolation` 과 식별자 없는 고정 문구만 보내고,
  원본은 파사드가 `offlineSyncWireErrors(onMapped:)` 로 세션 로그(`LogLevel.error`)에 남깁니다 — Serverpod 는
  스트림을 끝낸 오류(대체본)만 기록하기 때문입니다. 매퍼를 직접 적용하는 endpoint 도 `onMapped` 로 같은 로그를
  남기세요. 다른 코드의 `message` 는 서버 메시지 그대로입니다(시계 오차의 노드 id 는 기기가 보낸 스탬프의 것).
- **서버 노드는 space 마다 하나** (unibook#14218): 업스트림은 DB 하나의 모든 space 가 **노드 하나를 공유**했습니다.
  서버에서 그 노드는 영속되고 인스턴스끼리도 공유되므로, S 이내로 앞선 기기 한 대가 끌어올린 시계가 **다른 모든
  사용자**에 대한 서버 쓰기 스탬프가 됐습니다 — 그 쓰기가 LWW 에서 새 편집을 이기고, 다른 사용자 기기가 K1 로
  멈추고, 카운터 65,535 를 전 사용자가 나눠 쓰고, 모든 병합이 그 한 행의 `FOR UPDATE` 를 기다렸습니다. 포크는
  **영속 사용자 없이 연 DB(서버)** 에서 space 마다 노드를 줍니다(`managers/space.dart`). 기기(영속 사용자로 연 DB)
  는 지금처럼 설치 단위 노드 하나를 모든 space 가 공유합니다. 설정으로 끌 수 없습니다 — context 를 처음 쓴 DB 가
  정하고, space 마다 노드를 준 context 에 영속 사용자 DB 를 열면 `StateError` 입니다(서버 전체가 조용히 공유
  노드로 돌아가는 대신). 이미 노드를 공유하던 space 는 다음 사용 때 새 노드를 받고, 그 시계는
  max(공유 노드 `lastHlc`, 그 space 에 저장된 최대 스탬프 — 행·필드·툼스톤)에서 시작합니다(기기 쪽
  `_preserveLatestCurrentNodeHlc` 와 대칭). 이 이동은 space 행을 `FOR NO KEY UPDATE`(그 space 를 참조만 하는 병합은
  기다리지 않음)로, 이어서 노드 행을 잠그고 다시 확인합니다 — 동시에 옮겨도 한 space 에 노드 둘이 생기지 않고,
  함께 떠나던 space 들 중 마지막은 공유 노드를 그대로 씁니다. ⚠️ **구버전 서버와 함께 돌리지 마세요** — 구버전은
  space 를 다시 한 노드로 모으고 두 버전이 서로 옮깁니다. 시계는 오르기만 해 LWW 는 맞지만 그동안 기기 한 대가
  다른 사용자 space 의 시계를 끌어올릴 수 있습니다. 한 세션이 여러 space 를 다루면 서버 노드도 여럿이지만
  체크포인트가 (space, 노드) 단위라 정합이 유지됩니다(`space_node_test.dart`, 공유 노드 DB 를 옮긴 경우 포함) —
  다만 한 space 의 K1 은 그 세션 전체를 멈춥니다.
- **connect 노드 체크포인트**: 업스트림은 배치를 병합한 뒤 connect 노드의 체크포인트로 **배치 최대값**을 적었고,
  그 스탬프에 다른 저자의 노드 id 가 남아 다음 핸드셰이크가 그 노드 이름으로 보냈습니다 — connect 노드는
  체크포인트가 없어 그 space 의 자기 변경을 매 세션 다시 받았습니다. 공유 노드를 떠난 space 에서는 connect 노드가
  다시 쓰지 않으니 끝나지 않았습니다. 포크는 connect 노드 **자신의** 변경으로만 적고, 다른 노드 id 로 저장된
  체크포인트는 그 노드의 변경이 오면 대체합니다(이미 그렇게 저장된 기기는 한 번 더 받고 멈춥니다).
- **C ≥ S + 같은 계정 기기 사이의 예상 지연**: S 이내로 앞선 기기 한 대가 **자기 space** 의 서버 노드를 서버
  벽시계 + S 까지 끌어올리면, 그 뒤 서버가 그 space 에 쓰는 스탬프도 그만큼 앞섭니다. 같은 space 에서 서버보다
  δ 만큼 뒤처진 형제 기기는 그 스탬프를 S + δ 앞선 것으로 보므로, C 가 S + δ 보다 작으면 K1 로 멈춥니다
  (unibook#13202 ⓒ 와 같은 구조). 다른 space 의 기기는 영향을 받지 않습니다. ⚠️ **기본값 C = S = 1시간은 이
  규칙을 δ = 0 에서만 만족합니다** — 같은 계정의 다른 기기가 서버 노드를 한도 끝까지 끌어간 동안, 서버보다
  조금이라도 느린 기기는 멈출 수 있습니다(`space_node_test.dart` 가 이 잔여를 고정합니다). 여유를 두려면 서버 S 를
  기기 C 보다 예상 지연만큼 작게 잡으세요(예: S 30분, C 1시간). C < S 이면 시계가 정확한 기기도 멈춥니다. 한도가
  1분에서 1시간이 되면서 이 창도 60배 넓어졌습니다 — 서버 작성 쓰기(백필 등)가 그 창 안에서 미래 스탬프를 받아
  LWW 에서 이길 수 있습니다.
- **위조 노드 id**: 피어는 아무 노드 id 로나 변경을 보낼 수 있습니다. 업스트림 병합은 배치의 최대 HLC 하나만 검사하고,
  그것이 자기 노드 id 면 검사 없이 채택했습니다 — 서버 노드 id 로 +3시간 행 하나를 끼우면 같은 배치의 다른 행도
  검사를 건너뛰고 서버 노드가 한도 없이 끌려갔습니다. 포크는 다른 노드 최대값을 먼저 `merge` 로 검사하고, 자기
  노드 스탬프도 `adoptOwn` 으로 같은 한도 안에서만 받습니다. 그래서 "기기 한 대가 서버 노드를 끌어올릴 수 있는
  폭은 S 까지" 가 성립하고, `serverClockDrift` 가 기기 탓이 아니라는 분류도 이것에 기댑니다.
- **한도를 낮출 때**: 노드의 마지막 스탬프(`crdt_nodes.lastHlc`)는 영속됩니다. 노드 시계가 큰 한도 아래서 이미
  벽시계보다 앞선 상태에서 한도를 낮춰 재시작하면, 벽시계가 따라잡을 때까지(최대 옛 한도만큼) 그 노드의 **모든 로컬
  CRDT 쓰기**가 `localAhead` 로 실패합니다. 서버에서는 노드가 앞서 있는 **그 space 의 동기화 테이블 쓰기**가
  막히고, 서버 스탬프가 필요한 그 space 의 동기화는 기기에 `serverClockDrift` 로 갑니다. 낮추기 전에 노드들의
  `lastHlc` 가 벽시계보다 새 한도 이상 앞서 있지 않은지 확인하거나, 단계적으로 낮추세요.
- **카운터 오버플로 노출**: 노드 시계가 벽시계보다 앞서 있는 동안에는 스탬프마다 시각은 그대로이고 카운터만
  오릅니다(`Hlc.increment`). 카운터 상한은 `0xFFFF`(65,535)이고, update 는 **행 × 바뀐 필드마다** 스탬프를
  찍습니다. 앞서 있을 수 있는 시간이 1분에서 1시간이 되면서 이 노출도 60배 커졌습니다 — 서버 대량 쓰기(백필 등)나
  쓰기가 많은 기기가 끌려간 창 안에서 `OverflowException`(`hlcOverflow`)을 낼 수 있고, 벽시계가 따라잡을 때까지
  계속됩니다. 서버에서는 카운터도 space 마다 따로라 한 space 의 소진이 다른 space 의 쓰기를 막지 않습니다. 대량
  쓰기 전에 그 space 의 서버 노드가 앞서 있지 않은지 확인하세요.
- **K3 는 업스트림대로 유지**합니다. 기기 시계를 한도보다 크게 되돌리면 그 시간만큼 모든 로컬 쓰기가 실패합니다
  (`co_offline_sync` 의 `now()` 에는 없던 실패 모드입니다).
- **분류기**: `OfflineSyncFailure.from(error)` 가 `code`·`isPermanent`·`isClockDrift` 를 줍니다. `isClockDrift` 는
  기기 시계 확인 안내 대상(`clockDrift`·`clockDriftBehind`·`clockRollback`)이고, `serverClockDrift` 는 포함하지
  않습니다. `schemaMismatch` 는 방향을 판정하지 않으므로 영구로 분류하지 않습니다. 스트림 **열기 거부**
  (`OpenMethodStreamException`)는 네트워크 끊김이 아닙니다 — `authenticationFailed`(토큰 갱신 1회 뒤에도 인증 실패)·
  `authorizationDeclined`·`incompatibleEndpoint`(`endpointNotFound`·`invalidArguments`)로 나누고 영구로 봅니다.
  그 밖의 `MethodStreamException` 만 `transport` 입니다.
- **와이어 계약 — `unknown`**: `OfflineSyncFailureCode` 는 모르는 코드를 `unknown` 으로 풉니다(`default: unknown`).
  던지게 두면 서버가 나중에 코드를 더했을 때 구버전 앱에서 `UnknownMessageException` 이 나고, Serverpod 클라이언트가
  **WebSocket 연결 전체**(그 위의 모든 메서드 스트림)를 닫습니다. 이 기본값과 `unknown` 값은 지우지 마세요.
  서버는 `unknown` 을 보내지 않습니다.
- ⚠️ **`unknown` 은 모르는 코드만 막습니다 — 모르는 클래스는 못 막습니다.** `OfflineSyncRemoteException` 이 생기기
  전의 포크로 빌드한 앱은 이 클래스 자체를 복호하지 못해 같은 `UnknownMessageException` 이 나고 연결 전체가
  닫힙니다(`serverpod_client` 4.1.0-beta.1 `client_method_stream_manager.dart` 의 `UnknownMessageException`
  catch → rethrow → 연결 종료). 이 포크에 의존해 배포된 앱이 없으면 영향이 없습니다(unibook 은 2026-09-24
  기준 의존하지 않음). 앞으로 기기로 보내는 **새 직렬화 클래스**(예외든 이벤트든)를 더할 때는 그 클래스를 아는
  앱을 먼저 배포하고 서버가 나중에 보내기 시작하게 하거나, 핸드셰이크에서 기기가 아는지 확인해 게이트하세요.
- **`driftMs` 는 올림**: `merge` 는 벽시계를 마이크로초로 비교하므로 한도를 1ms 미만 넘긴 거부가 있습니다.
  `driftMs` 는 올리고 `maxDriftMs` 는 내려서, 거부된 경우 항상 `driftMs > maxDriftMs` 입니다.
- **후속 후보 (하지 않음)**: 병합의 시계 검사는 `mergeChanges` 끝(`_updateHlcFromIncomingOperations`)에 있어서
  거부될 배치도 모든 행을 쓴 뒤 롤백합니다. 앞단 사전 검사로 옮기면 낭비가 줄지만, 관찰 결과가 같고 업스트림과의
  차이가 늘어 이번에는 하지 않았습니다.

## 동기화 상태와 미전송 건수

앱이 co_sync 에서 받던 미전송 건수·동기화 상태를 포크에서도 얻습니다 (unibook#14183). 상태는
client 패키지의 `OfflineSyncStatusTracker` 가 들고, 건수는 엔진의 `OfflineSyncDatabase.unsentRowCount`
가 셉니다. `client.offlineSync` 는 접근할 때마다 새로 만들어지므로 추적기는 세션마다 하나 만들어 보관하세요.

```dart
final tracker = OfflineSyncStatusTracker(client.offlineSync, session);
tracker.statusChanges.listen(render); // 현재 값은 tracker.status

await tracker.syncOnce(); // 실패도 status 에 남기고 다시 던진다

// 로그아웃 경고처럼 캐시가 아니라 지금 값이 필요할 때
final unsent = await tracker.countUnsentRows();
```

| `OfflineSyncStatus` | 뜻 | co_sync `CoSyncStatus` |
|---|---|---|
| `phase` | `syncOnce` 회차 진행 중(`syncing`) 여부. 연속 동기화는 바꾸지 않는다 | `inFlight` |
| `unsentRowCount` | 이 기기가 쓰고 서버가 아직 확인하지 않은 **행** 수. `null` 은 판정 불가(미집계·조회 실패)이고 0 이 아니다 | `pendingCount` |
| `lastSuccessAt` | 마지막 `syncOnce` 성공 시각 | 같음 |
| `lastFailure`·`lastFailureAt` | `OfflineSyncFailure.from` 으로 분류한 마지막 실패(성공하면 지워짐) | `lastFailure` |
| `isIdle`·`needsAttention` | 할 일 없음 / 영구 실패 | 같음 (격리·스키마 축은 없음) |

- **"확인" 은 ACK 가 아니라 기기가 서버에게서 기록한 것**입니다. 프로토콜에 ACK 가 없어서, 기기의
  (space, 자기 노드) `offline_sync_space_nodes.lastReceivedHlc` 를 서버 확인 체크포인트로 씁니다(서버 쪽
  같은 컬럼과 같은 뜻, 핸드셰이크는 자기 노드 행을 보내지 않으므로 프로토콜 무변경). 기록 시점은 셋입니다 —
  ① 세션 시작 때 서버 핸드셰이크가 보고한 값으로 **덮어쓰기**(서버가 데이터를 잃었으면 내려간다),
  ② `once` 세션에서 서버의 `OfflineSyncClose` 를 받은 뒤 보낸 변경의 최대값(서버는 마지막 배치를 병합한
  뒤에만 닫는다), ③ 서버가 되돌려 보낸 자기 변경(업스트림 병합 경로, 보장 아님).
- **적게 세지 않고, 많이 셀 수는 있습니다.** 서버가 거부한 회차(K2 등)와 기기 쪽 실패는 ②에 닿지 않아 줄지
  않습니다. 서버는 병합했는데 기기가 실패한 회차, 연속 동기화(회차마다 확인 시점이 없다)는 다음 `syncOnce`
  까지 많게 셉니다. 서버가 이 사용자와 더 동기화하지 않는 space 의 자기 행은 계속 셉니다. 셈 도중에 ①이
  체크포인트를 내리면(데이터를 잃은 서버) 옛 높은 값으로 세지 않도록, 행을 읽은 뒤 체크포인트를 다시 읽어
  내려갔으면 새 값으로 다시 셉니다(최대 3회, 그래도 계속 내려가면 자기 행 전부 = 상한). 셈 도중 커밋된
  **로컬 쓰기**는 들어갈 수도 빠질 수도 있으니, 로그아웃 경고는 쓰기를 멈춘 뒤 셉니다.
- **보낼 변경은 한 스냅샷에서 모읍니다.** 회차는 삽입·갱신·삭제를 쿼리 셋으로 읽습니다. 업스트림은 셋을 따로
  읽어서, 회차가 모으는 도중 커밋된 쓰기(삽입 뒤 갱신)를 갱신 쿼리만 보고 보냈고, 체크포인트가 그 갱신까지
  올라가 놓친 삽입은 **다시 보내지지 않았습니다**(건수도 0). 포크는 셋을 한 스냅샷에서 먼저 읽습니다. 노드의
  쓰기는 노드를 잠그고 스탬프를 찍으므로 HLC 순서로 커밋되고, 스냅샷에 든 것은 어떤 HLC 까지의 전부입니다 —
  스냅샷 뒤의 쓰기는 다음 회차가 보내고 그동안 건수에 남습니다. SQLite 에서는 스냅샷이 쓰기 잠금이라 세 쿼리
  동안 로컬 쓰기가 기다립니다(도메인 값 조회는 잠금 밖).
- **건수를 셀 수 없으면 `null`**: 조회가 실패하면(예: DB 가 닫힘) 추적기는 0 도 직전 값도 아닌 `null` 을
  발행합니다. `watchUnsentRowCount` 는 실패한 셈을 오류 이벤트로 내고 다음 커밋에서 다시 셉니다.
- **한 이벤트로 발행**: `syncOnce` 가 끝나면 결과(`lastSuccessAt` 또는 `lastFailure`)와 **그 뒤에 읽은** 건수를
  한 번에 냅니다. "성공 시각 이후 + 미전송 0" 으로 판정하는 소비자가 중간 상태를 보지 않습니다. 건수 조회는
  한 번에 하나씩, 요청 이후에 시작한 조회로만 갱신합니다.
- **오프라인 쓰기 반영은 SQLite 전용**: 추적기는 `watchUnsentRowCountTriggers` 로 커밋마다 다시 셉니다. 워치가
  없는 DB 에서는 생성 시·회차 뒤·`refreshUnsentRowCount` 에서만 셉니다. 웹은 검증하지 않았습니다.
- **`syncOnce` 는 합류합니다**: 진행 중에 부르면 같은 회차를 기다리고, 그 호출의 `onMergeSuccess` 는 불리지
  않습니다. 회차 중에 쓴 행은 그 회차에 실리지 않을 수 있으니 성공 뒤 건수가 0 이 아니면 다시 예약하세요.
- **비용**: 행·필드·tombstone 3쿼리의 행 id 합집합과, 앞뒤 체크포인트 조회(자기 노드 행만)입니다. 데스크톱
  SQLite 실측(2026-09-24, 재검증 포함, 각 5회): 1천 행 8–18ms·1만 행 46–58ms(확인값 없음, 전량), 확인값 이후
  10% 갱신 시 1천 행 3–5ms·1만 행 13–16ms.
  모바일은 측정하지 않았습니다. 행에 필드 조건을 `any` 로 거는 한 쿼리는 설계 프로브에서 1만 행 1.3–2.4초여서
  쓰지 않습니다.

### 서버 연속 동기화 간격

`initializeOfflineSync(continuousSyncInterval:)` 이 서버 쪽 연속 동기화 회차 사이 대기(기본 200ms, 업스트림과
같음)를 정합니다. 두 피어는 각자 루프를 돌고, 각자 자기 간격만 봅니다.

| 간격 | 정하는 곳 | 좌우하는 것 |
|---|---|---|
| 서버 | `initializeOfflineSync(continuousSyncInterval:)` — **서버 전체에 하나** | 서버가 자기 쪽 변경(다른 기기가 올린 쓰기 포함)을 모아 이 기기로 보내는 주기. 기기가 보낼 것이 없으면 서버는 유휴 타임아웃 1초를 기다린 뒤 이 간격만큼 쉬고 다시 모읍니다(대략 1초 + 간격) |
| 기기 | `OfflineSyncDatabaseSession.wraps(continuousSyncInterval:)` | 기기가 로컬 쓰기를 모아 보내는 주기와, 받아 둔 서버 배치를 적용하는 주기 |

⚠️ 기기 간격을 줄여도 **서버가 보내는 주기는 그대로입니다**. 보낼 것이 없는 기기는 배치 끝을 보내지 않아서, 서버는
여전히 유휴 타임아웃과 자기 간격을 기다립니다. 내려오는 쪽 지연은 서버 주기와 기기 주기를 둘 다 거칩니다. 화면
(세션)마다 다른 간격 — ADR §5.4 의 "실시간이 필요한 화면에서만" — 은 이 포크에 **없습니다**. 전역 설정만
있습니다. 세션별 서버 간격은 unibook#14207 이 추적합니다(클라이언트 동기화 관리 레이어 unibook#14193 의 선행).

⚠️ 생성된 `Serverpod` 생성자가 이미 **기본값으로** `initializeOfflineSync(syncTables: ...)` 를 부릅니다. 값을 바꾸려면
생성 뒤에 다시 부르되, 호출마다 엔진을 통째로 교체하므로 **모든 설정을 한 번에** 넘기세요 — 간격만 넘기면
`maxClockDrift` 가 기본값으로 돌아갑니다.

```dart
final pod = Serverpod(args);
pod.initializeOfflineSync(
  syncTables: syncTables,
  continuousSyncInterval: const Duration(seconds: 2),
  maxClockDrift: const Duration(minutes: 30),
);
```

간격은 서버 전체에 하나입니다. 줄이면 모든 사용자의 모든 연속 세션이 더 자주 모읍니다.

## 동작과 주의점

- **트리거 테이블**: 조회 테이블, `where`·`orderBy`·`include`가 참조하는 테이블, `alsoTriggerOnTables`,
  그리고 CRDT 가시성 테이블(`crdt_data_rows`·`offline_sync_spaces`·`offline_sync_space_members`)에
  커밋이 생기면 다시 조회합니다. `where`에 raw `Expression`을 쓰면 그 안의 테이블은
  `alsoTriggerOnTables`로 넘겨야 합니다.
- **재조회 범위**: CRDT 테이블은 모든 동기화 테이블이 공유하므로, 어느 동기화 테이블에 쓰든 모든 watch가
  다시 조회합니다. 동기화 기록 같은 부수 쓰기도 마찬가지입니다. 그래서 직렬화 결과가 직전 emit과 같으면
  내보내지 않습니다. 생성 모델에는 `==`가 없어서 앱에서 거르기 어렵기 때문입니다.
- **가시성 필터 재생성**: 재조회할 때마다 가시성 필터와 space 목록을 새로 만듭니다. 공유 space 권한
  변경 시나리오는 아직 테스트하지 않았습니다.
- **SQLite 전용**: 서버(Postgres)에서 호출하면 `UnsupportedError`입니다. 커밋된 상태만 읽고, 롤백된
  트랜잭션은 내보내지 않습니다.
- **버전 범위**: Serverpod CLI는 `^4.1.0-beta.1` 같은 범위보다 정확한 버전 고정을 권장한다고 경고합니다.
  4.1 정식 이후 버전 차이로 생성 코드가 어긋나면 정확한 버전으로 고정하세요.
- **웹**: 웹 빌드는 검증하지 않았습니다.

## 테스트

DB 서버가 필요 없습니다. watch 테스트는 SQLite 복제본 두 개를 한 프로세스에서 동기화하고, 한쪽이
운영 환경의 Serverpod endpoint 역할(authoritative)을 맡습니다.

```bash
# 엔진 단위 테스트
cd packages/serverpod_offline_sync && dart pub get && dart test
# 클라이언트 실패 분류·상태 값 테스트
cd packages/serverpod_offline_sync_client && dart pub get && dart test
# 모듈 통합 테스트 (SQLite 파일 + 테스트 1개는 Serverpod 내장 PostgreSQL 자동 기동)
cd packages/serverpod_offline_sync_server && dart pub get && dart test --concurrency=1
# 생성된 Model.db.watch 테스트
cd test/offline_sync_watch_test_client && dart pub get && dart test
```

watch fixture의 모델은 `test/offline_sync_watch_test_server/lib/src/models`에 있습니다. 모델을 바꾸면
생성 코드와 마이그레이션을 다시 만듭니다.

```bash
cd test/offline_sync_watch_test_server
dart pub get
dart run serverpod_cli generate
dart run serverpod_cli create-migration
```

업스트림 저장소의 대규모 테스트(`test/serverpod_offline_sync_test_*`, 결정론적 시뮬레이션)는 포크에
포함하지 않았습니다.

## 업스트림 따라가기

1. 새 기준 커밋에서 `git archive <sha> packages/serverpod_offline_sync packages/serverpod_offline_sync_client packages/serverpod_offline_sync_server`로
   세 패키지를 다시 풀고, [변경점 표](#업스트림-기준과-변경점)의 항목을 다시 적용합니다. ⚠️ 디렉터리를 새로 풀면
   표의 **포크 전용 테스트**와 신규 파일이 사라집니다 — 푼 직후 `git checkout <직전 포크 커밋> -- <파일>` 로
   되살리세요. ⚠️ 시계 오차 항목을 빠뜨리면 **조용히 1분으로 돌아갑니다** — 그 회귀를 잡는
   `hlc_max_drift_test.dart` 도 포크 전용이라, 되살리지 않으면 회귀와 가드가 함께 사라집니다.
2. `cd packages/serverpod_offline_sync_server && dart run serverpod_cli generate`
3. 위 테스트를 모두 실행합니다.
4. 이 README의 기준 커밋과 `CHANGELOG.md`를 갱신합니다.

## 포크 제거

업스트림이 Serverpod 4.1과 `watch`를 지원하는 버전을 내고, [왜 포크인가](#왜-포크인가)의 포크 전용 API·동작에
대응물이 생기면 다음 순서로 돌아갑니다.

1. [변경점 표](#업스트림-기준과-변경점)의 포크 전용 항목마다 업스트림 대응물을 찾고, 앱 호출부를 그쪽으로 옮깁니다.
   대응물이 없는 API 를 쓰는 앱은 컴파일되지 않으니 그대로 지우지 마세요. 동작 차이(시계 오차 기본값 1시간,
   기기의 서버 확인 체크포인트 기록)는 컴파일 오류로 드러나지 않습니다 — 업스트림 고정값(1분)으로 돌아가면
   1분을 넘는 기기 시계 차이가 다시 K1·K2 로 거부됩니다. 기기 DB 에 남은 자기 노드 체크포인트 행은 업스트림
   핸드셰이크가 읽지 않아(`createSyncSinceHlc` 는 현재 노드 행을 제외) 무해합니다.
2. watch fixture 테스트를 업스트림 버전으로 돌려 삭제·병합 삭제가 반영되는지 확인합니다.
3. 앱의 git 의존을 pub 버전으로 바꿉니다. 패키지 이름과 모듈 이름이 같아서 생성 코드와 DB는 그대로입니다.
4. 세 패키지와 `test/offline_sync_watch_test_*`를 삭제합니다.
