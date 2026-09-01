import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 프로토콜 버전 — 와이어 포맷이 비호환으로 바뀔 때만 올린다.
///
/// ⚠️ 이 값은 [computeSchemaSignature] 에 들어가므로 **올리는 순간
/// `SchemaRegistry` 창 안의 모든 버전 서명이 동시에 바뀐다** — 배포된 모든
/// 앱이 한꺼번에 불일치가 된다. 가산적 변경(선택 키 추가 등)에는 올리지 말고,
/// 올려야 한다면 앱 강제 업데이트와 같은 시점에만 한다.
const int protocolVersion = 1;

/// 동기화 대상 스키마의 안정적 서명을 만든다.
///
/// [tables] 는 `테이블 이름 → 컬럼 이름 목록`. 순서와 무관하게 같은 스키마면
/// 같은 서명이 나온다 (내부에서 정렬). 서명에는 [protocolVersion] 이 포함돼
/// 와이어 포맷 변경도 불일치로 잡힌다.
///
/// 정준화(canonical)는 JSON 인코딩으로 한다 — 평문 구분자 join 은 이름에
/// 구분자(`:` `,` `;`)가 들어가면 서로 다른 스키마가 같은 서명을 얻는
/// 주입 충돌이 난다 (리뷰 발견 3).
///
/// 클라이언트·서버가 각자 계산해 push/pull 마다 대조한다 — 서명이 다른 채
/// 병합하면 한쪽이 모르는 필드가 조용히 유실되기 때문이다.
String computeSchemaSignature(Map<String, List<String>> tables) {
  final canonical = [
    for (final table in tables.keys.toList()..sort())
      [
        table,
        [...tables[table]!]..sort(),
      ],
  ];
  final payload = jsonEncode({'v': protocolVersion, 'tables': canonical});
  final digest = sha256.convert(utf8.encode(payload));
  // 앞 16 hex(64비트)면 스키마 구분 용도로 충분하다.
  return digest.toString().substring(0, 16);
}
