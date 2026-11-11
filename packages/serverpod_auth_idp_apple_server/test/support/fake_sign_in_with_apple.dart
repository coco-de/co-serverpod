import 'dart:async';

import 'package:sign_in_with_apple_server/sign_in_with_apple_server.dart';

/// Apple credentials are irrelevant here: every network call is stubbed.
final _configuration = SignInWithAppleConfiguration(
  serviceIdentifier: 'com.example.service',
  bundleIdentifier: 'com.example.app',
  redirectUri: 'https://api.example.com/auth/apple/callback',
  teamId: 'TEAMID1234',
  keyId: 'KEYID12345',
  key: 'unused-in-tests',
);

/// An [IdentityToken] for [userId] that echoes [nonce] as its nonce claim.
IdentityToken identityToken({
  required final String userId,
  final String? nonce,
}) => IdentityToken(
  userId: userId,
  email: 'user@privaterelay.appleid.com',
  emailVerified: true,
  isPrivateEmail: true,
  realUserStatus: 2,
  nonce: nonce,
  nonceSupported: nonce != null,
);

/// The calls [FakeSignInWithApple] can be told never to complete.
enum AppleCall {
  /// `verifyIdentityToken`.
  verify,

  /// `exchangeAuthorizationCode`.
  exchange,

  /// `validateRefreshToken`.
  validate,

  /// `revokeAuthorization`.
  revoke,

  /// `decodeAppleServerNotification`.
  decode,
}

/// A [SignInWithApple] whose network calls are scripted, so tests exercise
/// only the provider's own control flow.
class FakeSignInWithApple extends SignInWithApple {
  /// Creates a scripted [SignInWithApple].
  ///
  /// [token] is what a successful identity verification returns,
  /// [verifyError] is thrown instead when set, and [notification] is what
  /// decoding a server notification returns. Calls listed in [hang] never
  /// complete, which is what a stalled provider looks like to the caller.
  FakeSignInWithApple({
    final IdentityToken? token,
    this.verifyError,
    this.notification,
    this.hang = const {},
  }) : token = token ?? identityToken(userId: 'apple-user'),
       super(config: _configuration);

  /// What a successful identity verification returns.
  final IdentityToken token;

  /// Thrown by `verifyIdentityToken` when set.
  final Object? verifyError;

  /// What decoding a server notification returns.
  final AppleServerNotification? notification;

  /// The calls that never complete.
  final Set<AppleCall> hang;

  /// How often `verifyIdentityToken` was called.
  int verifyCalls = 0;

  /// The `nonce` the last `verifyIdentityToken` call received.
  String? lastNonce;

  /// How often `exchangeAuthorizationCode` was called.
  int exchangeCalls = 0;

  /// How often `validateRefreshToken` was called.
  int validateCalls = 0;

  /// The refresh tokens `revokeAuthorization` was called with.
  final List<String> revokedRefreshTokens = [];

  /// How often `decodeAppleServerNotification` was called.
  int decodeCalls = 0;

  /// The payload the last `decodeAppleServerNotification` call received.
  String? lastPayload;

  @override
  Future<IdentityToken> verifyIdentityToken(
    final String identityToken, {
    required final bool useBundleIdentifier,
    required final String? nonce,
  }) {
    verifyCalls++;
    lastNonce = nonce;
    if (hang.contains(AppleCall.verify)) {
      return Completer<IdentityToken>().future;
    }
    final error = verifyError;
    if (error != null) return Future.error(error);

    // Mirror `sign_in_with_apple_server`'s contract: a non-null `nonce` must
    // equal the token's `nonce` claim, otherwise it throws.
    if (nonce != null && nonce != token.nonce) {
      return Future.error(Exception('nonce mismatch'));
    }
    return Future.value(token);
  }

  @override
  Future<AuthorizationCodeExchangeResponse> exchangeAuthorizationCode(
    final String authorizationCode, {
    required final bool useBundleIdentifier,
  }) {
    exchangeCalls++;
    if (hang.contains(AppleCall.exchange)) {
      return Completer<AuthorizationCodeExchangeResponse>().future;
    }
    return Future.value(
      AuthorizationCodeExchangeResponse(
        accessToken: 'access-token',
        accessTokenExpiresIn: 3600,
        idToken: 'id-token',
        refreshToken: 'real-refresh-token',
      ),
    );
  }

  @override
  Future<RefreshTokenValidationResponse> validateRefreshToken(
    final String refreshToken, {
    required final bool useBundleIdentifier,
  }) {
    validateCalls++;
    if (hang.contains(AppleCall.validate)) {
      return Completer<RefreshTokenValidationResponse>().future;
    }
    return Future.value(
      RefreshTokenValidationResponse(
        accessToken: 'access-token',
        accessTokenExpiresIn: 3600,
        idToken: 'id-token',
      ),
    );
  }

  @override
  Future<void> revokeAuthorization({
    required final String refreshToken,
    required final bool useBundleIdentifier,
  }) {
    revokedRefreshTokens.add(refreshToken);
    if (hang.contains(AppleCall.revoke)) return Completer<void>().future;
    return Future.value();
  }

  @override
  Future<AppleServerNotification> decodeAppleServerNotification(
    final String payloadToken,
  ) {
    decodeCalls++;
    lastPayload = payloadToken;
    if (hang.contains(AppleCall.decode)) {
      return Completer<AppleServerNotification>().future;
    }
    return Future.value(
      notification ??
          AppleServerNotificationEmailEnabled(
            userIdentifier: 'apple-user',
            email: 'user@privaterelay.appleid.com',
          ),
    );
  }
}
