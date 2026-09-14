import 'package:co_sync/co_sync.dart' as sync;

/// Compatibility wrapper for the original Serverpod-shaped example.
///
/// New code can use the transport from `package:co_sync/co_sync.dart` directly.
class JsonSyncTransport extends sync.JsonSyncTransport {
  /// Preserves the original constructor and public callback fields.
  JsonSyncTransport({required this.pushJson, required this.pullJson})
    : super(pushJson: pushJson, pullJson: pullJson);

  /// Sends a JSON push request and returns a JSON response.
  final Future<String> Function(String payload) pushJson;

  /// Sends a JSON pull request and returns a JSON response.
  final Future<String> Function(String payload) pullJson;
}
