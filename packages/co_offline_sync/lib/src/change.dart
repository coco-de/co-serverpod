import 'row_state.dart';

/// 와이어를 건너는 변경 단위 — "어느 테이블의 어느 행이 이 상태다".
///
/// 델타가 아니라 **행 상태 전체**를 나른다. [RowState] 가 join-semilattice
/// 라서 전체 상태 전송이 곧 멱등 델타다 — 같은 변경을 몇 번 받아도 결과가
/// 같으므로 재시도·중복 전달에 안전하다.
class RowChange {
  /// [table] 은 동기화 대상 논리 테이블 이름.
  const RowChange({required this.table, required this.state});

  /// 논리 테이블 이름.
  final String table;

  /// 행의 병합 가능 상태.
  final RowState state;

  /// JSON 표현.
  Map<String, Object?> toJson() => {'tb': table, 'st': state.toJson()};

  /// [toJson] 의 역연산.
  factory RowChange.fromJson(Map<String, Object?> json) => RowChange(
    table: json['tb']! as String,
    state: RowState.fromJson(json['st']! as Map<String, Object?>),
  );

  @override
  String toString() => 'RowChange($table/${state.rowId})';
}
