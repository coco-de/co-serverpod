import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';

import 'json_sync_response.dart';

/// Sends a sync wire object through an application-owned API client.
///
/// Return only a successful sync response, after checking HTTP/GraphQL errors
/// and unwrapping any API envelope. Values must be JSON-compatible.
typedef SyncMapCallback =
    Future<Map<String, Object?>> Function(Map<String, Object?> payload);

/// Connects the core sync protocol to application-owned JSON APIs.
///
/// The default constructor accepts JSON strings (e.g. a Serverpod endpoint).
/// [JsonSyncTransport.map] accepts decoded objects (e.g. OpenAPI or GraphQL).
/// Authentication, SDK error mapping, envelopes and retries belong to the
/// callbacks. Callback errors propagate unchanged, including their stack trace;
/// only malformed successful responses become [SyncProtocolException].
///
/// This adapter does not implement a schema probe: applications can separately
/// opt into `JsonSchemaWindowProbe` via the runtime's `schemaProbe` argument.
class JsonSyncTransport implements SyncTransport {
  /// Supplies JSON string push/pull methods from the application's client.
  JsonSyncTransport({
    required Future<String> Function(String payload) pushJson,
    required Future<String> Function(String payload) pullJson,
  }) : this.map(
         pushMap: (payload) async {
           final response = await pushJson(jsonEncode(payload));
           return parseSyncResponse(() => decodeSyncObject(response));
         },
         pullMap: (payload) async {
           final response = await pullJson(jsonEncode(payload));
           return parseSyncResponse(() => decodeSyncObject(response));
         },
       );

  /// Supplies decoded JSON object push/pull methods, without an SDK dependency.
  JsonSyncTransport.map({
    required SyncMapCallback pushMap,
    required SyncMapCallback pullMap,
  }) : _pushMap = pushMap,
       _pullMap = pullMap;

  final SyncMapCallback _pushMap;
  final SyncMapCallback _pullMap;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    // Keep the callback outside the parser's catch boundary. In particular, a
    // callback's own FormatException/TypeError must not be reclassified.
    final json = await _pushMap(request.toJson());
    return parseSyncResponse(() {
      final response = SyncPushResponse.fromJson(json);
      if (response.appliedCount < 0) {
        throw const SyncProtocolException('applied must be non-negative');
      }
      Hlc.parse(response.serverHlcPacked);
      return response;
    });
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    final json = await _pullMap(request.toJson());
    return parseSyncResponse(() {
      final response = SyncPullResponse.fromJson(json);
      final hlc = response.serverHlcPacked;
      if (hlc != null) Hlc.parse(hlc);
      // Decoded SDK maps can still contain DateTime/DTO objects or non-finite
      // numbers. Reject them before a caller starts applying any rows.
      for (final change in response.changes) {
        for (final field in change.state.fields.values) {
          validateSyncJsonValue(field.value);
        }
      }
      return response;
    });
  }
}
