/// Client library for the `serverpod_auth_idp_apple` Serverpod module.
///
/// Exposes the generated protocol (including `EndpointAppleIdp` with `login`
/// accepting an optional `nonce`) and re-exports the core auth client.
library;

export 'package:serverpod_auth_core_client/serverpod_auth_core_client.dart'
    hide Caller, Protocol, ClientAuthSessionManagerExtension;

export 'src/protocol/client.dart';
export 'src/protocol/protocol.dart';
