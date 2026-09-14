import 'package:co_sync/co_sync.dart';

/// Connect an OpenAPI client's decoded request/response objects.
///
/// For typed SDKs, callbacks construct request DTOs from the wire map and return
/// response DTOs' `toJson()`. Check HTTP status and unwrap envelopes there. Throw
/// on failure: returning an empty success would acknowledge unsynced writes.
JsonSyncTransport openApiSyncTransport({
  required SyncMapCallback push,
  required SyncMapCallback pull,
}) => JsonSyncTransport.map(pushMap: push, pullMap: pull);
