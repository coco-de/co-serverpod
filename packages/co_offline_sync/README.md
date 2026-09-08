# co_offline_sync

순수 Dart로 구현한 offline-first 동기화 엔진입니다. 로컬에서 먼저 쓰고, 연결이
복구되면 행 상태를 push/pull하여 여러 기기의 데이터를 병합합니다. 특정 DB,
Flutter, Serverpod 생성 코드에 의존하지 않습니다.

## 어떤 패키지를 쓰나요?

| 패키지 | 역할 | 사용처 |
|---|---|---|
| `co_offline_sync` | HLC, 필드별 LWW 병합, 삭제/복원, 프로토콜, 클라이언트/서버 엔진 | Dart 서버, 커스텀 클라이언트 |
| [`co_offline_sync_client`](../co_offline_sync_client/README.md) | Drift 저장소, 반응형 조회, 연결/인증/생명주기 런타임, 읽기 전용 replica | Flutter 앱 |

Flutter 앱은 두 번째 패키지의 시작 가이드를 사용하세요. 이 문서는 코어 직접 사용과
서버 구현 계약을 설명합니다. `CoSyncClient`와 `CoSyncServer`는 **이 코어에 모두**
포함됩니다. Serverpod 엔드포인트와 PostgreSQL 저장소 구현은 소비 앱에서 제공합니다.

## 설치

Git 의존성을 사용합니다. 아래 `<COMMIT_SHA>`는 실제 검증한 커밋 SHA로 바꾸세요.
Flutter 어댑터와 함께 쓸 때는 두 패키지의 URL과 ref를 동일하게 맞춥니다.

```yaml
dependencies:
  co_offline_sync:
    git:
      url: https://github.com/coco-de/co-serverpod.git
      ref: <COMMIT_SHA>
      path: packages/co_offline_sync
```

```bash
dart pub get
```

코어의 SDK 제약은 `>=3.8.0 <4.0.0`입니다. Flutter 어댑터의 SDK 제약은 별도입니다.
`pubspec.yaml`의 버전은 패키지 소스 버전이며 pub.dev 배포 여부를 뜻하지 않습니다.

## 1. 두 기기가 동기화하는 최소 예제

아래 코드는 [실행 가능한 예제](example/sync_example.dart)와 같은 흐름입니다.
인메모리 저장소는 프로세스 종료 시 사라지므로 테스트/학습용으로 사용합니다.

```dart
import 'package:co_offline_sync/co_offline_sync.dart';

Future<void> main() async {
  const schema = {
    'note': ['title', 'body'],
  };
  final server = CoSyncServer(
    store: InMemoryServerSyncStore(),
    clock: HlcClock(nodeId: 'server-demo'),
    syncSchema: schema,
  );
  CoSyncClient device(String nodeId) => CoSyncClient(
    store: InMemoryClientSyncStore(),
    transport: InProcessTransport(server),
    clock: HlcClock(nodeId: nodeId),
    syncSchema: schema,
    schemaVersion: 1,
  );
  final phone = device('phone-demo');
  final tablet = device('tablet-demo');

  // 네트워크 왕복 없이 로컬 반영. 실제 앱은 충돌 없는 UUID 등의 rowId를 사용.
  await phone.upsert('note', 'note-1', {'title': '제목', 'body': '초안'});
  await phone.sync();
  await tablet.sync();

  // 서로 다른 필드를 오프라인에서 수정하면 둘 다 보존된다.
  await phone.upsert('note', 'note-1', {'title': '수정한 제목'});
  await tablet.upsert('note', 'note-1', {'body': '태블릿에서 작성'});
  await phone.sync();
  await tablet.sync();
  await phone.sync();
  final note = await phone.read('note', 'note-1');
  assert(note!.values['title'] == '수정한 제목');
  assert(note!.values['body'] == '태블릿에서 작성');

  await phone.delete('note', 'note-1');
  await phone.sync();
  await tablet.sync();
  assert((await tablet.read('note', 'note-1'))!.isDeleted);

  await phone.restore('note', 'note-1');
  await phone.sync();
  await tablet.sync();
  assert(!(await tablet.read('note', 'note-1'))!.isDeleted);
}
```

체크아웃에서 실행:

```bash
cd packages/co_offline_sync
dart pub get
dart --enable-asserts run example/sync_example.dart
```

`read`는 없는 행에 `null`, 삭제된 행에는 `isDeleted == true`인 `RowView`를
반환합니다. `sync()`는 push 후 pull을 실행하며, 성공 시
`SyncReport(pushedRows, pulledChanges)`를 반환합니다. 코어에서 발생한 실패는
호출자에게 전파됩니다. 자동 재시도와 연결성 감지는 코어가 수행하지 않습니다.

## 2. 데이터 모델과 병합 규칙

- 스키마는 `테이블명 → 동기화할 필드명 목록`입니다. 실제 SQL 테이블이나 코드를
  생성하지 않으며, 요청 서명과 필드 검증에 쓰입니다.
- `rowId`는 같은 논리 행을 모든 기기에서 식별하는 문자열입니다. 서버 기존 int PK를
  교체할 필요는 없으며, 앱에서 UUID 또는 충돌 없는 결정적 ID를 연결합니다.
- 각 필드는 JSON 값과 `Hlc(millis, counter, nodeId)`를 가집니다. 같은 필드를
  수정하면 HLC가 큰 값이 남고, 다른 필드의 수정은 함께 보존됩니다.
- `upsert`에는 바꾼 필드만 전달하세요. 생략한 필드는 유지되고, `null`을 전달하면
  그 필드의 값이 null로 변경됩니다. 중첩 Map/List도 **하나의 필드**이므로 내부
  항목 단위 협업 편집은 별도의 행/필드 모델링이 필요합니다.
- 값은 JSON 호환 값이어야 합니다. `DateTime`, 바이너리, 도메인 객체는 앱 코덱에서
  문자열/숫자/JSON으로 변환합니다. `$`로 시작하는 앱 필드는 금지됩니다.
- 전송은 행 상태 전체를 사용합니다. 중복 전송과 재시도는 멱등이며, 병합의 교환·결합·
  멱등 성질은 [병합 테스트](test/merge_test.dart)로 검증합니다.

### 삭제와 복원

`delete`는 예약 필드 `$deleted`를 true로 기록하고 `restore`는 false로 기록합니다.
물리 삭제가 아니므로 기존 필드 값이 유지됩니다.

| 정책 | 삭제 상태 판정 |
|---|---|
| `TombstonePolicy.deleteWins` (기본) | `$deleted`의 현재 값이 true면 삭제. 일반 필드 편집만으로 복원되지 않음 |
| `TombstonePolicy.editWins` | 삭제 스탬프보다 나중인 일반 필드가 있으면 활성으로 해석 |

정책은 저장 상태를 읽는 방식입니다. 어댑터가 삭제 여부를 별도 컬럼에 물질화한다면
정책 변경 시 그 컬럼도 다시 계산해야 합니다. 삭제 행의 보관 기간/GC와 장기간
오프라인 기기의 재시드는 앱이 설계해야 합니다. 이 패키지는 tombstone GC를 제공하지 않습니다.

### 시계와 재시작

`nodeId`는 설치/저장소 단위로 영속화하고 기기끼리 공유하지 않습니다. 클라이언트는
첫 조작 전에 `ClientSyncStore.maxHlc()`로 시계를 자동 시드합니다. 저장된 HLC를
잃거나 nodeId를 다른 기기에 복제하면 병합 전제가 깨질 수 있습니다.
`ClockDriftException`은 허용 범위를 넘어 미래인 원격 시각을 거부합니다.

## 3. 네트워크 전송 연결

`SyncTransport`의 두 메서드를 구현합니다. 다음은 생성 클라이언트에 의존하지 않는
예시 어댑터입니다. 이 클래스는 예제 코드이며 패키지 공개 API가 아닙니다.

```dart
import 'dart:convert';
import 'package:co_offline_sync/co_offline_sync.dart';

class JsonSyncTransport implements SyncTransport {
  JsonSyncTransport({required this.pushJson, required this.pullJson});

  final Future<String> Function(String payload) pushJson;
  final Future<String> Function(String payload) pullJson;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    final response = await pushJson(jsonEncode(request.toJson()));
    return SyncPushResponse.fromJson(
      jsonDecode(response) as Map<String, Object?>,
    );
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    final response = await pullJson(jsonEncode(request.toJson()));
    return SyncPullResponse.fromJson(
      jsonDecode(response) as Map<String, Object?>,
    );
  }
}
```

Serverpod에서는 앱이 만든 endpoint의 `push(String)` / `pull(String)` 메서드를
콜백으로 전달할 수 있습니다. HTTP라면 인증 헤더, 타임아웃, 상태 코드 처리를 콜백에
구현합니다. 와이어 JSON은 `toJson/fromJson`을 쓰고 축약 키를 직접 조립하지 마세요.

서버 endpoint는 인증한 사용자 범위의 `CoSyncServer`에
`SyncPushRequest.fromJson` → `handlePush` → 응답 `toJson` 순서로 연결합니다.
`pull`도 같은 방식입니다. **nodeId와 schemaSignature는 인증 정보가 아닙니다.**
스키마 서명이 맞아도 소유권, 쓰기 권한, 필드 값의 도메인 규칙은 서버가 별도로 검증해야 합니다.

### 요청 크기

`CoSyncClient`의 기본 push 분할 상한은 **400행 / JSON UTF-8 6 MiB**입니다.
`maxChangesPerPush`, `maxBytesPerPush`로 조정할 수 있습니다. 한 행이 바이트 상한을
넘으면 분할할 수 없으므로 `SyncProtocolException`이 발생합니다. 큰 문서/필기는
앱에서 행을 나누거나 파일을 외부에 저장하고 참조를 동기화하세요.

이 상한은 클라이언트의 요청 분할 설정입니다. 서버의 요청 바이트·행 수·필드 길이
하드 제한은 endpoint에서 별도로 적용해야 합니다. 여러 청크 중 뒤쪽이 실패하면
앞쪽의 성공까지 롤백되지는 않습니다. 코어 push는 요청 전체의 원자적 트랜잭션을
보장하지 않으므로 필요한 경우 서버 어댑터에서 트랜잭션 경계를 제공합니다.

## 4. 영속 저장소 구현 계약

Flutter는 [`DriftClientSyncStore`](../co_offline_sync_client/README.md)를 재사용할 수
있습니다. 다른 플랫폼은 다음 계약을 구현합니다.

| `ClientSyncStore` 메서드 | 지켜야 할 동작 |
|---|---|
| `getRow` / `putRow` | HLC를 포함한 RowState 저장. 병합 자체는 엔진이 수행 |
| `putRow(pending: true)` | 로컬 변경을 pending으로 기록 |
| `putRow(pending: false)` | 원격 병합이 기존 로컬 pending을 지우지 않음 |
| `pendingRows` / `clearPending` | 전송 스냅샷 HLC 이하일 때만 ack 처리하여 전송 중 새 편집 보존 |
| `loadCursor` / `saveCursor` | pull 커서 영속화. 페이지 반영 전 커서를 앞당기지 않음 |
| `maxHlc` | 재시작 시 모든 저장 행의 최대 HLC 제공 |
| `changes` | 저장 후 테이블/행/출처 변경 통지 |

`changes`는 무효화 이벤트입니다. 초기 목록, 계정 데이터 삭제 알림 등을 UI에
제공하려면 저장소의 스냅샷 기반 query watch를 사용하세요.

서버는 `ServerSyncStore`의 `getRow`, `putRow`, `nextSeq`, `changesSince`를 구현합니다.
다중 인스턴스 환경에서 다음을 함께 보장해야 합니다.

1. 인증 사용자/테넌트별 행과 커서 조회 범위를 격리합니다.
2. **읽기 → 병합 → 저장 전체**를 DB 트랜잭션/락으로 직렬화합니다. 각 메서드만
   따로 트랜잭션으로 감싸면 같은 행의 동시 수정이 유실될 수 있습니다.
3. seq 발급과 변경의 조회 가시성이 커서 순서를 보존해야 합니다. DB 시퀀스만 발급하고
   작은 seq의 트랜잭션이 늦게 커밋되면 먼저 전진한 pull 커서가 이를 놓칠 수 있습니다.
   잠금/커밋 순서 또는 안전한 변경 로그 설계를 사용합니다.
4. `changesSince`는 seq 오름차순으로 페이지를 제공하고 `nextSeq`/`hasMore`를 정확히
   계산합니다. 필터링된 페이지도 커서가 전진할 수 있어야 합니다.

인메모리 서버 저장소는 이 프로덕션 계약의 대체물이 아닙니다.

## 5. 스키마 버전 호환 창

앱 업데이트와 서버 배포 사이에는 여러 스키마가 공존합니다. `SchemaRegistry`로
받아 줄 버전을 명시하세요.

```dart
final registry = SchemaRegistry([
  SchemaVersion(version: 1, tables: {'note': ['title', 'body']}),
  SchemaVersion(version: 2, tables: {'note': ['title', 'body', 'color']}),
]);
final server = CoSyncServer.withRegistry(
  store: InMemoryServerSyncStore(), // 실서비스는 사용자 범위의 DB 구현
  clock: HlcClock(nodeId: 'server-demo'),
  registry: registry,
);
final client = CoSyncClient(
  store: InMemoryClientSyncStore(),
  transport: InProcessTransport(server),
  clock: HlcClock(nodeId: 'device-demo'),
  syncSchema: registry.current.tables,
  schemaVersion: registry.current.version,
);
```

| 규칙 | 동작 |
|---|---|
| 서명이 정본 | 버전 번호는 불일치 원인 분류용 힌트. 서명으로 실제 스키마를 확정 |
| 가산적 진화 | 창 안에서는 테이블/컬럼 추가만 허용. 제거/이름 변경은 새 필드를 병존시키는 방식으로 전환 |
| 신 컬럼 optional | 구 앱이 만든 행에는 신 필드가 없으므로 소비 코드에서 기본값/nullable 처리 |
| push 검증 | 레지스트리 현행이 아는 컬럼과 예약 필드를 검증 |
| pull 투영 | 구 앱에는 아는 컬럼만 전달. tombstone과 복원은 보존하며 커서는 전진 |
| 시계 보정 | 투영 전 최대 스탬프를 응답 HLC로 전달하여 구 앱의 시계가 뒤처지지 않게 함 |
| 창 닫기 | 구 버전을 레지스트리에서 빼면 그 앱은 `clientOutdated`로 거부 |

호환 창에서는 `deleteWins`를 권장합니다. `editWins`는 구 앱이 신 컬럼의 스탬프를
보지 못해 버전마다 삭제 뷰가 다를 수 있습니다. `protocolVersion` 변경은 모든 서명을
바꾸므로 일반적인 컬럼 추가와 같은 방식으로 취급하면 안 됩니다.

## 6. 실패 처리

| 예외 | 의미 / 처리 |
|---|---|
| `SchemaMismatchException` + `clientOutdated` | 지원 창보다 오래된 앱. 업데이트 안내 |
| `SchemaMismatchException` + `serverBehind` | 서버 롤아웃 대기 후 재시도 |
| `SchemaMismatchException` + `signatureConflict` | 같은 버전 번호의 스키마 불일치. 배포/설정 확인 |
| `SyncProtocolException` | 잘못된 필드·예약 키·커서·limit·분할 불가능한 크기 등의 계약 위반 |
| `ClockDriftException` | 기기/서버 시각 확인. 무조건 재시도하지 않음 |
| `HlcCounterOverflowException` | 같은 밀리초의 논리 카운터 상한 초과 |
| 전송 예외 | 네트워크/인증 오류는 전송 어댑터가 전달. 앱에서 재시도 정책 적용 |

실패 때문에 pending이나 tombstone을 임의로 삭제하지 마세요. 구체적인 인증 오류 코드,
업데이트 화면, 백오프, 관측 지표는 소비 앱의 책임입니다.

## 개발과 검증

동기화 두 패키지는 인증 패키지의 루트 Pub workspace와 독립적으로 resolve합니다.
코어를 테스트할 때 Flutter와 Serverpod 인증 의존성을 설치할 필요가 없습니다.

```bash
cd packages/co_offline_sync
dart pub get
dart analyze --fatal-infos
dart test
dart --enable-asserts run example/sync_example.dart
```

설계 배경: coco-de/unibook#12634. `serverpod_offline_sync`, `sql_crdt`,
`offline_sync_engine`의 설계를 참고했으며 런타임 의존성으로 사용하지 않습니다.
