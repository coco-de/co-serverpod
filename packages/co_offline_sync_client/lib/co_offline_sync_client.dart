/// Flutter persistence and runtime adapters for co_offline_sync.
///
/// Application schemas, authentication and backend transports are injected by
/// the consuming application. See README.md for setup and lifecycle examples.
library;

export 'src/co_sync_runtime.dart';
export 'src/co_sync_remote_exception.dart';
export 'src/drift/co_sync_database.dart' show CoReplicaRowData, CoSyncDatabase;
export 'src/drift_client_sync_store.dart';
export 'src/local_first_seeded_watch.dart';
export 'src/replica/replica_puller.dart';
export 'src/replica/replica_seeded_watch.dart';
export 'src/replica/replica_store.dart';
