import 'dart:async';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';
import 'package:sign_in_with_apple_server/sign_in_with_apple_server.dart';

import 'apple_idp_admin.dart';
import 'apple_idp_config.dart';
import 'apple_idp_utils.dart';
import 'routes/apple_server_notification_route.dart';

/// Main class for the Apple identity provider.
///
/// Ported from the official `serverpod_auth_idp_server` Apple provider, with
/// nonce replay protection added: [login] accepts an optional [nonce] that is
/// verified against the identity token.
///
/// The `admin` property provides access to [AppleIdpAdmin]; the `utils`
/// property provides access to [AppleIdpUtils].
class AppleIdp implements IdentityProvider {
  /// The method used when authenticating with the Apple identity provider.
  @override
  String get method => utils.method;

  /// Admin operations to work with Apple-backed accounts.
  final AppleIdpAdmin admin;

  /// Utility functions for the Apple identity provider.
  final AppleIdpUtils utils;

  /// The configuration for the Apple identity provider.
  final AppleIdpConfig config;

  final TokenIssuer _tokenIssuer;

  final UserProfiles _userProfiles;

  AppleIdp._(
    this.config,
    this._tokenIssuer,
    this.utils,
    this.admin,
    this._userProfiles,
  );

  /// Creates a new instance of [AppleIdp].
  factory AppleIdp(
    final AppleIdpConfig config, {
    required final TokenManager tokenManager,
    final AuthUsers authUsers = const AuthUsers(),
    final UserProfiles userProfiles = const UserProfiles(),
  }) {
    final signInWithAppleConfig = config.toSignInWithAppleConfiguration();

    final utils = AppleIdpUtils(
      config: config,
      tokenManager: tokenManager,
      signInWithApple: SignInWithApple(config: signInWithAppleConfig),
      authUsers: authUsers,
    );
    final admin = AppleIdpAdmin(utils: utils);

    return AppleIdp._(config, tokenManager, utils, admin, userProfiles);
  }

  /// {@template apple_idp.login}
  /// Signs in a user with their Apple account.
  ///
  /// If no user exists yet linked to the Apple-provided identifier, a new one
  /// will be created (without any `Scope`s). Their provided name and email
  /// (if any) are used for the `UserProfile` linked to their `AuthUser`.
  ///
  /// When [nonce] is provided, the identity token's `nonce` claim is verified
  /// against it (replay protection). Pass the same value the client put into
  /// the Apple authorization request (standard `sign_in_with_apple` pattern:
  /// `SHA256(rawNonce)`). Passing `null` skips the nonce check.
  /// {@endtemplate}
  Future<AuthSuccess> login(
    final Session session, {
    required final String identityToken,
    required final String authorizationCode,

    /// Whether the sign-in was triggered from a native Apple platform app.
    ///
    /// Pass `false` for web sign-ins or 3rd party platforms like Android.
    required final bool isNativeApplePlatformSignIn,
    final String? nonce,
    final String? firstName,
    final String? lastName,
    final Transaction? transaction,
  }) async {
    return await DatabaseUtil.runInTransactionOrSavepoint(
      session.db,
      transaction,
      (final transaction) async {
        final account = await utils.authenticate(
          session,
          identityToken: identityToken,
          authorizationCode: authorizationCode,
          isNativeApplePlatformSignIn: isNativeApplePlatformSignIn,
          nonce: nonce,
          firstName: firstName,
          lastName: lastName,
          transaction: transaction,
        );

        if (account.newAccount) {
          await _userProfiles.createUserProfile(
            session,
            account.authUserId,
            UserProfileData(
              fullName: [account.details.firstName, account.details.lastName]
                  .nonNulls
                  .map((final n) => n.trim())
                  .where((final n) => n.isNotEmpty)
                  .join(' '),
              email: account.details.isVerifiedEmail == true
                  ? account.details.email
                  : null,
            ),
            transaction: transaction,
          );
        }

        return _tokenIssuer.issueToken(
          session,
          authUserId: account.authUserId,
          method: method,
          transaction: transaction,
          scopes: account.scopes,
        );
      },
    );
  }

  /// Determines whether the current session has an associated Apple account.
  Future<bool> hasAccount(final Session session) async =>
      await utils.getAccount(session) != null;

  /// {@macro apple_idp.revokedNotificationRoute}
  Route revokedNotificationRoute() =>
      AppleRevokedNotificationRoute(utils: utils);

  /// {@macro apple_idp.webAuthenticationCallbackRoute}
  Route webAuthenticationCallbackRoute() => AppleWebAuthenticationCallbackRoute(
    utils: utils,
    androidPackageIdentifier: config.androidPackageIdentifier,
    webRedirectUri: config.webRedirectUri,
  );

  @override
  Future<void> mergeAuthUsers(
    final Session session, {
    required final UuidValue userToKeepId,
    required final UuidValue userToRemoveId,
    required final Transaction transaction,
  }) async {
    await AppleAccount.db.updateWhere(
      session,
      where: (final t) => t.authUserId.equals(userToRemoveId),
      columnValues: (final t) => [t.authUserId(userToKeepId)],
      transaction: transaction,
    );
  }
}

/// Extension to get the [AppleIdp] instance from the [AuthServices].
extension AppleIdpGetter on AuthServices {
  /// Returns the [AppleIdp] instance from the [AuthServices].
  AppleIdp get appleIdp => AuthServices.getIdentityProvider<AppleIdp>();
}

/// Extension to configure [AppleIdp] routes on the web server.
extension AppleIdpConfigureRoutes on Serverpod {
  /// Configures the routes for the [AppleIdp]. Must be called after the web
  /// server is initialized. If any of the paths are not provided, its route
  /// will not be added.
  void configureAppleIdpRoutes({
    final String? revokedNotificationRoutePath = '/hooks/apple-notification',
    final String? webAuthenticationCallbackRoutePath = '/auth/apple/callback',
  }) {
    final appleIdp = AuthServices.instance.appleIdp;

    if (revokedNotificationRoutePath != null) {
      webServer.addRoute(
        appleIdp.revokedNotificationRoute(),
        revokedNotificationRoutePath,
      );
    }
    if (webAuthenticationCallbackRoutePath != null) {
      webServer.addRoute(
        appleIdp.webAuthenticationCallbackRoute(),
        webAuthenticationCallbackRoutePath,
      );
    }
  }
}
