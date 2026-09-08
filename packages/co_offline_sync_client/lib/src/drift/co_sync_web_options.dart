import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';

/// 웹 Drift 데이터베이스 옵션 (`package:cache` 의 `appDriftWebOptions` 와 동일
/// 계약 — L1 동일 계층이라 의존할 수 없어 복제한다).
///
/// ⚠️ [DriftWebOptions.onResult] 를 **반드시** 지정한다 — 미지정 시
/// `drift_flutter` 기본 핸들러가 릴리스 웹 빌드에서도 `print` 경고를 찍는다
/// (kobic#10863 계열, cache 쪽 주석 참조).
DriftWebOptions coSyncDriftWebOptions() => .new(
  sqlite3Wasm: Uri.parse('sqlite3.wasm'),
  driftWorker: Uri.parse('drift_worker.js'),
  onResult: (result) {
    if (kDebugMode && result.missingFeatures.isNotEmpty) {
      final missing = result.missingFeatures
          .map((feature) => feature.name)
          .join(', ');
      debugPrint(
        'drift(co_sync): ${result.chosenImplementation.name} 선택 '
        '(미지원 브라우저 기능: $missing)',
      );
    }
  },
);
