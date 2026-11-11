import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:serverpod_auth_idp_kakao_server/serverpod_auth_idp_kakao_server.dart';
import 'package:serverpod_auth_idp_server/core.dart' show AuthUsers;
import 'package:test/test.dart';

import 'support/fake_session.dart';

/// Baseline behaviour of [KakaoIdpUtils] with the default configuration.
///
/// These tests use only API that existed before the optional app check and the
/// call timeout were added, so they describe the behaviour that must not change
/// when those options are left at their defaults.

http.Response _json(final Object body, [final int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

KakaoIdpUtils _utils(final http.Client client) => KakaoIdpUtils(
  config: KakaoIdpConfig(clientId: 'test-rest-api-key'),
  authUsers: const AuthUsers(),
  httpClient: client,
);

void main() {
  group('Given KakaoIdpUtils.fetchAccountDetails with the default config', () {
    test(
      'when Kakao answers 200 then it calls only /v2/user/me with the bearer '
      'token and parses the profile',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((final request) async {
          requests.add(request);
          return _json({
            'id': 1234567890,
            'kakao_account': {
              'email': 'User@Kakao.com',
              'profile': {'nickname': '카카오유저'},
            },
          });
        });

        final details = await _utils(
          client,
        ).fetchAccountDetails(FakeSession(), accessToken: 'access-token-1');

        expect(requests, hasLength(1));
        expect(requests.single.method, 'GET');
        expect(
          requests.single.url,
          Uri.parse('https://kapi.kakao.com/v2/user/me'),
        );
        expect(
          requests.single.headers['Authorization'],
          'Bearer access-token-1',
        );
        expect(details.userIdentifier, '1234567890');
        expect(details.email, 'user@kakao.com');
        expect(details.name, '카카오유저');
      },
    );

    test('when Kakao answers 401 then it throws '
        'KakaoAccessTokenVerificationException', () async {
      final client = MockClient((final request) async => _json({}, 401));

      await expectLater(
        _utils(
          client,
        ).fetchAccountDetails(FakeSession(), accessToken: 'bad-token'),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
    });

    test('when the body is not a JSON object then it throws '
        'KakaoAccessTokenVerificationException', () async {
      final client = MockClient(
        (final request) async => http.Response('not json', 200),
      );

      await expectLater(
        _utils(client).fetchAccountDetails(FakeSession(), accessToken: 't'),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
    });
  });

  group('Given KakaoIdpUtils.exchangeCodeForToken with the default config', () {
    test(
      'when Kakao returns an access token then it posts the code to the token '
      'endpoint and returns the token',
      () async {
        final requests = <http.Request>[];
        // OAuth2PkceUtil creates its own http.Client, so replace the client
        // factory for the duration of the call.
        final token = await http.runWithClient(
          () => _utils(MockClient((final r) async => _json({}, 500)))
              .exchangeCodeForToken(
                FakeSession(),
                code: 'auth-code',
                codeVerifier: 'verifier',
                redirectUri: 'https://app.example.com/callback',
              ),
          () => MockClient((final request) async {
            requests.add(request);
            return _json({
              'access_token': 'issued-token',
              'token_type': 'bearer',
            });
          }),
        );

        expect(token, 'issued-token');
        expect(requests, hasLength(1));
        expect(requests.single.method, 'POST');
        expect(
          requests.single.url,
          Uri.parse('https://kauth.kakao.com/oauth/token'),
        );
        final form = Uri.splitQueryString(requests.single.body);
        expect(form['grant_type'], 'authorization_code');
        expect(form['code'], 'auth-code');
        expect(form['code_verifier'], 'verifier');
        expect(form['redirect_uri'], 'https://app.example.com/callback');
        expect(form['client_id'], 'test-rest-api-key');
      },
    );

    test('when the token endpoint rejects the code then it throws '
        'KakaoAccessTokenVerificationException', () async {
      await expectLater(
        http.runWithClient(
          () => _utils(MockClient((final r) async => _json({}, 500)))
              .exchangeCodeForToken(
                FakeSession(),
                code: 'bad',
                codeVerifier: 'v',
                redirectUri: 'https://app.example.com/callback',
              ),
          () => MockClient(
            (final request) async => _json({'error': 'invalid_grant'}, 400),
          ),
        ),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );
    });
  });
}
