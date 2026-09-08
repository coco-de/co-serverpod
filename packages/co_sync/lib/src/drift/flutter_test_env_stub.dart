import 'package:drift/drift.dart';

/// 웹 빌드용 스텁 — `dart:io`/`dart:ffi` 미지원이라 항상 false.
bool get isRunningUnderFlutterTest => false;

/// 웹 빌드용 스텁 — [isRunningUnderFlutterTest] 가 항상 false 라 호출되지 않는다.
QueryExecutor createInMemoryTestExecutor() =>
    throw UnsupportedError('웹에서는 인메모리 테스트 executor 를 지원하지 않습니다.');
