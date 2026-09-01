@Tags(['integration'])
library;

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_core_server/serverpod_auth_core_server.dart';
import 'package:serverpod_auth_idp_apple_server/serverpod_auth_idp_apple_server.dart';
import 'package:sign_in_with_apple_server/sign_in_with_apple_server.dart';
import 'package:test/test.dart';

import 'test_tools/serverpod_test_tools.dart';

/// Apple credentials are irrelevant here — every network call is stubbed by
/// [_FakeSignInWithApple]. The redirect URI intentionally carries a path, the
/// way a real deployment configures it, because that is exactly why a web
/// authorization code (bound to a bare page origin) can never be exchanged
/// against it.
final _configuration = SignInWithAppleConfiguration(
  serviceIdentifier: 'com.example.service',
  bundleIdentifier: 'com.example.app',
  redirectUri: 'https://api.example.com/auth/apple/callback',
  teamId: 'TEAMID1234',
  keyId: 'KEYID12345',
  key: 'unused-in-tests',
);

IdentityToken _identityToken({required final String userId}) => IdentityToken(
  userId: userId,
  email: 'user@privaterelay.appleid.com',
  emailVerified: true,
  isPrivateEmail: true,
  realUserStatus: 2,
  nonce: null,
  nonceSupported: false,
);

/// Stubs both Apple network calls so the tests exercise [AppleIdpUtils]'s own
/// control flow: identity verification always succeeds (that is what proves
/// the user), while the authorization-code exchange is scripted per test.
class _FakeSignInWithApple extends SignInWithApple {
  _FakeSignInWithApple({required this.token, this.exchangeError})
    : super(config: _configuration);

  final IdentityToken token;

  /// When non-null, [exchangeAuthorizationCode] throws it instead of
  /// returning a response — emulating Apple's `invalid_grant:
  /// redirect_uri mismatch`.
  final Exception? exchangeError;

  /// How many times the authorization-code exchange was attempted.
  int exchangeCallCount = 0;

  /// The `useBundleIdentifier` value the exchange was called with.
  bool? lastExchangeUsedBundleIdentifier;

  @override
  Future<IdentityToken> verifyIdentityToken(
    final String identityToken, {
    required final bool useBundleIdentifier,
    required final String? nonce,
  }) async => token;

  @override
  Future<AuthorizationCodeExchangeResponse> exchangeAuthorizationCode(
    final String authorizationCode, {
    required final bool useBundleIdentifier,
  }) async {
    exchangeCallCount++;
    lastExchangeUsedBundleIdentifier = useBundleIdentifier;

    final error = exchangeError;
    if (error != null) throw error;

    return AuthorizationCodeExchangeResponse(
      accessToken: 'access-token',
      accessTokenExpiresIn: 3600,
      idToken: 'id-token',
      refreshToken: 'real-refresh-token',
    );
  }
}

/// [AppleIdpUtils.authenticate] never touches the token manager — it is only
/// used by [AppleIdpUtils.serverNotificationHandler]. Any call from these
/// tests would therefore be a bug, so make it loud rather than silent.
class _UnusedTokenManager implements TokenManager {
  @override
  dynamic noSuchMethod(final Invocation invocation) => throw StateError(
    'TokenManager.${invocation.memberName} must not be called during '
    'authenticate()',
  );
}

AppleIdpUtils _utils(final _FakeSignInWithApple signInWithApple) =>
    AppleIdpUtils(
      tokenManager: _UnusedTokenManager(),
      signInWithApple: signInWithApple,
      authUsers: const AuthUsers(),
    );

void main() {
  withServerpod('Given AppleIdpUtils.authenticate', (
    final sessionBuilder,
    final endpoints,
  ) {
    late Session session;

    setUp(() {
      session = sessionBuilder.build();
    });

    // ⭐ Regression guard for unibook#12761.
    //
    // The web client obtains its authorization code with the *page origin* as
    // redirect_uri (forced by the Apple JS SDK's popup postMessage rule),
    // while the server always exchanges against the configured redirect URI.
    // Those two can never be equal, so Apple rejects the exchange — and
    // before the fix `authenticate` rethrew that for non-native sign-ins,
    // failing every first-ever web Apple sign-in.
    test('when a new web sign-in cannot exchange the authorization code '
        'then it still succeeds and stores an empty refresh token', () async {
      final signInWithApple = _FakeSignInWithApple(
        token: _identityToken(userId: 'apple-web-new-user'),
        exchangeError: Exception(
          'Could not exchange authorization code. Status code: 400, '
          'message: {"error":"invalid_grant","error_description":'
          '"redirect_uri mismatch."}',
        ),
      );

      final result = await _utils(signInWithApple).authenticate(
        session,
        identityToken: 'fake-identity-token',
        authorizationCode: 'fake-authorization-code',
        isNativeApplePlatformSignIn: false,
        nonce: null,
        transaction: null,
      );

      expect(result.newAccount, isTrue);
      expect(result.details.userIdentifier, 'apple-web-new-user');
      expect(signInWithApple.exchangeCallCount, 1);
      expect(signInWithApple.lastExchangeUsedBundleIdentifier, isFalse);

      // The account must exist — the whole point is that the sign-in is not
      // rolled back — and it must carry the empty sentinel so that
      // refreshToken()/serverNotificationHandler skip Apple's revocation
      // endpoint for it.
      final account = await AppleKrAccount.db.findFirstRow(
        session,
        where: (final t) => t.userIdentifier.equals('apple-web-new-user'),
      );
      expect(account, isNotNull);
      expect(account!.authUserId, result.authUserId);
      expect(account.refreshToken, isEmpty);
      expect(account.refreshTokenRequestedWithBundleIdentifier, isFalse);
    });

    // The behaviour #12663 introduced for iOS/macOS must survive the
    // generalisation to all platforms.
    test('when a new native sign-in cannot exchange the authorization code '
        'then it still succeeds', () async {
      final signInWithApple = _FakeSignInWithApple(
        token: _identityToken(userId: 'apple-native-new-user'),
        exchangeError: Exception('redirect_uri mismatch'),
      );

      final result = await _utils(signInWithApple).authenticate(
        session,
        identityToken: 'fake-identity-token',
        authorizationCode: 'fake-authorization-code',
        isNativeApplePlatformSignIn: true,
        nonce: null,
        transaction: null,
      );

      expect(result.newAccount, isTrue);
      expect(signInWithApple.lastExchangeUsedBundleIdentifier, isTrue);

      final account = await AppleKrAccount.db.findFirstRow(
        session,
        where: (final t) => t.userIdentifier.equals('apple-native-new-user'),
      );
      expect(account!.refreshToken, isEmpty);
      expect(account.refreshTokenRequestedWithBundleIdentifier, isTrue);
    });

    // Making the exchange non-fatal must not quietly discard a token that was
    // obtained successfully — otherwise revocation detection would break for
    // everyone, not just for the accounts that could not exchange.
    test('when the authorization code exchange succeeds '
        'then the real refresh token is stored', () async {
      final signInWithApple = _FakeSignInWithApple(
        token: _identityToken(userId: 'apple-happy-path-user'),
      );

      await _utils(signInWithApple).authenticate(
        session,
        identityToken: 'fake-identity-token',
        authorizationCode: 'fake-authorization-code',
        isNativeApplePlatformSignIn: false,
        nonce: null,
        transaction: null,
      );

      final account = await AppleKrAccount.db.findFirstRow(
        session,
        where: (final t) => t.userIdentifier.equals('apple-happy-path-user'),
      );
      expect(account!.refreshToken, 'real-refresh-token');
    });

    // This gate is why the defect stayed hidden: an account that already
    // exists never reaches the exchange, so QA accounts and anyone who first
    // signed in on a phone were unaffected.
    test('when the Apple account already exists '
        'then the authorization code is not exchanged again', () async {
      final first = _FakeSignInWithApple(
        token: _identityToken(userId: 'apple-returning-user'),
      );
      final initial = await _utils(first).authenticate(
        session,
        identityToken: 'fake-identity-token',
        authorizationCode: 'first-code',
        isNativeApplePlatformSignIn: false,
        nonce: null,
        transaction: null,
      );
      expect(first.exchangeCallCount, 1);

      final second = _FakeSignInWithApple(
        token: _identityToken(userId: 'apple-returning-user'),
        exchangeError: Exception('must not be reached'),
      );
      final repeat = await _utils(second).authenticate(
        session,
        identityToken: 'fake-identity-token',
        authorizationCode: 'second-code',
        isNativeApplePlatformSignIn: false,
        nonce: null,
        transaction: null,
      );

      expect(repeat.newAccount, isFalse);
      expect(repeat.authUserId, initial.authUserId);
      expect(second.exchangeCallCount, 0);
    });
  });
}
