import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart'
    show RowState, TombstonePolicy;
import 'package:co_sync/src/drift/co_sync_web_options.dart';
import 'package:co_sync/src/drift/flutter_test_env_stub.dart'
    if (dart.library.io) 'package:co_sync/src/drift/flutter_test_env_io.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';

part 'co_sync_database.g.dart';

/// 동기화 행 상태 테이블.
///
/// 코어 `RowState` 를 JSON 으로 통째 보관한다 — 병합 판단은 코어가 하고 이
/// 테이블은 영속·부기만 담당한다. `maxHlc`/`pendingSnapshotHlc` 는 packed
/// HLC 문자열(고정폭 — **문자열 사전순 == HLC 순서**)이라 SQL 비교로
/// pending 가드를 판정할 수 있다.
@DataClassName('CoSyncRowData')
class CoSyncRows extends Table {
  /// 기본 생성자.
  const CoSyncRows();

  /// 논리 테이블 이름 (drift `Table.tableName` 과의 충돌을 피해 개명).
  TextColumn get logicalTable => text()();

  /// 행 id (전역 고유 문자열).
  TextColumn get rowId => text()();

  /// 코어 `RowState.toJson()` 직렬화.
  TextColumn get stateJson => text()();

  /// 행의 최대 HLC (packed) — pending 가드의 SQL 비교 대상.
  TextColumn get maxHlc => text()();

  /// push 대기 여부.
  BoolColumn get pending => boolean().withDefault(const Constant(false))();

  /// pending 스냅샷 시점의 maxHlc (packed) — ack 해제 가드.
  TextColumn get pendingSnapshotHlc => text().nullable()();

  /// tombstone 물질화 (S7-2, #12753 — v3).
  ///
  /// 코어의 삭제는 `stateJson` 안의 `$deleted` LWW 필드라 SQL 로 걸러지지
  /// 않는다 — 논리 테이블 단위 **watch/COUNT** 가 행마다 JSON 디코드를
  /// 요구하게 되어 성립하지 않았다. `putRow` 가 저장 시점에
  /// `RowState.isDeleted(tombstonePolicy)` 판정을 이 컬럼으로 동기한다.
  ///
  /// ⚠️ 이 값은 **스토어에 배선된 `TombstonePolicy` 기준의 파생값**이다 —
  /// 정책을 바꾸면 기존 행과 어긋나므로, 정책 변경은 재마이그레이션
  /// (전행 재판정)을 동반해야 한다. 판정의 정본은 여전히 `stateJson` 이다.
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// 영구 거부로 **격리**된 행인가 (B4 #13736 — v4).
  ///
  /// 격리는 폐기가 아니라 보류다: `pending` 과 `pendingSnapshotHlc` 는 그대로
  /// 두고 이 플래그만 세운다. `pendingRows()` 가 이 행을 빼므로 매 회차가 같은
  /// 자리에서 멈추지 않고, 해제되면 원래 스냅샷 그대로 재전송된다.
  BoolColumn get quarantined => boolean().withDefault(const Constant(false))();

  /// 격리 사유 코드 (서버 실패 코드 — `payload_too_large` 등).
  TextColumn get quarantineCode => text().nullable()();

  /// 격리 사유 설명 (서버가 남긴 진단 문자열).
  TextColumn get quarantineReason => text().nullable()();

  /// 격리 시각 (epoch millis, UTC).
  IntColumn get quarantinedAtMillis => integer().nullable()();

  @override
  Set<Column> get primaryKey => {logicalTable, rowId};
}

/// 커서 등 소량 key-value 메타.
@DataClassName('CoSyncMetaData')
class CoSyncMeta extends Table {
  /// 기본 생성자.
  const CoSyncMeta();

  /// 메타 키.
  TextColumn get metaKey => text()();

  /// 메타 값.
  TextColumn get metaValue => text()();

  @override
  Set<Column> get primaryKey => {metaKey};
}

/// read-only replica 행 (S6, #12720).
///
/// 서버 SSOT 데이터(내서재 주문파생·도서 메타 등)의 단방향 pull 복제본.
/// CRDT 축(`CoSyncRows`)과 달리 **클라이언트 쓰기·병합·HLC 가 없다** —
/// 서버가 준 최신 상태를 그대로 보관하고, 삭제는 tombstone 플래그로 받는다.
///
/// ## 왜 CoSyncDatabase 동거인가 (배치 결정, 에픽 #12696 판정)
///
/// - 1차 범위(D2)가 **사용자 연관 한정**이라 내용 대부분이 계정 스코프다 —
///   `CacheRegistry` 로그아웃 wipe 상속(#6520, S3-3 등록)이 격리 요구와 정합.
/// - 명시적 로그아웃은 인증 스냅샷을 먼저 지워 오프라인 선복원이 불가하므로
///   "로그아웃 후 오프라인 replica 소비자"는 실측상 존재하지 않는다.
/// - 단일 DB = S7 반응형(drift 쿼리 watch)이 DB 경계 없이 성립.
/// - 공용 카탈로그 전량 복제(후속 D2 재결정 시)는 수명이 달라 **그때 별도
///   DB 를 재평가**한다 — 지금 분리하면 근거 없는 선행 복잡도다.
@DataClassName('CoReplicaRowData')
class CoReplicaRows extends Table {
  /// 기본 생성자.
  const CoReplicaRows();

  /// replica 도메인 (예: `book_order_summary`, `book_meta`).
  TextColumn get domain => text()();

  /// 행 id (도메인 내 고유 — 서버 PK 의 문자열 표현).
  TextColumn get rowId => text()();

  /// 서버 상태의 JSON 직렬화 (thin projection — S6-2 계약).
  TextColumn get dataJson => text()();

  /// 서버 `updatedAt` (epoch millis, UTC) — 진단·정렬용.
  ///
  /// ⚠️ 증분 판정은 이 값이 아니라 **서버가 발급한 opaque 커서**
  /// (`CoReplicaCursors`)로 한다 — 동률·시계 후퇴 처리는 서버 소관.
  IntColumn get serverUpdatedAtMillis => integer()();

  /// 서버측 삭제 여부 (soft-delete 전파).
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {domain, rowId};
}

/// replica 도메인별 pull 커서 (S6).
@DataClassName('CoReplicaCursorData')
class CoReplicaCursors extends Table {
  /// 기본 생성자.
  const CoReplicaCursors();

  /// replica 도메인.
  TextColumn get domain => text()();

  /// 서버가 발급한 opaque 커서 — 다음 pull 의 시작점.
  TextColumn get cursor => text()();

  @override
  Set<Column> get primaryKey => {domain};
}

/// co_sync 로컬 데이터베이스.
///
/// 웹/네이티브/`flutter test` 3분기는 `package:cache` 의 `CacheDatabase`
/// (kobic#10863) 와 동일 계약 — L1 동일 계층이라 의존하지 못해 복제한다.
@DriftDatabase(
  tables: [CoSyncRows, CoSyncMeta, CoReplicaRows, CoReplicaCursors],
)
class CoSyncDatabase extends _$CoSyncDatabase {
  /// 직접 QueryExecutor 를 전달하는 생성자 (테스트: `NativeDatabase.memory()`).
  CoSyncDatabase(super.e);

  /// 크로스 플랫폼 factory.
  ///
  /// - 네이티브: SQLite 파일 (`co_sync.db`)
  /// - 웹: IndexedDB + sqlite3.wasm
  /// - `flutter test`: 인메모리 (pending Timer 잔존 방지 — kobic#10863 계약)
  factory CoSyncDatabase.create() => CoSyncDatabase(
    isRunningUnderFlutterTest
        ? createInMemoryTestExecutor()
        : driftDatabase(
            name: 'co_sync',
            web: kIsWeb ? coSyncDriftWebOptions() : null,
          ),
  );

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (migrator, from, to) async {
      // v1 → v2: replica 테이블 2종 추가 (S6-1, #12720). 기존 CRDT
      // 테이블은 무변경 — 가산적이라 롤백 자유.
      if (from < 2) {
        await migrator.createTable(coReplicaRows);
        await migrator.createTable(coReplicaCursors);
      }
      // v2 → v3: tombstone 물질화 컬럼 (S7-2, #12753). 기존 행은
      // stateJson 의 `$deleted` LWW 필드를 deleteWins(스토어 기본 정책)로
      // 재판정해 백필한다 — 기본값 false 로만 두면 기존 tombstone 이
      // 활성으로 오분류된다. 백필 판정은 `DriftClientSyncStore` 의
      // `materializedDeleted` 와 같은 식이어야 한다 (드리프트 금지).
      if (from < 3) {
        await migrator.addColumn(coSyncRows, coSyncRows.deleted);
        // ⚠️ `select(coSyncRows)` 를 쓰지 않는다 — 생성된 매퍼는 **현행(v4)**
        // 컬럼을 전부 읽으므로, v2 DB 를 여는 이 단계에서는 아직 없는 v4
        // 컬럼에서 null check 로 죽는다. 옛 단계는 그 시점에 존재하던
        // 컬럼만 이름으로 읽어야 한다 (v4 추가 때 실제로 터졌다).
        final rows = await customSelect(
          'SELECT logical_table, row_id, state_json FROM co_sync_rows',
        ).get();
        for (final result in rows) {
          final row = (
            logicalTable: result.read<String>('logical_table'),
            rowId: result.read<String>('row_id'),
            stateJson: result.read<String>('state_json'),
          );
          // 판정은 코어 API 로만 — JSON 형태(`f`/`v` 축약 키)를 손파싱하면
          // 코어 직렬화 변경에 조용히 어긋난다.
          final state = RowState.fromJson(
            jsonDecode(row.stateJson) as Map<String, Object?>,
          );
          if (state.isDeleted(TombstonePolicy.deleteWins)) {
            await (update(coSyncRows)..where(
                  (t) =>
                      t.logicalTable.equals(row.logicalTable) &
                      t.rowId.equals(row.rowId),
                ))
                .write(const CoSyncRowsCompanion(deleted: Value(true)));
          }
        }
      }
      // v3 → v4: 영구 실패 행 격리 컬럼 4종 (B4 #13736). 순수 가산 —
      // 기존 행은 `quarantined=false` 가 옳다(격리된 적이 없다). 백필이
      // 필요 없는 대신 기존 `pending` 부기는 **건드리지 않는다**: 여기서
      // 손대면 아직 올라가지 않은 로컬 변경을 마이그레이션이 지운다.
      if (from < 4) {
        await migrator.addColumn(coSyncRows, coSyncRows.quarantined);
        await migrator.addColumn(coSyncRows, coSyncRows.quarantineCode);
        await migrator.addColumn(coSyncRows, coSyncRows.quarantineReason);
        await migrator.addColumn(coSyncRows, coSyncRows.quarantinedAtMillis);
      }
    },
  );
}
