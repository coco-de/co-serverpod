import 'package:co_offline_sync/co_offline_sync.dart';
import 'package:co_sync/co_sync.dart';

/// Executes a GraphQL operation and returns the complete decoded envelope.
///
/// Supply network-only operations; normalized/cached results are not sync acks.
/// SDK transport exceptions must be thrown, not hidden by returning cached data.
typedef GraphqlSyncOperation =
    Future<Map<String, Object?>> Function(
      String document,
      Map<String, Object?> variables,
    );

/// Example all-or-nothing failure for a GraphQL response containing `errors`.
///
/// Applications can instead map their SDK errors to `CoSyncRemoteException`
/// using the server's agreed error codes. Avoid exposing raw server messages.
class GraphqlSyncException implements Exception {
  /// Records the errors for application-owned diagnostics.
  GraphqlSyncException(List<Object?> errors)
    : errors = List.unmodifiable(errors);

  /// GraphQL errors; these may include application-sensitive details.
  final List<Object?> errors;

  @override
  String toString() => 'GraphqlSyncException: sync operation failed';
}

/// Illustrative schema using a JSON scalar to preserve the core wire contract.
///
/// Operation/field names and the `JSON` scalar must be provided by your server.
/// This is an adapter example, not a bundled GraphQL client or server schema.
JsonSyncTransport graphqlSyncTransport({
  required GraphqlSyncOperation execute,
}) => JsonSyncTransport.map(
  pushMap: (payload) async => _syncData(
    await execute(
      r'mutation SyncPush($payload: JSON!) { syncPush(payload: $payload) }',
      {'payload': payload},
    ),
    'syncPush',
  ),
  pullMap: (payload) async => _syncData(
    await execute(
      r'query SyncPull($payload: JSON!) { syncPull(payload: $payload) }',
      {'payload': payload},
    ),
    'syncPull',
  ),
);

Map<String, Object?> _syncData(Map<String, Object?> envelope, String field) {
  // GraphQL can return both data and errors with HTTP 200. Reject the entire
  // operation BEFORE reading data, so no pending ack or cursor escapes.
  if (envelope.containsKey('errors')) {
    final errors = envelope['errors'];
    if (errors is! List<Object?>) {
      throw const SyncProtocolException('GraphQL errors must be a list');
    }
    if (errors.isNotEmpty) throw GraphqlSyncException(errors);
  }
  final data = envelope['data'];
  if (data is! Map<String, Object?> || data[field] is! Map<String, Object?>) {
    throw const SyncProtocolException('GraphQL sync data must be an object');
  }
  return data[field]! as Map<String, Object?>;
}
