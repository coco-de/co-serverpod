import 'exceptions.dart';
import 'schema_signature.dart';

/// 동기화 스키마의 한 버전 — `테이블 → 컬럼 목록` 과 그 서명.
///
/// [tables] 는 정준화(테이블·컬럼 정렬)된 불변 사본으로 보관되므로 선언
/// 순서와 무관하게 같은 스키마면 같은 [signature] 를 갖는다.
class SchemaVersion {
  /// [version] 은 1 이상의 정수, [tables] 는 비어 있지 않아야 하며 각 테이블은
  /// 컬럼이 1개 이상, 컬럼명은 비어 있지 않고 `$` 로 시작하지 않으며 한 테이블
  /// 안에서 중복되지 않아야 한다 (위반은 [ArgumentError]).
  SchemaVersion({
    required this.version,
    required Map<String, List<String>> tables,
  }) : tables = _canonical(_validated(tables)),
       signature = computeSchemaSignature(tables) {
    if (version < 1) {
      throw ArgumentError.value(version, 'version', 'must be >= 1');
    }
  }

  /// 단조 증가하는 스키마 버전 번호 (사람·텔레메트리용).
  final int version;

  /// 정준화된 `테이블 → 정렬된 컬럼 목록` (불변).
  final Map<String, List<String>> tables;

  /// [computeSchemaSignature] 결과 — 와이어 대조에 쓰이는 실제 식별자.
  final String signature;

  /// `테이블 → 컬럼 집합` (페이로드 검증·pull 투영용).
  late final Map<String, Set<String>> columnSets = Map.unmodifiable({
    for (final e in tables.entries) e.key: Set.unmodifiable(e.value.toSet()),
  });

  /// 이 버전이 [older] 의 모든 테이블·컬럼을 포함하는가 (가산적 진화 판정).
  bool isSupersetOf(SchemaVersion older) {
    for (final entry in older.tables.entries) {
      final mine = columnSets[entry.key];
      if (mine == null) return false;
      for (final column in entry.value) {
        if (!mine.contains(column)) return false;
      }
    }
    return true;
  }

  static Map<String, List<String>> _validated(
    Map<String, List<String>> tables,
  ) {
    if (tables.isEmpty) {
      throw ArgumentError.value(tables, 'tables', 'must not be empty');
    }
    for (final entry in tables.entries) {
      final table = entry.key;
      if (table.isEmpty) {
        throw ArgumentError.value(tables, 'tables', 'empty table name');
      }
      if (entry.value.isEmpty) {
        throw ArgumentError.value(tables, 'tables', '$table has no columns');
      }
      final seen = <String>{};
      for (final column in entry.value) {
        if (column.isEmpty) {
          throw ArgumentError.value(tables, 'tables', '$table: empty column');
        }
        if (column.startsWith(r'$')) {
          throw ArgumentError.value(
            tables,
            'tables',
            r'$table.$column: `$` prefix is reserved',
          );
        }
        if (!seen.add(column)) {
          throw ArgumentError.value(
            tables,
            'tables',
            '$table: duplicate column $column',
          );
        }
      }
    }
    return tables;
  }

  static Map<String, List<String>> _canonical(
    Map<String, List<String>> tables,
  ) => Map.unmodifiable({
    for (final table in tables.keys.toList()..sort())
      table: List<String>.unmodifiable([...tables[table]!]..sort()),
  });

  @override
  String toString() => 'SchemaVersion(v$version, $signature)';
}

/// 서버가 **동시에 받아들이는** 스키마 버전들의 창(window).
///
/// ## 왜 필요한가
///
/// 서명 대조는 전부-아니면-전무라, 서버가 컬럼 하나를 더하는 순간 아직
/// 업데이트하지 않은 모든 앱의 동기화가 영구 실패한다. 이 클래스는 서버가
/// 현행뿐 아니라 **이전 버전 N개** 를 함께 알게 해, 구 클라이언트가 자기가
/// 아는 컬럼만으로 계속 push/pull 하게 한다.
///
/// ## 안전 조건 — 가산적 진화만 허용한다
///
/// 창 안의 모든 버전은 **이전 버전의 상위집합**이어야 한다 (테이블·컬럼은
/// 추가만, 제거·이름 변경·의미 변경 금지). 생성자가 이를 검증해 위반이면
/// [ArgumentError] 다. 이 조건 아래에서:
///
/// - 구 클라이언트의 push 는 자기 컬럼(또는 롤링 배포 중 받아 둔 창 안 컬럼)
///   만 나르고, 서버 병합은 필드 단위라 **신 컬럼 값이 보존**된다 (LWW join
///   은 없는 필드를 건드리지 않는다).
/// - 구 클라이언트의 pull 은 서버가 그 버전의 컬럼으로 **투영**해 내려보내므로
///   모르는 필드를 저장했다가 되밀어 올리는 일이 없다.
/// - 신 컬럼은 **nullable 이거나 애플리케이션 기본값**이 있어야 한다 — 구
///   클라이언트가 만든 새 행에는 그 필드가 없기 때문이다. 이건 타입 시스템이
///   아니라 소비 측 규약으로 지킨다.
///
/// 제거·이름 변경이 정말 필요하면 **새 테이블/새 컬럼을 추가**하고 옛 것을
/// 창이 닫힐 때까지 병존시킨다.
///
/// ## 알려진 한계
///
/// - **`TombstonePolicy.editWins` 는 창 안에서 버전 간 뷰가 갈릴 수 있다.**
///   구 클라이언트는 투영 때문에 신 컬럼의 스탬프를 보지 못하므로, 삭제 뒤에
///   신 컬럼만 편집되면 신 클라이언트는 alive · 구 클라이언트는 deleted 로 본다
///   (저장 상태는 같다 — 공유 컬럼이 다시 편집되면 수렴). 호환 창을 운영하는
///   동안은 기본값 `deleteWins` 를 권한다.
/// - **[protocolVersion] 을 올리면 창이 통째로 닫힌다.** 서명에 프로토콜
///   버전이 들어가므로 bump 하는 순간 창 안 모든 버전의 서명이 바뀌어 전
///   클라이언트가 불일치가 된다 — 이 클래스가 막으려는 사고와 같다. 와이어
///   정리 겸 올리지 말고, 앱 강제 업데이트와 같은 시점에만 올린다.
///
/// ## 창을 닫는 법
///
/// 오래된 버전을 목록에서 빼면 그 버전 클라이언트는
/// [SchemaMismatchReason.clientOutdated] 로 거부된다 — 앱 강제 업데이트와
/// 같은 시점에 한다.
class SchemaRegistry {
  /// [versions] 는 버전 번호 오름차순이어야 하고, 각 버전은 직전 버전의
  /// 상위집합이어야 하며, 서명이 서로 달라야 한다.
  SchemaRegistry(List<SchemaVersion> versions)
    : versions = List.unmodifiable(versions) {
    if (versions.isEmpty) {
      throw ArgumentError.value(versions, 'versions', 'must not be empty');
    }
    final seenSignatures = <String>{};
    for (var i = 0; i < versions.length; i++) {
      final v = versions[i];
      if (!seenSignatures.add(v.signature)) {
        throw ArgumentError.value(
          versions,
          'versions',
          'duplicate schema signature at v${v.version}',
        );
      }
      if (i == 0) continue;
      final prev = versions[i - 1];
      if (v.version <= prev.version) {
        throw ArgumentError.value(
          versions,
          'versions',
          'versions must strictly increase (v${prev.version} → v${v.version})',
        );
      }
      if (!v.isSupersetOf(prev)) {
        throw ArgumentError.value(
          versions,
          'versions',
          'v${v.version} drops a table/column of v${prev.version} — only '
              'additive evolution is allowed inside a compatibility window',
        );
      }
    }
  }

  /// 버전이 하나뿐인 레지스트리 (호환 창 없음 — 종전 동작과 동일).
  factory SchemaRegistry.single(
    Map<String, List<String>> tables, {
    int version = 1,
  }) => SchemaRegistry([SchemaVersion(version: version, tables: tables)]);

  /// 지원 버전 (오름차순, 불변).
  final List<SchemaVersion> versions;

  /// 현행(최신) 버전.
  SchemaVersion get current => versions.last;

  /// 아직 받아 주는 가장 오래된 버전.
  SchemaVersion get minSupported => versions.first;

  /// 서명으로 버전을 찾는다 (없으면 null).
  SchemaVersion? bySignature(String signature) {
    for (final v in versions) {
      if (v.signature == signature) return v;
    }
    return null;
  }

  /// 버전 번호로 찾는다 (없으면 null).
  SchemaVersion? byVersion(int version) {
    for (final v in versions) {
      if (v.version == version) return v;
    }
    return null;
  }

  /// 요청이 주장하는 서명·버전 힌트로 클라이언트 스키마를 확정한다.
  ///
  /// **서명이 정본**이다 — 서명이 창 안의 어느 버전과 일치하면 버전 힌트와
  /// 무관하게 그 버전을 돌려준다. 일치하지 않으면 버전 힌트로 원인을
  /// 분류해 [SchemaMismatchException] 을 던진다.
  SchemaVersion resolve({required String signature, int? version}) {
    final hit = bySignature(signature);
    if (hit != null) return hit;

    final SchemaMismatchReason reason;
    if (version == null) {
      reason = SchemaMismatchReason.unknown;
    } else if (version < minSupported.version) {
      reason = SchemaMismatchReason.clientOutdated;
    } else if (version > current.version) {
      reason = SchemaMismatchReason.serverBehind;
    } else {
      reason = SchemaMismatchReason.signatureConflict;
    }
    throw SchemaMismatchException(
      expected: current.signature,
      actual: signature,
      reason: reason,
      clientVersion: version,
      minSupportedVersion: minSupported.version,
      currentVersion: current.version,
    );
  }

  @override
  String toString() =>
      'SchemaRegistry(v${minSupported.version}..v${current.version}, '
      '${versions.length} versions)';
}
