import 'dart:convert';

import 'hlc.dart';

/// 삭제 여부를 나르는 예약 필드 이름.
///
/// tombstone 을 별도 축이 아니라 **일반 필드와 같은 LWW 규칙**으로 병합하기
/// 위해 예약 필드로 표현한다. 값은 `bool`. 애플리케이션 필드 이름은 `$` 로
/// 시작할 수 없다.
const String kDeletedField = r'$deleted';

/// 한 필드의 값과 그 값이 쓰인 시점의 HLC.
class FieldValue {
  /// [value] 는 JSON 직렬화 가능해야 한다
  /// (`null`/`bool`/`num`/`String`/`List`/`Map`).
  const FieldValue(this.value, this.hlc);

  /// 필드 값 (JSON 호환).
  final Object? value;

  /// 이 값이 쓰인 시점의 스탬프.
  final Hlc hlc;

  /// JSON 표현 (`{"v": ..., "t": "<packed hlc>"}`).
  Map<String, Object?> toJson() => {'v': value, 't': hlc.pack()};

  /// [toJson] 의 역연산.
  factory FieldValue.fromJson(Map<String, Object?> json) =>
      FieldValue(json['v'], Hlc.parse(json['t']! as String));

  @override
  String toString() => 'FieldValue($value @ $hlc)';
}

/// tombstone 해석 정책 — "동시 편집 vs 삭제" 를 어느 쪽으로 해소하는가.
///
/// 어느 정책이든 **저장 상태 자체는 동일**하다 (필드 단위 LWW join). 정책은
/// 저장 상태에서 "이 행이 지금 삭제된 것으로 보이는가" 를 계산하는 **뷰**만
/// 바꾼다. 따라서 정책을 나중에 바꿔도 데이터 마이그레이션이 필요 없다.
enum TombstonePolicy {
  /// 삭제 플래그의 LWW 값이 그대로 승리한다 (기본값).
  ///
  /// 동시 편집이 있어도 삭제 스탬프가 더 나중이면 행은 삭제로 보인다.
  /// 편집된 필드 값 자체는 tombstone 행 안에 보존된다.
  deleteWins,

  /// 삭제 스탬프보다 나중에 쓰인 애플리케이션 필드가 하나라도 있으면
  /// 행이 되살아난 것으로 본다.
  editWins,
}

/// 한 행의 병합 가능한 상태 — 필드별 `(값, HLC)` 의 집합.
///
/// 이 타입은 join-semilattice 원소다: [mergeRowStates] 가 필드별로 더 큰
/// HLC 를 취하는 join 연산이며, 교환·결합·멱등이 성립한다.
class RowState {
  /// [fields] 의 각 키는 컬럼 이름, 예약 필드는 [kDeletedField] 뿐이다.
  RowState({required this.rowId, required Map<String, FieldValue> fields})
    : fields = Map.unmodifiable(fields);

  /// 행의 전역 고유 id (노드 간 충돌하지 않는 문자열 — 예: UUID v7).
  final String rowId;

  /// 필드 이름 → 값·스탬프. 불변 뷰.
  final Map<String, FieldValue> fields;

  /// 이 행에 기록된 가장 큰 HLC (행의 "마지막 수정" 스탬프).
  Hlc get maxHlc {
    Hlc? max;
    for (final fv in fields.values) {
      if (max == null || fv.hlc > max) max = fv.hlc;
    }
    // fields 가 비는 RowState 는 엔진이 만들지 않지만, 방어적으로 zero 반환.
    return max ?? const Hlc.zero('-');
  }

  /// 삭제 플래그 필드 (없으면 null — 한 번도 삭제된 적 없는 행).
  FieldValue? get deletedField => fields[kDeletedField];

  /// [policy] 기준으로 이 행이 삭제 상태로 보이는지 계산한다.
  bool isDeleted(TombstonePolicy policy) {
    final del = deletedField;
    if (del == null || del.value != true) return false;
    switch (policy) {
      case TombstonePolicy.deleteWins:
        return true;
      case TombstonePolicy.editWins:
        for (final entry in fields.entries) {
          if (entry.key == kDeletedField) continue;
          if (entry.value.hlc > del.hlc) return false;
        }
        return true;
    }
  }

  /// 애플리케이션 필드만 (`$` 예약 접두 전체 제외) `이름 → 값` 으로 푼다.
  ///
  /// [kDeletedField] 하나만 거르면, 와이어로 주입된 미지의 `$` 필드가
  /// 소비자에게 그대로 노출된다 (리뷰 발견 4) — 접두 전체를 거른다.
  Map<String, Object?> valuesView() => {
    for (final e in fields.entries)
      if (!e.key.startsWith(r'$')) e.key: e.value.value,
  };

  /// JSON 표현 (`{"id": ..., "f": {name: {v, t}}}`).
  Map<String, Object?> toJson() => {
    'id': rowId,
    'f': {for (final e in fields.entries) e.key: e.value.toJson()},
  };

  /// [toJson] 의 역연산.
  factory RowState.fromJson(Map<String, Object?> json) {
    final rawFields = json['f']! as Map<String, Object?>;
    return RowState(
      rowId: json['id']! as String,
      fields: {
        for (final e in rawFields.entries)
          e.key: FieldValue.fromJson(e.value! as Map<String, Object?>),
      },
    );
  }

  /// [columns] 에 있는 애플리케이션 필드와 [kDeletedField] 만 남긴 사본.
  ///
  /// 서버가 구 스키마 버전 클라이언트에게 내려보낼 때 쓴다 — 그 클라이언트가
  /// 모르는 컬럼을 저장했다가 그대로 되밀어 올리는 일을 원천 차단한다.
  /// tombstone 은 어느 버전에서나 의미가 같으므로 항상 보존한다. 필드별 HLC 는
  /// 그대로라 투영 결과도 여전히 병합 가능한 [RowState] 다.
  RowState project(Set<String> columns) => RowState(
    rowId: rowId,
    fields: {
      for (final e in fields.entries)
        if (e.key == kDeletedField || columns.contains(e.key)) e.key: e.value,
    },
  );

  @override
  String toString() => 'RowState(${jsonEncode(toJson())})';
}
