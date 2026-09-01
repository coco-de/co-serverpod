import 'dart:convert';

import 'row_state.dart';

/// 두 행 상태를 필드 단위 LWW 로 병합한다 (join 연산).
///
/// 성질 (테스트로 고정):
/// - **교환**: `merge(a, b) == merge(b, a)`
/// - **결합**: `merge(merge(a, b), c) == merge(a, merge(b, c))`
/// - **멱등**: `merge(a, a) == a`
///
/// 규칙: 필드별로 HLC 가 더 큰 쪽 값을 취한다. HLC 는 nodeId tiebreak 로
/// 서로 다른 노드 간 동률이 없지만, 방어적으로 완전히 같은 HLC 에 값이 다르면
/// JSON 인코딩 사전순으로 큰 값을 취해 결정성을 유지한다.
RowState mergeRowStates(RowState a, RowState b) {
  assert(a.rowId == b.rowId, 'cannot merge different rows');
  final merged = <String, FieldValue>{...a.fields};
  for (final entry in b.fields.entries) {
    final existing = merged[entry.key];
    if (existing == null) {
      merged[entry.key] = entry.value;
      continue;
    }
    final cmp = entry.value.hlc.compareTo(existing.hlc);
    if (cmp > 0) {
      merged[entry.key] = entry.value;
    } else if (cmp == 0 && !_sameValue(existing.value, entry.value.value)) {
      // 같은 HLC 에 다른 값 — 정상 경로에서는 불가능하지만 결정적으로 해소.
      if (jsonEncode(entry.value.value).compareTo(jsonEncode(existing.value)) >
          0) {
        merged[entry.key] = entry.value;
      }
    }
  }
  return RowState(rowId: a.rowId, fields: merged);
}

/// 로컬 상태([local], null 가능)에 원격 상태를 병합한 결과를 돌려준다.
RowState mergeIntoLocal(RowState? local, RowState remote) =>
    local == null ? remote : mergeRowStates(local, remote);

/// 두 행 상태가 동일한지 (필드·값·HLC 전부).
bool rowStatesEqual(RowState a, RowState b) {
  if (a.rowId != b.rowId || a.fields.length != b.fields.length) return false;
  for (final entry in a.fields.entries) {
    final other = b.fields[entry.key];
    if (other == null ||
        other.hlc != entry.value.hlc ||
        !_sameValue(other.value, entry.value.value)) {
      return false;
    }
  }
  return true;
}

bool _sameValue(Object? a, Object? b) =>
    identical(a, b) || jsonEncode(a) == jsonEncode(b);
