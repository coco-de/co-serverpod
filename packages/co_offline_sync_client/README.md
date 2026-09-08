# co_offline_sync_client

[`co_offline_sync`](../co_offline_sync/README.md)의 **Flutter + Drift 클라이언트 구현**입니다.
SQLite 기반 영속 저장소, 반응형 조회, 연결/인증/생명주기에 따른 동기화, 읽기 전용
replica 저장소를 제공합니다. 유니북의 `package/co_sync`에서 공용 구현을 옮겼습니다.

앱 스키마, 인증, Serverpod 생성 클라이언트, 도메인 코덱은 포함하지 않습니다.
생성자와 콜백으로 연결하므로 다른 Flutter 앱에서도 사용할 수 있습니다.
패키지 이름은 `client`지만 현재 Flutter SDK가 필요합니다. 순수 Dart 환경에는
코어의 `CoSyncClient`와 별도 `ClientSyncStore` 구현을 사용하세요.

## 설치

SDK 제약은 Dart `>=3.10.0 <4.0.0`이고, 아래 검증 명령은 Flutter 3.47.0에서 실행합니다.
소비 앱의 `pubspec.yaml`에 Git 의존성을 추가하세요. `<COMMIT_SHA>`는 실제 검증한
커밋으로 교체하고 두 패키지의 URL/ref를 같게 유지합니다.

```yaml
dependencies:
  flutter:
    sdk: flutter
  co_offline_sync_client:
    git:
      url: https://github.com/coco-de/co-serverpod.git
      ref: <COMMIT_SHA>
      path: packages/co_offline_sync_client
  # 코어 타입을 직접 import하는 앱은 명시적으로 선언합니다.
  co_offline_sync:
    git:
      url: https://github.com/coco-de/co-serverpod.git
      ref: <COMMIT_SHA>
      path: packages/co_offline_sync
```

```bash
flutter pub get
```

형제 코어는 패키지 내부에서 `path: ../co_offline_sync`로 연결됩니다. Git으로 설치하면
같은 저장소/커밋의 형제를 사용합니다. Pub workspace에서 기존 코어 override가 있다면
같은 ref로 맞추세요. 이 패키지는 현재 `publish_to: none`이며 Git으로 사용합니다.
Drift 생성 코드는 커밋되어 있어 **소비 앱은 build_runner를 실행할 필요가 없습니다.**

## 구성

| API | 역할 |
|---|---|
| `CoSyncDatabase` | 동기화 행, pending, nodeId, pull 커서, replica 행/커서 저장 |
| `DriftClientSyncStore` | 코어 `ClientSyncStore` 구현 + 스냅샷 기반 query watch |
| `CoSyncRuntime` | 엔진 조립, 쓰기 debounce, 연결/인증/생명주기 트리거, 계정 세대 보호 |
| `SchemaWindowProbe` / `SchemaWindowInfo` | 선택적인 서버 스키마 사전 조회 계약 |
| `CoSyncRemoteException` | 앱 전송 어댑터에서 사용할 수 있는 원격 실패 코드 분류 |
| `ReplicaStore` / `ReplicaPuller` | 서버가 원천인 데이터의 읽기 전용 증분 캐시 |
| `replicaSeededWatch` / `localFirstSeededWatch` | 아직 수신하지 않은 상태와 실제 빈 목록 구분 |

```text
UI / Repository
  ├─ runtime.upsert/delete/restore → Drift → watch → UI
  └─ runtime.syncNow → SyncTransport → 앱 서버의 CoSyncServer
                            ↑                 ↓
                  인증/생성 클라이언트      서버 DB 구현
                  (소비 앱에서 제공)       (소비 앱에서 제공)
```

## 1. 스키마와 런타임 만들기

아래는 앱 부트스트랩 코드의 예입니다. `transport`는 다음 절의 `SyncTransport`
구현이고, `auth`와 로깅 콜백은 소비 앱의 인증/관측 서비스로 바꾸세요.

```dart
import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_offline_sync_client/co_offline_sync_client.dart';

const appSchemaVersion = 1;
const appSyncSchema = {
  'note': ['title', 'body'],
};

final database = CoSyncDatabase.create();
final runtime = CoSyncRuntime(
  database: database,
  transport: transport,
  syncSchema: appSyncSchema,
  schemaVersion: appSchemaVersion,
  maxFieldValueChars: 64 * 1024, // 예시 정책. 서버의 필드 제한과 맞출 것
  isAuthenticated: () => auth.isAuthenticated,
  onSyncError: (error, stack) => logSyncError(error, stack),
);
```

`syncSchema`, `schemaVersion`, `maxFieldValueChars`는 필수입니다. 공용 패키지에는
앱별 스키마 기본값이 없습니다. 한 앱 세션에는 같은 DB를 사용하는 런타임 하나를
등록하세요. Flutter 플러그인을 쓰는 앱은 부트스트랩에서
`WidgetsFlutterBinding.ensureInitialized()` 후 DB를 생성합니다.

`CoSyncDatabase.create()`는 네이티브에서 `co_sync`라는 이름으로 DB를 열고,
웹에서는 WASM worker 옵션을 사용합니다. `flutter test`에서는 메모리 executor를
선택합니다. 직접 테스트/계정별 DB를 제공하려면 `CoSyncDatabase(queryExecutor)`를
사용하세요. DB 이름과 SQLite 스키마 버전 **3**은 기존 `co_sync`와 동일합니다.
이 DB 버전과 앱 동기화 스키마의 `schemaVersion`은 서로 다른 버전입니다.

## 2. Serverpod 또는 HTTP 연결

코어의 `SyncTransport`를 구현합니다. 생성된 Serverpod 타입에 공용 패키지가
의존하지 않도록 아래 [예제 어댑터](example/json_sync_transport.dart)처럼 콜백으로 연결합니다.
`JsonSyncTransport`는 예제에 정의한 클래스이며 패키지에서 export하는 타입은 아닙니다.

```dart
final transport = JsonSyncTransport(
  pushJson: (payload) => client.coSync.push(payload),
  pullJson: (payload) => client.coSync.pull(payload),
);
```

여기서 `client.coSync`는 **소비 앱이 구현하고 생성한** Serverpod endpoint입니다.
서버에서 `SyncPushRequest`/`SyncPullRequest`를 디코드하고 `CoSyncServer`로 처리한 뒤
JSON 문자열을 돌려줍니다. endpoint와 DB 저장소 구현은 이 패키지에 들어 있지 않습니다.
HTTP에서도 같은 콜백 안에서 요청·인증·응답 처리를 구현할 수 있습니다.

원격 타입드 예외는 앱에서 `CoSyncRemoteException(code:, message:)`으로 변환할 수
있습니다. 네트워크/타임아웃은 원래 예외를 전달하면 됩니다. 알려진 코드의 분류는 다음과
같으며, 이 클래스가 서버 응답을 자동 변환하는 것은 아닙니다.

| 코드 | 의미 | 분류 |
|---|---|---|
| `schema_outdated` | 앱이 서버 지원 창보다 오래됨 | 영구, 앱 업데이트 |
| `schema_server_behind` | 서버가 앱 스키마를 아직 지원하지 않음 | 일시, 롤아웃 대기 |
| `schema_mismatch` | 동일 버전의 서명 충돌 | 영구, 배포 결함 |
| `protocol` | 프로토콜/페이로드 계약 위반 | 영구, 앱 결함 |
| `payload_too_large` | 서버 크기 제한 초과 | 영구, 데이터 분할/크기 조정 |
| `clock_drift` | 원격 HLC가 허용 범위를 넘음 | 시각 확인 후 재시도 |

`isPermanent`는 호출자가 분기할 수 있는 정보입니다. 런타임이 이 값만으로 모든
재시도를 중단하지는 않으므로 같은 영구 실패를 계속 보내지 않도록 앱 정책을 연결하세요.

## 3. 로컬 쓰기와 조회

```dart
// 실제 rowId는 UUID 또는 도메인에서 정한 충돌 없는 ID를 사용합니다.
await runtime.upsert('note', 'note-1', {'title': '제목', 'body': '초안'});
await runtime.upsert('note', 'note-1', {'body': '오프라인에서도 저장'});
final note = await runtime.read('note', 'note-1');

await runtime.delete('note', 'note-1');  // tombstone, 물리 삭제 아님
await runtime.restore('note', 'note-1'); // 기존 값 유지한 복원
```

쓰기는 네트워크를 기다리지 않고 SQLite에 반영됩니다. 변경한 필드만 전달하면 나머지
필드는 유지됩니다. `read`는 없는 행에는 null, 삭제된 행에는 `isDeleted == true`를
반환합니다. 목록 watch는 기본적으로 삭제 행을 제외합니다.

값은 JSON 호환 값으로 인코딩합니다. 필드 길이 검사는 String의 Dart `length`, 그 외는
`jsonEncode(value).length`를 사용하며 UTF-8 바이트 제한과는 다릅니다.
상한을 넘으면 pending에 넣기 전에 `CoSyncFieldTooLargeError`가 발생합니다.

```dart
final notes = runtime.store.watchLogicalTable('note');
final noteCount = runtime.store.watchLogicalTableCount('note');

final subscription = notes.listen((rows) {
  final values = rows.map((row) => row.valuesView()).toList();
  renderNotes(values); // 앱의 상태 관리 계층에 전달
});
// 화면/리포지토리 종료 시
await subscription.cancel();
```

`watchLogicalTable`은 구독 즉시 현재 스냅샷을 제공하고 로컬 쓰기, pull 병합,
`clearAll`에 따라 다시 emit합니다. `runtime.changes`는 초기 스냅샷과 replay가 없는
broadcast 이벤트여서 UI 목록의 원천으로 쓰지 않습니다.
대량 변경에서 emit을 합치려면 watch의 `coalesceWindow` 옵션을 사용하세요.

## 4. 자동 동기화와 생명주기

```dart
runtime.bindOnlineStream(onlineStream);         // Stream<bool>
runtime.bindForegroundStream(foregroundStream); // Stream<bool>, resumed이면 true

// 인증 자격을 설치하고 isAuthenticated가 true가 된 직후
await runtime.onAuthenticated();

// 새로고침 버튼 등
final report = await runtime.syncNow();
if (report != null) {
  recordSyncCounts(report.pushedRows, report.pulledChanges);
}
```

| 트리거 | 동작 |
|---|---|
| 로컬 쓰기 | 기본 2초 debounce 후 온라인/인증 상태이면 동기화 |
| 첫 online / offline → online | 스키마 창을 조회한 뒤 동기화 |
| `onAuthenticated` | 로그인 직후 동기화 및 자동 실행 재개 |
| foreground 복귀 | 연결·인증·정책 조건을 확인해 동기화 |
| foreground 주기 | 기본 60초, `bindForegroundStream`을 연결한 경우에만 예약 |
| `syncNow` | 진행 중인 sync에 합류, 실행 중 새 쓰기가 있으면 추가 회수 |

`writeSyncDebounce`, `periodicSyncInterval`, `isLifecycleSyncEnabled`로 앱 정책을
주입합니다. 연결/생명주기 플러그인은 번들하지 않습니다. `syncNow()`는 실패를 던지지
않고 null을 반환하며 `lastError`와 `onSyncError`로 알립니다. 미인증, 명시적 오프라인,
구버전 앱 차단, reset/dispose에 의해 취소된 경우에도 null일 수 있으므로 null만으로
서버 실패를 단정하지 마세요. 코어 `CoSyncClient.sync()`의 실패 전파 방식과 다릅니다.

로그인 게이트를 생략하면 항상 인증된 것으로 간주합니다. 다중 사용자 앱은 반드시
`isAuthenticated`를 전달하세요. 온라인 스트림이 아직 연결되지 않았다면 수동
`syncNow`는 통신을 시도할 수 있습니다.

### 스키마 사전 확인

서버 현행/최소 버전/현행 서명을 반환하는 `SchemaWindowProbe`를 앱에서 구현하고
런타임의 `schemaProbe`에 전달합니다.

```dart
class AppSchemaProbe implements SchemaWindowProbe {
  AppSchemaProbe(this.fetch);
  final Future<SchemaWindowInfo> Function() fetch;

  @override
  Future<SchemaWindowInfo> fetchSchemaWindow() => fetch();
}
```

`verifySchemaWindow()`의 결과는 `schemaStatus`(`ValueListenable`)와
`onSchemaStatus`로 관찰합니다. `appOutdated`는 업데이트 안내,
`serverBehind`는 서버 배포 대기, `signatureConflict`는 설정/배포 오류입니다.
조회 실패는 `unknown`입니다. 창 안의 구버전 `compatible` 판정은 사전 UX 신호이고,
실제 push/pull에서는 코어 서버가 해당 버전 서명을 다시 검증합니다.

## 5. 로그아웃과 DB 소유권

기존 계정의 작업이 새 계정의 DB를 다시 채우지 않도록 순서를 지킵니다.

```dart
// 1. 먼저 앱의 인증 상태를 false로 전환하고 쓰기 진입을 중단합니다.
// 2. 이전 세대의 sync를 무효화합니다. reset 자체는 데이터를 지우지 않습니다.
await runtime.reset();
// 3. 미전송 변경도 포함해 해당 계정의 동기화 상태를 삭제합니다.
await runtime.store.clearAll();
// 4. 다음 로그인에서 자격을 설정하고 onAuthenticated()를 호출합니다.
```

`reset`은 진행 중 작업을 기본 3초까지 기다리고 세대 검사로 늦은 sync 응답의 저장을
막습니다. `clearAll`은 sync 행, pending, nodeId, cursor, 로컬 메타데이터를 지웁니다.
**읽기 전용 replica 행/커서는 지우지 않습니다.**

Replica를 함께 쓰면 앱에서 새 pull을 중단하고 진행 중인 pull이 완료되도록 기다린 후
각 도메인에 `ReplicaStore.clearDomain`을 호출해야 합니다. `ReplicaPuller.dispose`는
연결 구독만 해제하며 진행 중인 네트워크 요청을 취소하지 않습니다. 런타임의 세대 보호가
replica puller에 자동 적용된다고 가정하지 마세요. 계정별 DB와 puller를 재생성하는
방법도 가능합니다.

앱 종료 시 `await runtime.dispose()`를 호출합니다. 이 메서드는 스토어와 전달받은 DB도
닫습니다. 같은 DB를 공유하는 replica 구독/작업을 먼저 정리하고 DB를 중복으로 닫지 마세요.

## 6. 서버 원천 데이터의 읽기 전용 replica

결제 결과/권한/상품 메타데이터처럼 클라이언트가 CRDT로 수정하면 안 되는 데이터는
별도의 replica로 캐시할 수 있습니다. 서버는 도메인별 증분 조회와 tombstone을 제공합니다.

```dart
final replicas = ReplicaStore(database);
final puller = ReplicaPuller(
  store: replicas,
  domains: {
    'catalog': (cursor) async {
      final response = await api.pullCatalog(cursor: cursor, limit: 200);
      return ReplicaPage(
        rows: [
          for (final row in response.rows)
            ReplicaRowChange(
              rowId: row.id,
              dataJson: row.json,
              serverUpdatedAtMillis: row.updatedAtMillis,
              deleted: row.deleted,
            ),
        ],
        nextCursor: response.nextCursor,
        hasMore: response.hasMore,
      );
    },
  },
  onError: (domain, error, stack) => logReplicaError(domain, error, stack),
);

await puller.pullAll();
await puller.pull({'catalog'}); // 필요한 도메인만 회수
final catalogStream = replicas.watchDomain('catalog');
final countStream = replicas.watchDomainCount('catalog');
```

`api`/응답 DTO는 앱에서 제공합니다. `applyPage`는 행과 커서를 같은 트랜잭션으로
저장합니다. 도메인별 실패는 `lastErrors`/`onError`로 노출되고 다른 도메인은 진행됩니다.
한 번에 도메인당 기본 50페이지까지 받고, 남은 페이지는 다음 트리거에서 이어집니다.

`watchDomainJoin`은 replica끼리, `watchLogicalTableJoinReplica`는 동기화 논리 행과
replica를 조인합니다. 조인 규칙과 JSON 해석은 앱에서 정합니다. 결합할 키는 서버와
클라이언트에서 같아야 합니다.

### 최초 빈 목록 처리

`replicaSeededWatch`는 replica 커서/조회 결과를 사용합니다. `localFirstSeededWatch`는
sync 완료 여부와 replica 회수 결과를 함께 사용하며 **sync → replica pull** 순서로
회수합니다. 이미 로컬 값이 있으면 즉시 내보냅니다. 두 경로가 아직 시드되지 않은 빈
값은 보류하고, **둘 중 하나라도 시드되면** 빈 값을 내보냅니다. 모든 도메인 수신 완료를
의미하는 전역 준비 완료 신호로 사용하면 안 됩니다. `gapKeys`로 조인 상대가 빠진 키를
알려 주면 같은 갭에 대한 반복 요청을 억제하면서 재회수할 수 있습니다.

## 7. 웹 설정

기본 factory는 앱의 base URL 기준 `sqlite3.wasm`과 `drift_worker.js`를 요청합니다.
두 파일을 **소비 앱의 web 배포 산출물**에 포함하고 사용 중인 Drift/sqlite3 버전에
맞추세요. 다운로드한 worker가 `drift_worker.dart.js`라면 기본 경로인
`drift_worker.js`로 이름을 맞추거나 커스텀 executor에 그 URL을 지정합니다.
WASM 파일은 `Content-Type: application/wasm`으로 제공해야 합니다. 이 라이브러리는 웹 자산을 자동 복사하거나 worker를 생성하지 않습니다.

커스텀 URL/worker 옵션이 필요하면 `driftDatabase(name: ..., web: DriftWebOptions(...))`
등으로 executor를 만든 뒤 `CoSyncDatabase(executor)`에 전달합니다. 브라우저 저장소
기능/격리 헤더에 따라 Drift가 선택하는 구현이 달라지므로 네이티브 SQLite 테스트만으로
웹 구동까지 검증되었다고 볼 수 없습니다. 상세 설정은
[Drift 웹 설정](https://drift.simonbinder.eu/platforms/web/)을 참고하세요.

## 실행 가능한 예제와 검증

[예제 테스트](example/sync_example_test.dart)는 앱별 스키마, 두 SQLite 메모리 DB,
JSON 전송 왕복, 로컬 쓰기/원격 수신/삭제/복원/계정 초기화를 실행합니다.
Flutter 화면이나 실제 서버 없이 실행할 수 있습니다.

```bash
cd packages/co_offline_sync_client
flutter pub get
flutter analyze --fatal-infos
flutter test test example
```

Drift 테이블을 수정하는 패키지 유지보수자만 생성 코드를 재생성합니다.

```bash
dart run build_runner build --delete-conflicting-outputs
```

## 기존 co_sync에서 이동

| 이전 | 공용 패키지 |
|---|---|
| `package:co_sync/co_sync.dart`의 공용 구현 | `package:co_offline_sync_client/co_offline_sync_client.dart` |
| `CoSyncRuntime`의 유니북 스키마 기본값 | `syncSchema`와 `schemaVersion`을 필수 주입 |
| `ServerpodSyncTransport(pod.Client)` | 앱별 생성 클라이언트 어댑터로 유지 |
| `serverpodReplicaFetch`의 앱 DTO 변환 | 앱별 어댑터로 유지 |
| DB 이름, 테이블, schemaVersion 3, pending, HLC, cursor | 기존 형식 유지 |

유니북은 `package/co_sync`를 얇은 호환 어댑터로 유지하므로 기존 import와 DI 타입을
바꿀 필요가 없습니다. 다른 앱은 이 패키지를 직접 사용하고 자신의 스키마와 전송을
주입합니다. 코어 프로토콜/서버 저장소 계약은 [코어 README](../co_offline_sync/README.md)를
참고하세요.
