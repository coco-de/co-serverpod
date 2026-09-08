import 'dart:io' show Platform;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// `flutter test` 는 프로세스 환경변수 `FLUTTER_TEST` 를 자동으로 설정한다.
bool get isRunningUnderFlutterTest =>
    Platform.environment.containsKey('FLUTTER_TEST');

/// `NativeDatabase.memory()` — `dart:ffi` 기반이라 웹에서 컴파일 자체가
/// 불가능하므로, 이 심볼을 참조하는 import 는 반드시 `dart.library.io`
/// 조건부 뒤에 있어야 한다.
QueryExecutor createInMemoryTestExecutor() => NativeDatabase.memory();
