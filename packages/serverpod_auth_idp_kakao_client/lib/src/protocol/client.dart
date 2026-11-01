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

/// Endpoint for Kakao account-based authentication.
///
/// This endpoint exposes methods for logging in users using Kakao
/// authorization codes.
///
/// `IdpBaseEndpoint` is not part of the public API, therefore this endpoint
/// extends Serverpod's [Endpoint] directly and delegates to the configured
/// [KakaoIdp] instance.
///
/// If you would like to modify the authentication flow, consider extending
/// this class and overriding the relevant methods.
/// {@category Endpoint}
class EndpointKakaoIdp extends _isc.EndpointRef {
  EndpointKakaoIdp(_isc.EndpointCaller caller) : super(caller);

  @override
  String get name => 'serverpod_auth_idp_kakao.kakaoIdp';

  /// Validates a Kakao authorization code and either logs in the associated
  /// user or creates a new user account if the Kakao account ID is not yet
  /// known.
  ///
  /// This method exchanges the `authorization code` for an `access token`
  /// using PKCE, then authenticates the user.
  ///
  /// The [code] is the authorization code returned by Kakao's OAuth flow, the
  /// [codeVerifier] is the PKCE code verifier used to generate the code
  /// challenge, and the [redirectUri] must match the redirect URI used in the
  /// authorization request.
  ///
  /// If a new user is created an associated user profile is also created.
  _ida.Future<_iacc.AuthSuccess> login({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) => caller.callServerEndpoint<_iacc.AuthSuccess>(
    'serverpod_auth_idp_kakao.kakaoIdp',
    'login',
    {
      'code': code,
      'codeVerifier': codeVerifier,
      'redirectUri': redirectUri,
    },
  );

  /// Logs in (or registers) the user from a Kakao `access token` that the
  /// client already obtained via the native Kakao SDK.
  ///
  /// Unlike [login], this skips the authorization-code exchange and calls
  /// Kakao's user API directly. If a new user is created an associated user
  /// profile is also created.
  _ida.Future<_iacc.AuthSuccess> loginWithAccessToken({
    required String accessToken,
  }) => caller.callServerEndpoint<_iacc.AuthSuccess>(
    'serverpod_auth_idp_kakao.kakaoIdp',
    'loginWithAccessToken',
    {'accessToken': accessToken},
  );

  /// Determines whether the current session has an associated Kakao account.
  _ida.Future<bool> hasAccount() => caller.callServerEndpoint<bool>(
    'serverpod_auth_idp_kakao.kakaoIdp',
    'hasAccount',
    {},
  );
}

class Caller extends _isc.ModuleEndpointCaller {
  Caller(_isc.ServerpodClientShared client) : super(client) {
    kakaoIdp = EndpointKakaoIdp(this);
  }

  late final EndpointKakaoIdp kakaoIdp;

  @override
  Map<String, _isc.EndpointRef> get endpointRefLookup => {
    'serverpod_auth_idp_kakao.kakaoIdp': kakaoIdp,
  };
}
