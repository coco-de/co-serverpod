import 'package:serverpod/serverpod.dart';
import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:test/test.dart';

import 'test_tools/serverpod_test_tools.dart';

/// A server CRDT node per space through the module's own wiring
/// (unibook#14218): [offlineSyncDatabaseInterceptor] wraps each session's
/// database with the engine `initializeOfflineSync` configured, which shares
/// one context across the pod's sessions and opens no persistent user.
///
/// The other node-per-space tests open their databases directly. This pins
/// that the databases a Serverpod server gets give out nodes the same way.
void main() {
  withServerpod('[Offline sync node per space]', (sessionBuilder, _) {
    setUp(() {
      sessionBuilder.build().serverpod.initializeOfflineSync(syncTables: []);
    });

    /// The database the interceptor gives a new session of the pod.
    OfflineSyncDatabase interceptedDatabase() {
      final session = sessionBuilder.build();
      final database = offlineSyncDatabaseInterceptor(session, session.db);
      expect(database, isA<OfflineSyncDatabase>());
      return database as OfflineSyncDatabase;
    }

    test(
      'Given the interceptor, '
      'when two users use their spaces, '
      "then each space has its own node, the same in every session's database.",
      () async {
        final userA = const Uuid().v7obj();
        final userB = const Uuid().v7obj();
        final first = interceptedDatabase();
        final second = interceptedDatabase();

        final nodeA = await first.currentNodeId(userId: userA);
        final nodeB = await first.currentNodeId(userId: userB);

        expect(nodeB, isNot(nodeA));
        expect(await second.currentNodeId(userId: userA), nodeA);
        expect(await second.currentNodeId(userId: userB), nodeB);
      },
    );
  });
}
