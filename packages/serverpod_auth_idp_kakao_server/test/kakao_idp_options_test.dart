import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:serverpod_auth_idp_kakao_server/serverpod_auth_idp_kakao_server.dart';
import 'package:serverpod_auth_idp_server/core.dart'
    show AuthUsers, UserProfiles;
import 'package:test/test.dart';

import 'support/fake_kakao_api.dart';
import 'support/fake_session.dart';
import 'support/recording_token_issuer.dart';

/// The optional app check and the call timeout of the Kakao provider.
///
/// Both are off or generous by default; the first group pins that, the others
/// pin what the options do when they are set.

KakaoIdpUtils _utils(
  final FakeKakaoApi api, {
  final int? expectedAppId,
  final Duration? httpTimeout,
}) => KakaoIdpUtils(
  config: KakaoIdpConfig(
    clientId: 'test-rest-api-key',
    expectedAppId: expectedAppId,
    httpTimeout: httpTimeout ?? KakaoIdpConfig.defaultHttpTimeout,
  ),
  authUsers: const AuthUsers(),
  httpClient: api.client,
);

const _shortTimeout = Duration(milliseconds: 50);

void main() {
  group('Given the default KakaoIdpConfig', () {
    test('then the app check is off and the call timeout is 30 seconds', () {
      final config = KakaoIdpConfig(clientId: 'id');

      expect(config.expectedAppId, isNull);
      expect(config.httpTimeout, const Duration(seconds: 30));
      expect(KakaoIdpConfig.defaultHttpTimeout, const Duration(seconds: 30));
    });

    test(
      'when verifying the token app then it completes without calling Kakao',
      () async {
        final api = FakeKakaoApi();

        await _utils(
          api,
        ).verifyAccessTokenApp(FakeSession(), accessToken: 'any-token');

        expect(api.requests, isEmpty);
      },
    );
  });

  group('Given an expected app id', () {
    test(
      'when the token was issued to that app then it asks Kakao for the token '
      'info with the bearer token and accepts it',
      () async {
        final api = FakeKakaoApi(
          tokenInfo: {'id': 1234567890, 'expires_in': 7199, 'app_id': 1234},
        );

        await _utils(
          api,
          expectedAppId: 1234,
        ).verifyAccessTokenApp(FakeSession(), accessToken: 'access-token-1');

        expect(api.requests, hasLength(1));
        expect(api.requests.single.method, 'GET');
        expect(api.requests.single.url, Uri.parse(kakaoTokenInfoUrl));
        expect(
          api.requests.single.headers['Authorization'],
          'Bearer access-token-1',
        );
      },
    );

    test('when app_id is a numeric string then it still matches', () async {
      final api = FakeKakaoApi(
        tokenInfo: {'id': 1, 'expires_in': 10, 'app_id': '1234'},
      );

      await _utils(
        api,
        expectedAppId: 1234,
      ).verifyAccessTokenApp(FakeSession(), accessToken: 't');
    });

    test('when the token was issued to a different app then it throws '
        'KakaoAccessTokenVerificationException', () async {
      final api = FakeKakaoApi(
        tokenInfo: {'id': 1, 'expires_in': 10, 'app_id': 9999},
      );
      final session = FakeSession();

      await expectLater(
        _utils(
          api,
          expectedAppId: 1234,
        ).verifyAccessTokenApp(session, accessToken: 'other-app-token'),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
      expect(session.logs, isNotEmpty);
    });

    for (final entry in <String, Object>{
      'app_id is missing': {'id': 1, 'expires_in': 10},
      'app_id is null': {'id': 1, 'app_id': null},
      'app_id is not numeric': {'id': 1, 'app_id': 'abc'},
      'app_id has a fraction': {'id': 1, 'app_id': 1234.5},
      'the body is not an object': [1234],
    }.entries) {
      test(
        'when ${entry.key} then it rejects the token instead of skipping the '
        'check',
        () async {
          final api = FakeKakaoApi(tokenInfo: entry.value);

          await expectLater(
            _utils(
              api,
              expectedAppId: 1234,
            ).verifyAccessTokenApp(FakeSession(), accessToken: 't'),
            throwsA(isA<KakaoAccessTokenVerificationException>()),
          );
        },
      );
    }

    test('when Kakao answers the token info request with 401 then it throws '
        'KakaoAccessTokenVerificationException', () async {
      final client = MockClient(
        (final request) async => jsonResponse({'code': -401}, 401),
      );

      await expectLater(
        KakaoIdpUtils(
          config: KakaoIdpConfig(clientId: 'id', expectedAppId: 1234),
          authUsers: const AuthUsers(),
          httpClient: client,
        ).verifyAccessTokenApp(FakeSession(), accessToken: 'expired'),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
    });

    test('when the response is not JSON then it throws '
        'KakaoAccessTokenVerificationException', () async {
      final client = MockClient(
        (final request) async => http.Response('<html>', 200),
      );

      await expectLater(
        KakaoIdpUtils(
          config: KakaoIdpConfig(clientId: 'id', expectedAppId: 1234),
          authUsers: const AuthUsers(),
          httpClient: client,
        ).verifyAccessTokenApp(FakeSession(), accessToken: 't'),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
    });
  });

  group('Given KakaoIdp.loginWithAccessToken with an expected app id', () {
    test('when the token belongs to a different app then it is rejected before '
        'the user info is requested and before any database access', () async {
      final api = FakeKakaoApi(
        tokenInfo: {'id': 1, 'expires_in': 10, 'app_id': 9999},
      );
      final issuer = RecordingTokenIssuer();
      // KakaoIdp builds its own KakaoIdpUtils, so route its http.Client()
      // to the stand-in while it is constructed.
      final idp = http.runWithClient(
        () => KakaoIdp(
          KakaoIdpConfig(clientId: 'id', expectedAppId: 1234),
          tokenIssuer: issuer,
          authUsers: const AuthUsers(),
          userProfiles: const UserProfiles(),
        ),
        () => api.client,
      );

      // FakeSession throws if the database is touched, so this also proves
      // the check runs before a transaction is opened.
      await expectLater(
        idp.loginWithAccessToken(FakeSession(), accessToken: 'other-app-token'),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
      expect(api.requestedUrls, [kakaoTokenInfoUrl]);
      expect(issuer.issuedFor, isEmpty);
    });
  });

  group('Given a short httpTimeout and a provider that never answers', () {
    test('when fetching the account details then it throws '
        'KakaoAccessTokenVerificationException', () async {
      final api = FakeKakaoApi(hang: true);
      final session = FakeSession();

      await expectLater(
        _utils(
          api,
          httpTimeout: _shortTimeout,
        ).fetchAccountDetails(session, accessToken: 't'),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
      expect(api.requestedUrls, [kakaoUserInfoUrl]);
      expect(session.logs.single, contains('timed out'));
    });

    test('when verifying the token app then it throws '
        'KakaoAccessTokenVerificationException', () async {
      final api = FakeKakaoApi(hang: true);

      await expectLater(
        _utils(
          api,
          expectedAppId: 1234,
          httpTimeout: _shortTimeout,
        ).verifyAccessTokenApp(FakeSession(), accessToken: 't'),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
      expect(api.requestedUrls, [kakaoTokenInfoUrl]);
    });

    test('when exchanging the authorization code then it throws '
        'KakaoAccessTokenVerificationException', () async {
      final tokenRequests = <http.Request>[];
      final utils = _utils(FakeKakaoApi(), httpTimeout: _shortTimeout);

      await expectLater(
        http.runWithClient(
          () => utils.exchangeCodeForToken(
            FakeSession(),
            code: 'code',
            codeVerifier: 'verifier',
            redirectUri: 'https://app.example.com/callback',
          ),
          () => MockClient((final request) {
            tokenRequests.add(request);
            return Completer<http.Response>().future;
          }),
        ),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
      expect(tokenRequests, hasLength(1));
    });
  });

  group('Given KakaoIdpConfig.parseExpectedAppId', () {
    test('when the password is absent then the check stays off', () {
      expect(KakaoIdpConfig.parseExpectedAppId(null), isNull);
    });

    test('when the password is a number then it is the app id', () {
      expect(KakaoIdpConfig.parseExpectedAppId('1234'), 1234);
      expect(KakaoIdpConfig.parseExpectedAppId(' 1234 '), 1234);
    });

    for (final value in ['', 'abc', '12.5', '0', '-7']) {
      test('when the password is "$value" then it fails at start-up', () {
        expect(
          () => KakaoIdpConfig.parseExpectedAppId(value),
          throwsStateError,
        );
      });
    }
  });
}
