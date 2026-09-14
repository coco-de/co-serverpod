import 'package:co_offline_sync/co_offline_sync.dart';

import 'co_sync_runtime.dart';
import 'json_sync_response.dart';

/// Optional JSON adapter for the runtime's schema-window preflight.
///
/// It validates the shape of `currentVersion`, `minSupportedVersion` and
/// `currentSignature`. The runtime evaluates compatibility; the server must
/// still enforce schema compatibility on every push/pull.
class JsonSchemaWindowProbe implements SchemaWindowProbe {
  /// Supplies an application-owned JSON string schema-window request.
  JsonSchemaWindowProbe({required Future<String> Function() fetchJson})
    : this.map(
        fetchMap: () async {
          final response = await fetchJson();
          return parseSyncResponse(() => decodeSyncObject(response));
        },
      );

  /// Supplies an application-owned decoded JSON schema-window request.
  JsonSchemaWindowProbe.map({
    required Future<Map<String, Object?>> Function() fetchMap,
  }) : _fetchMap = fetchMap;

  final Future<Map<String, Object?>> Function() _fetchMap;

  @override
  Future<SchemaWindowInfo> fetchSchemaWindow() async {
    final json = await _fetchMap();
    return parseSyncResponse(() {
      final current = json['currentVersion'];
      final minimum = json['minSupportedVersion'];
      final signature = json['currentSignature'];
      if (current is! int ||
          minimum is! int ||
          minimum < 1 ||
          current < minimum ||
          signature is! String ||
          signature.trim().isEmpty) {
        throw const SyncProtocolException('Invalid schema window');
      }
      return (
        currentVersion: current,
        minSupportedVersion: minimum,
        currentSignature: signature,
      );
    });
  }
}
