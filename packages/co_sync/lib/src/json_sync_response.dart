import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';

/// Parses only a received response, never an application's network callback.
T parseSyncResponse<T>(T Function() parse) {
  try {
    return parse();
  } on FormatException catch (_, stack) {
    Error.throwWithStackTrace(
      const SyncProtocolException('Malformed sync response encoding'),
      stack,
    );
  } on TypeError catch (_, stack) {
    Error.throwWithStackTrace(
      const SyncProtocolException('Malformed sync response fields'),
      stack,
    );
  }
}

/// Decodes an object without including its potentially sensitive body in errors.
Map<String, Object?> decodeSyncObject(String response) {
  final json = jsonDecode(response);
  if (json is! Map<String, Object?>) {
    throw const SyncProtocolException('Sync response must be a JSON object');
  }
  return json;
}

/// Validates payload values without serializing decoded SDK maps again.
void validateSyncJsonValue(Object? value) =>
    _validateValue(value, Set.identity());

void _validateValue(Object? value, Set<Object> ancestors) {
  if (value == null || value is String || value is bool) return;
  if (value is num && value.isFinite) return;
  if (value is! List<Object?> && value is! Map<Object?, Object?>) {
    throw const SyncProtocolException(
      'Sync field value must be JSON-compatible',
    );
  }
  if (!ancestors.add(value)) {
    throw const SyncProtocolException(
      'Sync field value must not contain cycles',
    );
  }
  if (value is List<Object?>) {
    for (final item in value) {
      _validateValue(item, ancestors);
    }
  } else if (value is Map<Object?, Object?>) {
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const SyncProtocolException(
          'Sync JSON object keys must be strings',
        );
      }
      _validateValue(entry.value, ancestors);
    }
  }
  ancestors.remove(value);
}
