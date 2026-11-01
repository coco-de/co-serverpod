/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters
// ignore_for_file: invalid_use_of_internal_member

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'dart:async' as _ida;
import 'package:serverpod_auth_core_client/serverpod_auth_core_client.dart'
    as _iacc;
import 'package:serverpod_client/serverpod_client.dart' as _isc;

/// Endpoint for Naver Account-based authentication.
///
/// This endpoint exposes methods for logging in users using Naver
/// authorization codes.
///
/// The canonical upstream provider extends `IdpBaseEndpoint`, which is not part
/// of the public API. This endpoint therefore extends Serverpod's [Endpoint]
/// directly and delegates the authentication flow to the configured [NaverIdp]
/// instance.
///
/// If you would like to modify the authentication flow, consider extending
/// this class and overriding the relevant methods.
/// {@category Endpoint}
class EndpointNaverIdp extends _isc.EndpointRef {
  EndpointNaverIdp(_isc.EndpointCaller caller) : super(caller);

  @override
  String get name => 'serverpod_auth_idp_naver.naverIdp';

  /// Validates a Naver authorization code and either logs in the associated
  /// user or creates a new user account if the Naver account ID is not yet
  /// known.
  ///
  /// This method exchanges the `authorization code` for an `access token`,
  /// then authenticates the user.
  ///
  /// If a new user is created an associated `UserProfile` is also created.
  ///
  /// [codeVerifier] is optional because Naver does not document PKCE support.
  _ida.Future<_iacc.AuthSuccess> login({
    required String code,
    String? codeVerifier,
    required String redirectUri,
  }) => caller.callServerEndpoint<_iacc.AuthSuccess>(
    'serverpod_auth_idp_naver.naverIdp',
    'login',
    {
      'code': code,
      'codeVerifier': codeVerifier,
      'redirectUri': redirectUri,
    },
  );

  /// Logs in (or registers) the user from a Naver `access token` that the
  /// client already obtained via the native Naver login SDK.
  ///
  /// Unlike [login], this skips the authorization-code exchange and calls
  /// Naver's user info API directly with the supplied token. If a new user is
  /// created an associated `UserProfile` is also created.
  _ida.Future<_iacc.AuthSuccess> loginWithAccessToken({
    required String accessToken,
  }) => caller.callServerEndpoint<_iacc.AuthSuccess>(
    'serverpod_auth_idp_naver.naverIdp',
    'loginWithAccessToken',
    {'accessToken': accessToken},
  );

  /// Determines whether the current session has an associated Naver account.
  _ida.Future<bool> hasAccount() => caller.callServerEndpoint<bool>(
    'serverpod_auth_idp_naver.naverIdp',
    'hasAccount',
    {},
  );
}

class Caller extends _isc.ModuleEndpointCaller {
  Caller(_isc.ServerpodClientShared client) : super(client) {
    naverIdp = EndpointNaverIdp(this);
  }

  late final EndpointNaverIdp naverIdp;

  @override
  Map<String, _isc.EndpointRef> get endpointRefLookup => {
    'serverpod_auth_idp_naver.naverIdp': naverIdp,
  };
}
