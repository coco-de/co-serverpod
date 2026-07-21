import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';

import '../business/apple_idp.dart';

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
class AppleIdpEndpoint extends Endpoint {
  /// Accessor for the configured Apple Idp instance.
  ///
  /// By default this uses the global instance configured in [AuthServices].
  /// If you want to use a different instance, override this getter.
  AppleIdp get appleIdp => AuthServices.instance.appleIdp;

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
  Future<AuthSuccess> login(
    final Session session, {
    required final String identityToken,
    required final String authorizationCode,
    required final bool isNativeApplePlatformSignIn,
    final String? nonce,
    final String? firstName,
    final String? lastName,
  }) async {
    return appleIdp.login(
      session,
      identityToken: identityToken,
      authorizationCode: authorizationCode,
      isNativeApplePlatformSignIn: isNativeApplePlatformSignIn,
      nonce: nonce,
      firstName: firstName,
      lastName: lastName,
    );
  }

  /// Determines whether the current session has an associated Apple account.
  Future<bool> hasAccount(final Session session) async =>
      appleIdp.hasAccount(session);
}
