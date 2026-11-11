import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:serverpod_auth_idp_naver_server/serverpod_auth_idp_naver_server.dart';
import 'package:serverpod_auth_idp_server/core.dart' show AuthUsers;
import 'package:test/test.dart';

import 'support/fake_naver_api.dart';
import 'support/fake_session.dart';

/// Baseline behaviour of [NaverIdpUtils] with the default configuration.
///
/// These tests use only API that existed before the optional access-token
/// switch and the call timeout were added, so they describe the behaviour that
/// must not change when those options are left at their defaults.

NaverIdpUtils _utils(final http.Client client) => NaverIdpUtils(
  config: NaverIdpConfig(clientId: 'test-client-id', clientSecret: 'secret'),
  authUsers: const AuthUsers(),
  httpClient: client,
);

void main() {
  group('Given NaverIdpUtils.fetchAccountDetails with the default config', () {
    test('when Naver answers 200 then it calls only the user info API with the '
        'bearer token and parses the profile', () async {
      final api = FakeNaverApi(
        userInfo: naverProfile(
          id: '32742776',
          email: 'User@Naver.com',
          name: '홍길동',
        ),
      );

      final details = await _utils(
        api.client,
      ).fetchAccountDetails(FakeSession(), accessToken: 'access-token-1');

      expect(api.requests, hasLength(1));
      expect(api.requests.single.method, 'GET');
      expect(api.requests.single.url, Uri.parse(naverUserInfoUrl));
      expect(
        api.requests.single.headers['Authorization'],
        'Bearer access-token-1',
      );
      expect(details.userIdentifier, '32742776');
      expect(details.email, 'user@naver.com');
      expect(details.name, '홍길동');
    });

    test('when Naver answers 401 then it throws '
        'NaverAccessTokenVerificationException', () async {
      final client = MockClient((final request) async => jsonResponse({}, 401));

      await expectLater(
        _utils(
          client,
        ).fetchAccountDetails(FakeSession(), accessToken: 'bad-token'),
        throwsA(isA<NaverAccessTokenVerificationException>()),
      );
    });

    test('when Naver reports a failed lookup in resultcode then it throws '
        'NaverAccessTokenVerificationException', () async {
      final client = MockClient(
        (final request) async => jsonResponse({
          'resultcode': '024',
          'message': 'Authentication failed',
        }),
      );

      await expectLater(
        _utils(client).fetchAccountDetails(FakeSession(), accessToken: 't'),
        throwsA(isA<NaverAccessTokenVerificationException>()),
      );
    });
  });

  group('Given NaverIdpUtils.exchangeCodeForToken with the default config', () {
    test(
      'when Naver returns an access token then it posts the code to the token '
      'endpoint and returns the token',
      () async {
        final requests = <http.Request>[];
        // OAuth2PkceUtil creates its own http.Client, so replace the client
        // factory for the duration of the call.
        final token = await http.runWithClient(
          () => _utils(FakeNaverApi().client).exchangeCodeForToken(
            FakeSession(),
            code: 'auth-code',
            codeVerifier: null,
            redirectUri: 'https://app.example.com/callback',
          ),
          () => MockClient((final request) async {
            requests.add(request);
            return jsonResponse({
              'access_token': 'issued-token',
              'token_type': 'bearer',
            });
          }),
        );

        expect(token, 'issued-token');
        expect(requests, hasLength(1));
        expect(requests.single.method, 'POST');
        expect(requests.single.url, Uri.parse(naverTokenEndpointUrl));
        final form = Uri.splitQueryString(requests.single.body);
        expect(form['grant_type'], 'authorization_code');
        expect(form['code'], 'auth-code');
        expect(form['redirect_uri'], 'https://app.example.com/callback');
        expect(form['client_id'], 'test-client-id');
        expect(form.containsKey('code_verifier'), isFalse);
      },
    );

    test('when the token endpoint rejects the code then it throws '
        'NaverAccessTokenVerificationException', () async {
      await expectLater(
        http.runWithClient(
          () => _utils(FakeNaverApi().client).exchangeCodeForToken(
            FakeSession(),
            code: 'bad',
            codeVerifier: null,
            redirectUri: 'https://app.example.com/callback',
          ),
          () => MockClient(
            (final request) async =>
                jsonResponse({'error': 'invalid_grant'}, 400),
          ),
        ),
        throwsA(isA<NaverAccessTokenVerificationException>()),
      );
    });
  });
}
