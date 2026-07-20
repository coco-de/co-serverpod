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
import 'package:serverpod_client/serverpod_client.dart' as _i1;
import 'dart:async' as _i2;
import 'package:serverpod_auth_core_client/serverpod_auth_core_client.dart'
    as _i3;

/// Endpoint for Apple account-based authentication (Sign in with Apple).
///
/// This endpoint exposes methods for logging in users with an Apple
/// `identityToken` + `authorizationCode`, verifying an optional `nonce` for
/// replay protection.
///
/// `IdpBaseEndpoint` is not part of the public API, therefore this endpoint
/// extends Serverpod's [Endpoint] directly and delegates to the configured
/// [AppleIdp] instance.
///
/// If you would like to modify the authentication flow, consider extending
/// this class and overriding the relevant methods.
/// {@category Endpoint}
class EndpointAppleIdp extends _i1.EndpointRef {
  EndpointAppleIdp(_i1.EndpointCaller caller) : super(caller);

  @override
  String get name => 'serverpod_auth_idp_apple.appleIdp';

  /// Signs in a user with their Apple account.
  ///
  /// If no user exists yet linked to the Apple-provided identifier, a new one
  /// will be created. Their provided name and email (if any) are used for the
  /// linked `UserProfile`.
  ///
  /// [identityToken] and [authorizationCode] come from the Sign in with Apple
  /// credential. [isNativeApplePlatformSignIn] must be `true` for iOS/macOS
  /// native sign-ins and `false` for web/Android.
  ///
  /// When [nonce] is provided, the identity token's `nonce` claim is verified
  /// against it (replay protection). Pass the same value the client put into
  /// the Apple authorization request — following the standard
  /// `sign_in_with_apple` pattern, that is `SHA256(rawNonce)`.
  _i2.Future<_i3.AuthSuccess> login({
    required String identityToken,
    required String authorizationCode,
    required bool isNativeApplePlatformSignIn,
    String? nonce,
    String? firstName,
    String? lastName,
  }) => caller.callServerEndpoint<_i3.AuthSuccess>(
    'serverpod_auth_idp_apple.appleIdp',
    'login',
    {
      'identityToken': identityToken,
      'authorizationCode': authorizationCode,
      'isNativeApplePlatformSignIn': isNativeApplePlatformSignIn,
      'nonce': nonce,
      'firstName': firstName,
      'lastName': lastName,
    },
  );

  /// Determines whether the current session has an associated Apple account.
  _i2.Future<bool> hasAccount() => caller.callServerEndpoint<bool>(
    'serverpod_auth_idp_apple.appleIdp',
    'hasAccount',
    {},
  );
}

class Caller extends _i1.ModuleEndpointCaller {
  Caller(_i1.ServerpodClientShared client) : super(client) {
    appleIdp = EndpointAppleIdp(this);
  }

  late final EndpointAppleIdp appleIdp;

  @override
  Map<String, _i1.EndpointRef> get endpointRefLookup => {
    'serverpod_auth_idp_apple.appleIdp': appleIdp,
  };
}
