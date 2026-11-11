import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_apple_server/serverpod_auth_idp_apple_server.dart';
import 'package:serverpod_auth_idp_server/core.dart' show AuthUsers;
import 'package:test/test.dart';

import 'support/apple_test_config.dart';
import 'support/fake_session.dart';
import 'support/fake_sign_in_with_apple.dart';
import 'support/recording_token_manager.dart';

/// The optional nonce requirement, the call timeout and the request body
/// limit of the Apple provider.
///
/// The nonce requirement is off and the timeout and the limit are generous by
/// default; the first groups pin that, the others pin what the options do when
/// they are set.

AppleIdpUtils _utils(
  final FakeSignInWithApple apple, {
  final AppleIdpConfig? config,
}) => AppleIdpUtils(
  config: config,
  tokenManager: RecordingTokenManager(),
  signInWithApple: apple,
  authUsers: const AuthUsers(),
);

/// Thrown by the fake when identity verification is reached.
class _VerificationReached implements Exception {}

const _shortTimeout = Duration(milliseconds: 50);

Future<void> _authenticate(final AppleIdpUtils utils, {final String? nonce}) =>
    utils.authenticate(
      FakeSession(),
      identityToken: 'identity-token',
      authorizationCode: 'authorization-code',
      isNativeApplePlatformSignIn: true,
      nonce: nonce,
      transaction: null,
    );

Body _streamed(final List<int> chunkSizes) => Body.fromDataStream(
  Stream.fromIterable([for (final size in chunkSizes) Uint8List(size)]),
);

int _status(final Result result) => (result as Response).statusCode;

void main() {
  group('Given the default AppleIdpConfig', () {
    test('then the nonce is optional, calls time out after 30 seconds and '
        'request bodies are limited to 512 KiB', () {
      const config = AppleIdpConfig(
        serviceIdentifier: 'service',
        bundleIdentifier: 'bundle',
        redirectUri: 'https://api.example.com/auth/apple/callback',
        teamId: 'team',
        keyId: 'key',
        key: 'secret',
      );

      expect(config.requireNonce, isFalse);
      expect(config.httpTimeout, const Duration(seconds: 30));
      expect(config.maxRequestBodyBytes, 512 * 1024);
      expect(AppleIdpConfig.defaultHttpTimeout, const Duration(seconds: 30));
      expect(AppleIdpConfig.defaultMaxRequestBodyBytes, 524288);
    });
  });

  group('Given a client that sends no nonce', () {
    test(
      'when requireNonce is off then identity verification is still attempted '
      'with a null nonce',
      () async {
        final apple = FakeSignInWithApple(verifyError: _VerificationReached());

        await expectLater(
          _authenticate(_utils(apple, config: appleTestConfig())),
          throwsA(isA<_VerificationReached>()),
        );
        expect(apple.verifyCalls, 1);
        expect(apple.lastNonce, isNull);
      },
    );

    test(
      'when no config is given then identity verification is attempted too',
      () async {
        final apple = FakeSignInWithApple(verifyError: _VerificationReached());

        await expectLater(
          _authenticate(_utils(apple)),
          throwsA(isA<_VerificationReached>()),
        );
        expect(apple.verifyCalls, 1);
      },
    );

    test('when requireNonce is on then authenticate throws '
        'AppleNonceRequiredException before Apple is called', () async {
      final apple = FakeSignInWithApple(verifyError: _VerificationReached());

      await expectLater(
        _authenticate(
          _utils(apple, config: appleTestConfig(requireNonce: true)),
        ),
        throwsA(isA<AppleNonceRequiredException>()),
      );
      expect(apple.verifyCalls, 0);
    });
  });

  group('Given a client that sends a nonce and requireNonce is on', () {
    test('then the nonce reaches identity verification unchanged', () async {
      final apple = FakeSignInWithApple(verifyError: _VerificationReached());

      await expectLater(
        _authenticate(
          _utils(apple, config: appleTestConfig(requireNonce: true)),
          nonce: 'hashed-nonce',
        ),
        throwsA(isA<_VerificationReached>()),
      );
      expect(apple.verifyCalls, 1);
      expect(apple.lastNonce, 'hashed-nonce');
    });
  });

  group('Given a short httpTimeout and Apple never answering', () {
    test('when verifying the identity token then authenticate throws a '
        'TimeoutException', () async {
      final apple = FakeSignInWithApple(hang: {AppleCall.verify});

      await expectLater(
        _authenticate(
          _utils(apple, config: appleTestConfig(httpTimeout: _shortTimeout)),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(apple.verifyCalls, 1);
    });

    test('when decoding a server notification then the handler throws a '
        'TimeoutException', () async {
      final apple = FakeSignInWithApple(hang: {AppleCall.decode});

      await expectLater(
        _utils(
          apple,
          config: appleTestConfig(httpTimeout: _shortTimeout),
        ).handleServerNotificationBody(
          FakeSession(),
          Body.fromString(jsonEncode({'payload': 'signed'})),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(apple.decodeCalls, 1);
    });
  });

  group('Given AppleIdpUtils.handleServerNotificationBody', () {
    test('when the body is within the limit then it decodes the payload and '
        'answers 200', () async {
      final apple = FakeSignInWithApple();

      final result =
          await _utils(
            apple,
            config: appleTestConfig(maxRequestBodyBytes: 1024),
          ).handleServerNotificationBody(
            FakeSession(),
            Body.fromString(jsonEncode({'payload': 'signed-payload'})),
          );

      expect(_status(result), 200);
      expect(apple.lastPayload, 'signed-payload');
    });

    test(
      'when the body is exactly as large as the limit then it is accepted',
      () async {
        final text = jsonEncode({'payload': 'p'});
        final apple = FakeSignInWithApple();

        final result = await _utils(
          apple,
          config: appleTestConfig(
            maxRequestBodyBytes: utf8.encode(text).length,
          ),
        ).handleServerNotificationBody(FakeSession(), Body.fromString(text));

        expect(_status(result), 200);
        expect(apple.decodeCalls, 1);
      },
    );

    test('when the declared length is over the limit then it answers 413 '
        'without decoding', () async {
      final apple = FakeSignInWithApple();

      final result =
          await _utils(
            apple,
            config: appleTestConfig(maxRequestBodyBytes: 100),
          ).handleServerNotificationBody(
            FakeSession(),
            Body.fromString(jsonEncode({'payload': 'a' * 200})),
          );

      expect(_status(result), 413);
      expect(apple.decodeCalls, 0);
    });

    test('when a body of unknown length grows past the limit then it answers '
        '413 without decoding', () async {
      final apple = FakeSignInWithApple();

      final result = await _utils(
        apple,
        config: appleTestConfig(maxRequestBodyBytes: 100),
      ).handleServerNotificationBody(FakeSession(), _streamed([60, 60]));

      expect(_status(result), 413);
      expect(apple.decodeCalls, 0);
    });

    test(
      'when no config is given then bodies over 512 KiB are refused',
      () async {
        final apple = FakeSignInWithApple();

        final result = await _utils(apple).handleServerNotificationBody(
          FakeSession(),
          Body.fromString(jsonEncode({'payload': 'a' * (512 * 1024)})),
        );

        expect(_status(result), 413);
        expect(apple.decodeCalls, 0);
      },
    );
  });

  group('Given AppleWebAuthenticationCallbackRoute', () {
    AppleWebAuthenticationCallbackRoute route({final AppleIdpConfig? config}) =>
        AppleWebAuthenticationCallbackRoute(
          utils: _utils(FakeSignInWithApple(), config: config),
          androidPackageIdentifier: 'com.example.app',
          webRedirectUri: 'https://example.com/auth/apple/callback',
        );

    Headers headers(final String userAgent) => Headers.build((final h) {
      h['user-agent'] = [userAgent];
    });

    const form = 'code=abc&id_token=tok&state=s%201';

    test('when a web client posts a form then it is redirected with the '
        'parameters in the query string', () async {
      final result = await route().respondToCallback(
        headers('Mozilla/5.0 (Macintosh)'),
        Body.fromString(form),
      );

      final response = result as Response;
      expect(response.statusCode, 303);
      expect(
        response.headers['location']?.single,
        'https://example.com/auth/apple/callback?code=abc&id_token=tok&state=s%201',
      );
    });

    test('when an Android client posts a form then it is redirected to the '
        'app with the parameters in the intent URI', () async {
      final result = await route().respondToCallback(
        headers('Mozilla/5.0 (Linux; Android 14)'),
        Body.fromString(form),
      );

      final response = result as Response;
      expect(response.statusCode, 307);
      expect(
        response.headers['location']?.single,
        'intent://callback?code=abc&id_token=tok&state=s%201#Intent;'
        'package=com.example.app;scheme=signinwithapple;end',
      );
    });

    test(
      'when the body is empty then the redirect carries no query string',
      () async {
        final result = await route().respondToCallback(
          headers('Mozilla/5.0 (Macintosh)'),
          Body.empty(),
        );

        expect(
          (result as Response).headers['location']?.single,
          'https://example.com/auth/apple/callback',
        );
      },
    );

    test(
      'when the declared length is over the limit then it answers 413',
      () async {
        final result =
            await route(
              config: appleTestConfig(maxRequestBodyBytes: 100),
            ).respondToCallback(
              headers('Mozilla/5.0 (Macintosh)'),
              Body.fromString('code=${'a' * 200}'),
            );

        expect(_status(result), 413);
      },
    );

    test('when a body of unknown length grows past the limit then it answers '
        '413', () async {
      final result =
          await route(
            config: appleTestConfig(maxRequestBodyBytes: 100),
          ).respondToCallback(
            headers('Mozilla/5.0 (Linux; Android 14)'),
            _streamed([60, 60]),
          );

      expect(_status(result), 413);
    });

    test(
      'when no config is given then bodies over 512 KiB are refused',
      () async {
        final result = await route().respondToCallback(
          headers('Mozilla/5.0 (Macintosh)'),
          Body.fromString('code=${'a' * (512 * 1024)}'),
        );

        expect(_status(result), 413);
      },
    );
  });
}
