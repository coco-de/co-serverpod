import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:serverpod_auth_idp_naver_server/serverpod_auth_idp_naver_server.dart';
import 'package:serverpod_auth_idp_server/core.dart'
    show AuthUsers, UserProfiles;
import 'package:test/test.dart';

import 'support/fake_naver_api.dart';
import 'support/fake_session.dart';
import 'support/recording_token_issuer.dart';

/// The optional access-token login switch and the call timeout of the Naver
/// provider.
///
/// The switch is on and the timeout generous by default; the first group pins
/// that, the others pin what the options do when they are set.

NaverIdpUtils _utils(final FakeNaverApi api, {final Duration? httpTimeout}) =>
    NaverIdpUtils(
      config: NaverIdpConfig(
        clientId: 'test-client-id',
        clientSecret: 'secret',
        httpTimeout: httpTimeout ?? NaverIdpConfig.defaultHttpTimeout,
      ),
      authUsers: const AuthUsers(),
      httpClient: api.client,
    );

const _shortTimeout = Duration(milliseconds: 50);

void main() {
  group('Given the default NaverIdpConfig', () {
    test(
      'then access-token login is allowed and the call timeout is 30 seconds',
      () {
        final config = NaverIdpConfig(clientId: 'id', clientSecret: 'secret');

        expect(config.allowAccessTokenLogin, isTrue);
        expect(config.httpTimeout, const Duration(seconds: 30));
        expect(NaverIdpConfig.defaultHttpTimeout, const Duration(seconds: 30));
      },
    );
  });

  group('Given NaverIdp with access-token login turned off', () {
    test('when loginWithAccessToken is called then it throws '
        'NaverAccessTokenLoginDisabledException before calling Naver or '
        'touching the database', () async {
      final api = FakeNaverApi();
      final issuer = RecordingTokenIssuer();
      // NaverIdp builds its own NaverIdpUtils, so route its http.Client() to
      // the stand-in while it is constructed.
      final idp = http.runWithClient(
        () => NaverIdp(
          NaverIdpConfig(
            clientId: 'id',
            clientSecret: 'secret',
            allowAccessTokenLogin: false,
          ),
          tokenIssuer: issuer,
          authUsers: const AuthUsers(),
          userProfiles: const UserProfiles(),
        ),
        () => api.client,
      );

      // FakeSession throws if the database is touched, so this also proves
      // the switch is checked before a transaction is opened.
      await expectLater(
        idp.loginWithAccessToken(FakeSession(), accessToken: 'access-token'),
        throwsA(isA<NaverAccessTokenLoginDisabledException>()),
      );
      expect(api.requests, isEmpty);
      expect(issuer.issuedFor, isEmpty);
    });
  });

  group('Given a short httpTimeout and a provider that never answers', () {
    test('when fetching the account details then it throws '
        'NaverAccessTokenVerificationException', () async {
      final api = FakeNaverApi(hang: true);
      final session = FakeSession();

      await expectLater(
        _utils(
          api,
          httpTimeout: _shortTimeout,
        ).fetchAccountDetails(session, accessToken: 't'),
        throwsA(isA<NaverAccessTokenVerificationException>()),
      );
      expect(api.requestedUrls, [naverUserInfoUrl]);
      expect(session.logs.single, contains('timed out'));
    });

    test('when exchanging the authorization code then it throws '
        'NaverAccessTokenVerificationException', () async {
      final tokenRequests = <http.Request>[];
      final utils = _utils(FakeNaverApi(), httpTimeout: _shortTimeout);

      await expectLater(
        http.runWithClient(
          () => utils.exchangeCodeForToken(
            FakeSession(),
            code: 'code',
            codeVerifier: null,
            redirectUri: 'https://app.example.com/callback',
          ),
          () => MockClient((final request) {
            tokenRequests.add(request);
            return Completer<http.Response>().future;
          }),
        ),
        throwsA(isA<NaverAccessTokenVerificationException>()),
      );
      expect(tokenRequests, hasLength(1));
    });
  });
}
