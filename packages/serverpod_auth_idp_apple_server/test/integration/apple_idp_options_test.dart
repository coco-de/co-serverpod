@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_apple_server/serverpod_auth_idp_apple_server.dart';
import 'package:serverpod_auth_idp_server/core.dart' show AuthUsers;
import 'package:sign_in_with_apple_server/sign_in_with_apple_server.dart';
import 'package:test/test.dart';

import '../support/apple_test_config.dart';
import '../support/fake_sign_in_with_apple.dart';
import '../support/recording_token_manager.dart';
import 'test_tools/serverpod_test_tools.dart';

/// The optional nonce requirement and the call timeout of the Apple provider,
/// and the server notification handler, against a real test database.

const _shortTimeout = Duration(milliseconds: 50);

AppleIdpUtils _utils(
  final FakeSignInWithApple apple,
  final AppleIdpConfig config, [
  final RecordingTokenManager? manager,
]) => AppleIdpUtils(
  config: config,
  tokenManager: manager ?? RecordingTokenManager(),
  signInWithApple: apple,
  authUsers: const AuthUsers(),
);

Body _notificationBody() => Body.fromString(jsonEncode({'payload': 'signed'}));

void main() {
  withServerpod('Given AppleIdpUtils', (final sessionBuilder, final endpoints) {
    late Session session;

    setUp(() {
      session = sessionBuilder.build();
    });

    Future<AppleKrAccount> storedAccount(
      final String userIdentifier, {
      final String refreshToken = 'stored-refresh-token',
    }) async {
      final user = await const AuthUsers().create(session);
      return AppleKrAccount.db.insertRow(
        session,
        AppleKrAccount(
          userIdentifier: userIdentifier,
          refreshToken: refreshToken,
          refreshTokenRequestedWithBundleIdentifier: false,
          authUserId: user.id,
        ),
      );
    }

    Future<AppleKrAccount?> findAccount(final String userIdentifier) =>
        AppleKrAccount.db.findFirstRow(
          session,
          where: (final t) => t.userIdentifier.equals(userIdentifier),
        );

    group('with the nonce requirement on', () {
      test(
        'when the client sends the nonce the identity token carries then the '
        'sign-in succeeds and the account is created',
        () async {
          final apple = FakeSignInWithApple(
            token: identityToken(
              userId: 'apple-nonce-user',
              nonce: 'hashed-nonce',
            ),
          );

          final result =
              await _utils(
                apple,
                appleTestConfig(requireNonce: true),
              ).authenticate(
                session,
                identityToken: 'identity-token',
                authorizationCode: 'authorization-code',
                isNativeApplePlatformSignIn: false,
                nonce: 'hashed-nonce',
                transaction: null,
              );

          expect(result.newAccount, isTrue);
          expect(apple.lastNonce, 'hashed-nonce');
          expect(await findAccount('apple-nonce-user'), isNotNull);
        },
      );

      test('when the client sends no nonce then the sign-in is refused and '
          'nothing is created', () async {
        final apple = FakeSignInWithApple(
          token: identityToken(userId: 'apple-no-nonce-user'),
        );

        await expectLater(
          _utils(apple, appleTestConfig(requireNonce: true)).authenticate(
            session,
            identityToken: 'identity-token',
            authorizationCode: 'authorization-code',
            isNativeApplePlatformSignIn: false,
            nonce: null,
            transaction: null,
          ),
          throwsA(isA<AppleNonceRequiredException>()),
        );

        expect(apple.verifyCalls, 0);
        expect(await findAccount('apple-no-nonce-user'), isNull);
      });
    });

    group('with a short httpTimeout', () {
      test('when the authorization code exchange never completes then the '
          'sign-in still succeeds and stores an empty refresh token', () async {
        final apple = FakeSignInWithApple(
          token: identityToken(userId: 'apple-slow-exchange'),
          hang: {AppleCall.exchange},
        );

        final result =
            await _utils(
              apple,
              appleTestConfig(httpTimeout: _shortTimeout),
            ).authenticate(
              session,
              identityToken: 'identity-token',
              authorizationCode: 'authorization-code',
              isNativeApplePlatformSignIn: false,
              nonce: null,
              transaction: null,
            );

        expect(result.newAccount, isTrue);
        expect(apple.exchangeCalls, 1);
        final account = await findAccount('apple-slow-exchange');
        expect(account!.refreshToken, isEmpty);
      });

      test(
        'when validating the refresh token never completes then refreshToken '
        'throws a TimeoutException',
        () async {
          final apple = FakeSignInWithApple(hang: {AppleCall.validate});
          final account = await storedAccount('apple-slow-validate');

          await expectLater(
            _utils(
              apple,
              appleTestConfig(httpTimeout: _shortTimeout),
            ).refreshToken(
              session,
              appleAccount: account,
              onExpiredUserAuthentication: (final _) {},
            ),
            throwsA(isA<TimeoutException>()),
          );
          expect(apple.validateCalls, 1);
        },
      );
    });

    group('handling a server notification', () {
      test('when the user revoked consent then Apple is asked to revoke, the '
          'sessions are revoked and the account is kept', () async {
        final account = await storedAccount('apple-revoked');
        final apple = FakeSignInWithApple(
          notification: AppleServerNotificationConsentRevoked(
            userIdentifier: 'apple-revoked',
          ),
        );
        final manager = RecordingTokenManager();

        final result = await _utils(
          apple,
          appleTestConfig(),
          manager,
        ).handleServerNotificationBody(session, _notificationBody());

        expect((result as Response).statusCode, 200);
        expect(apple.revokedRefreshTokens, ['stored-refresh-token']);
        expect(manager.revokedAll, [(account.authUserId, 'apple')]);
        expect(await findAccount('apple-revoked'), isNotNull);
      });

      test('when the user deleted the Apple account then the sessions are '
          'revoked and the account row is deleted', () async {
        final account = await storedAccount('apple-deleted');
        final apple = FakeSignInWithApple(
          notification: AppleServerNotificationAccountDelete(
            userIdentifier: 'apple-deleted',
          ),
        );
        final manager = RecordingTokenManager();

        final result = await _utils(
          apple,
          appleTestConfig(),
          manager,
        ).handleServerNotificationBody(session, _notificationBody());

        expect((result as Response).statusCode, 200);
        expect(manager.revokedAll, [(account.authUserId, 'apple')]);
        expect(await findAccount('apple-deleted'), isNull);
      });

      test('when the user is unknown then nothing is revoked', () async {
        final apple = FakeSignInWithApple(
          notification: AppleServerNotificationConsentRevoked(
            userIdentifier: 'apple-unknown',
          ),
        );
        final manager = RecordingTokenManager();

        final result = await _utils(
          apple,
          appleTestConfig(),
          manager,
        ).handleServerNotificationBody(session, _notificationBody());

        expect((result as Response).statusCode, 200);
        expect(apple.revokedRefreshTokens, isEmpty);
        expect(manager.revokedAll, isEmpty);
      });

      test('when revoking at Apple never completes then the sessions are still '
          'revoked locally', () async {
        final account = await storedAccount('apple-slow-revoke');
        final apple = FakeSignInWithApple(
          notification: AppleServerNotificationConsentRevoked(
            userIdentifier: 'apple-slow-revoke',
          ),
          hang: {AppleCall.revoke},
        );
        final manager = RecordingTokenManager();

        final result = await _utils(
          apple,
          appleTestConfig(httpTimeout: _shortTimeout),
          manager,
        ).handleServerNotificationBody(session, _notificationBody());

        expect((result as Response).statusCode, 200);
        expect(apple.revokedRefreshTokens, ['stored-refresh-token']);
        expect(manager.revokedAll, [(account.authUserId, 'apple')]);
      });
    });
  });
}
