import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';
import 'package:sign_in_with_apple_server/sign_in_with_apple_server.dart';

import 'apple_idp_config.dart';

// AppleKrAccount 는 `serverpod generate` 후 생성되는 모델이다.
import '../generated/protocol.dart';

/// Details of the Apple account.
typedef AppleAccountDetails = ({
  /// Apple's permanent user identifier for this account
  String userIdentifier,
  String? email,
  bool? isVerifiedEmail,
  bool? isPrivateEmail,
  String? firstName,
  String? lastName,
});

/// Details of a successful Apple-based authentication.
typedef AppleAuthSuccess = ({
  UuidValue appleAccountId,
  UuidValue authUserId,
  AppleAccountDetails details,
  bool newAccount,
  Set<Scope> scopes,
});

/// Utility functions for the Apple identity provider.
///
/// Ported from the official `serverpod_auth_idp_server` Apple provider. The
/// only behavioural change is that [authenticate] threads a [nonce] through to
/// [SignInWithApple.verifyIdentityToken] so the identity token's `nonce` claim
/// is verified (replay protection), instead of the official provider's
/// hard-coded `nonce: null`.
class AppleIdpUtils {
  /// The method identifier used when issuing authentication tokens.
  ///
  /// serverpod 4.0.0-beta.2 의 `IdentityProvider` 계약이 요구하는
  /// instance getter 의 실제 값 소유자다 (공식 IdP 와 동일한 배치).
  String get method => 'apple';

  /// Configuration for the Apple identity provider.
  final AppleIdpConfig? config;

  final TokenManager _tokenManager;
  final SignInWithApple _signInWithApple;
  final AuthUsers _authUsers;

  /// Creates a new instance of [AppleIdpUtils].
  AppleIdpUtils({
    this.config,
    required final TokenManager tokenManager,
    required final SignInWithApple signInWithApple,
    required final AuthUsers authUsers,
  }) : _tokenManager = tokenManager,
       _signInWithApple = signInWithApple,
       _authUsers = authUsers;

  /// Authenticates a user using an [identityToken] and [authorizationCode].
  ///
  /// If the external user ID is not yet known in the system, a new `AuthUser`
  /// is created for it.
  ///
  /// When [nonce] is non-null, it is verified against the identity token's
  /// `nonce` claim (which Apple echoes back from the value the client sent in
  /// the authorization request). The client is expected to send exactly the
  /// value that was put into the Apple authorization request — following the
  /// standard `sign_in_with_apple` pattern, that is `SHA256(rawNonce)`. A
  /// mismatch throws (from `sign_in_with_apple_server`). When [nonce] is null,
  /// the nonce claim is ignored (backwards-compatible with the official
  /// provider), so existing clients keep working during the migration.
  Future<AppleAuthSuccess> authenticate(
    final Session session, {
    required final String identityToken,
    required final String authorizationCode,

    /// Whether the sign-in was triggered from a native Apple platform app.
    ///
    /// Pass `false` for web sign-ins or 3rd party platforms like Android.
    required final bool isNativeApplePlatformSignIn,
    required final String? nonce,
    final String? firstName,
    final String? lastName,
    required final Transaction? transaction,
  }) async {
    final verifiedIdentityToken = await _signInWithApple.verifyIdentityToken(
      identityToken,
      useBundleIdentifier: isNativeApplePlatformSignIn,
      nonce: nonce,
    );

    // TODO(https://github.com/serverpod/serverpod/issues/4105):
    // Handle the edge-case where we already know the user, but they
    // disconnected and now "registered" again, in which case we need to
    // receive and store the new refresh token.

    var appleAccount = await AppleKrAccount.db.findFirstRow(
      session,
      where: (final t) => t.userIdentifier.equals(verifiedIdentityToken.userId),
      transaction: transaction,
    );

    final createNewAccount = appleAccount == null;

    final AuthUserModel authUser = switch (createNewAccount) {
      true => await _authUsers.create(session, transaction: transaction),
      false => await _authUsers.get(
        session,
        authUserId: appleAccount!.authUserId,
      ),
    };

    if (createNewAccount) {
      // `sign_in_with_apple_server` (pub.dev v1.0.0) always sends
      // `redirect_uri: _config.redirectUri` to Apple's `/auth/token`
      // endpoint regardless of `useBundleIdentifier` (see its
      // `exchangeAuthorizationCode`, where `redirect_uri` sits outside the
      // `useBundleIdentifier` branch). That single fixed value cannot match
      // every platform's authorization request, and there are two distinct
      // ways it goes wrong:
      //
      //  * **Native (bundle identifier).** The authorization code was never
      //    associated with any redirect_uri in the first place — it is
      //    issued through the App ID flow, not the Service ID web-redirect
      //    flow — so Apple rejects the exchange with
      //    `invalid_grant: redirect_uri mismatch`. This made every
      //    *first-time* native iOS/macOS Apple sign-in fail
      //    (unibook#12663).
      //
      //  * **Web (Service ID + JS SDK popup).** The code *is* bound to a
      //    redirect_uri, but necessarily to a different one: the Apple JS
      //    SDK runs with `usePopup: true` and posts its result only to the
      //    origin of the `redirectURI` it was given, so the client must
      //    pass the *page origin* (e.g. `https://example.com`, no path).
      //    `_config.redirectUri` is a fixed URL that carries a path, so the
      //    two can never be equal on any host — this is structural, not a
      //    misconfiguration (unibook#12761).
      //
      // Android and desktop happen to send exactly `_config.redirectUri`
      // and so do not hit the mismatch, but they are equally entitled to
      // survive a transient exchange failure.
      //
      // In every case [verifyIdentityToken] above has *already* proven the
      // user's identity against Apple's public keys (signature, audience
      // and nonce). The refresh token obtained here is only used later by
      // [refreshToken]/[serverNotificationHandler] to detect a revoked
      // Apple authorization — it is not required to complete this sign-in.
      // We therefore treat the exchange as best-effort on **all**
      // platforms: on failure we fall back to an empty sentinel token (see
      // [refreshToken] and [serverNotificationHandler] for how that
      // sentinel is handled) instead of failing the whole authentication.
      String refreshToken;
      try {
        final response = await _signInWithApple.exchangeAuthorizationCode(
          authorizationCode,
          useBundleIdentifier: isNativeApplePlatformSignIn,
        );
        refreshToken = response.refreshToken;
      } on Exception catch (error, stackTrace) {
        session.log(
          'Apple sign-in: could not exchange authorization code for a '
          'refresh token (identity already verified, continuing without '
          'one; native=$isNativeApplePlatformSignIn): $error',
          level: LogLevel.warning,
          exception: error,
          stackTrace: stackTrace,
        );
        refreshToken = '';
      }

      appleAccount = await AppleKrAccount.db.insertRow(
        session,
        AppleKrAccount(
          userIdentifier: verifiedIdentityToken.userId,
          refreshToken: refreshToken,
          refreshTokenRequestedWithBundleIdentifier:
              isNativeApplePlatformSignIn,
          email: verifiedIdentityToken.email?.toLowerCase(),
          isEmailVerified: verifiedIdentityToken.emailVerified,
          isPrivateEmail: verifiedIdentityToken.isPrivateEmail,
          authUserId: authUser.id,
          firstName: firstName,
          lastName: lastName,
        ),
        transaction: transaction,
      );

      await config?.onAfterAppleAccountCreated?.call(
        session,
        authUser,
        appleAccount,
        transaction: transaction,
      );
    }

    final AppleAccountDetails details = (
      userIdentifier: appleAccount.userIdentifier,
      email: appleAccount.email,
      isVerifiedEmail: appleAccount.isEmailVerified,
      isPrivateEmail: appleAccount.isPrivateEmail,
      firstName: appleAccount.firstName,
      lastName: appleAccount.lastName,
    );

    return (
      appleAccountId: appleAccount.id!,
      authUserId: appleAccount.authUserId,
      details: details,
      newAccount: createNewAccount,
      scopes: authUser.scopes,
    );
  }

  /// Returns the possible [AppleKrAccount] associated with a session.
  Future<AppleKrAccount?> getAccount(final Session session) {
    return switch (session.authenticated) {
      null => Future.value(null),
      _ => AppleKrAccount.db.findFirstRow(
        session,
        where: (final t) =>
            t.authUserId.equals(session.authenticated!.authUserId),
      ),
    };
  }

  /// Refreshes the Apple [appleAccount]'s refresh token to ensure it is still
  /// valid.
  ///
  /// If the token has been revoked, the [onExpiredUserAuthentication] callback
  /// is invoked with the associated auth user's ID.
  Future<void> refreshToken(
    final Session session, {
    required final AppleKrAccount appleAccount,
    required final void Function(UuidValue authUserId)
    onExpiredUserAuthentication,
  }) async {
    await AppleKrAccount.db.updateRow(
      session,
      appleAccount.copyWith(lastRefreshedAt: clock.now()),
    );

    // [authenticate] leaves this empty when the initial authorization-code
    // exchange failed, on any platform (see the comment there). There is
    // no token to validate, so skip the call instead of letting Apple's
    // rejection of an empty token surface as an unhandled exception here —
    // that would otherwise abort [AppleIdpAdmin.checkAccountStatus]'s whole
    // batch, including the accounts after this one.
    if (appleAccount.refreshToken.isEmpty) return;

    try {
      await _signInWithApple.validateRefreshToken(
        appleAccount.refreshToken,
        useBundleIdentifier:
            appleAccount.refreshTokenRequestedWithBundleIdentifier,
      );
    } on RevokedTokenException catch (_) {
      onExpiredUserAuthentication(appleAccount.authUserId);
    }
  }

  /// Handler for revoking sessions based on server-to-server notifications
  /// coming from Apple.
  ///
  /// If the notification is of type [AppleServerNotificationConsentRevoked] or
  /// [AppleServerNotificationAccountDelete], all sessions based on the Apple
  /// authentication for that account will be revoked.
  Future<Result> serverNotificationHandler(
    final Session session,
    final Request req,
  ) async {
    final body = await utf8.decodeStream(req.body.read());
    final payload = (jsonDecode(body) as Map)['payload'] as String;

    final notification = await _signInWithApple.decodeAppleServerNotification(
      payload,
    );

    final userIdentifier = switch (notification) {
      AppleServerNotificationConsentRevoked() => notification.userIdentifier,
      AppleServerNotificationAccountDelete() => notification.userIdentifier,
      _ => null,
    };

    if (userIdentifier != null) {
      final appleAccount = await AppleKrAccount.db.findFirstRow(
        session,
        where: (final t) => t.userIdentifier.equals(userIdentifier),
      );

      if (appleAccount != null) {
        // [authenticate] stores an empty sentinel when the initial
        // authorization-code exchange failed, so there may be no token to
        // revoke. Even when there is one, revoking at Apple is a courtesy —
        // what actually ends the user's access is the local teardown below.
        // Neither an absent token nor Apple's rejection of one may prevent
        // [revokeAllTokens]/[deleteRow] from running; letting this throw
        // would leave the user signed in *after* they revoked consent.
        if (appleAccount.refreshToken.isNotEmpty) {
          try {
            await _signInWithApple.revokeAuthorization(
              refreshToken: appleAccount.refreshToken,
              useBundleIdentifier:
                  appleAccount.refreshTokenRequestedWithBundleIdentifier,
            );
          } on Exception catch (error, stackTrace) {
            session.log(
              'Apple server notification: revoking the authorization at '
              'Apple failed; continuing with the local session teardown: '
              '$error',
              level: LogLevel.warning,
              exception: error,
              stackTrace: stackTrace,
            );
          }
        }

        await _tokenManager.revokeAllTokens(
          session,
          authUserId: appleAccount.authUserId,
          method: method,
        );

        if (notification is AppleServerNotificationAccountDelete) {
          await AppleKrAccount.db.deleteRow(session, appleAccount);
        }
      }
    }
    return Response.ok();
  }
}
