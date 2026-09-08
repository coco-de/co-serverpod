import 'dart:convert';

import 'package:co_offline_sync/co_offline_sync.dart';

/// Example transport that connects application-owned JSON endpoints.
class JsonSyncTransport implements SyncTransport {
  /// Supplies the app's generated client methods or HTTP callbacks.
  JsonSyncTransport({required this.pushJson, required this.pullJson});

  /// Sends a JSON push request and returns a JSON response.
  final Future<String> Function(String payload) pushJson;

  /// Sends a JSON pull request and returns a JSON response.
  final Future<String> Function(String payload) pullJson;

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    final response = await pushJson(jsonEncode(request.toJson()));
    return SyncPushResponse.fromJson(
      jsonDecode(response) as Map<String, Object?>,
    );
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    final response = await pullJson(jsonEncode(request.toJson()));
    return SyncPullResponse.fromJson(
      jsonDecode(response) as Map<String, Object?>,
    );
  }
}
