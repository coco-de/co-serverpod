import 'package:http/http.dart' as http;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_kakao_server/serverpod_auth_idp_kakao_server.dart';
import 'package:serverpod_auth_idp_server/core.dart'
    show AuthUsers, UserProfiles;
import 'package:test/test.dart';

import '../support/fake_kakao_api.dart';
import '../support/recording_token_issuer.dart';
import 'test_tools/serverpod_test_tools.dart';

/// `KakaoIdpConfig.expectedAppId` against a real test database: what a login
/// does, and does not leave behind, when the check passes or fails.

KakaoIdp _idp(final FakeKakaoApi api, final RecordingTokenIssuer issuer) =>
    http.runWithClient(
      () => KakaoIdp(
        KakaoIdpConfig(clientId: 'test-rest-api-key', expectedAppId: 1234),
        tokenIssuer: issuer,
        authUsers: const AuthUsers(),
        userProfiles: const UserProfiles(),
      ),
      () => api.client,
    );

void main() {
  withServerpod('Given KakaoIdp with an expected app id', (
    final sessionBuilder,
    final endpoints,
  ) {
    late Session session;

    setUp(() {
      session = sessionBuilder.build();
    });

    test('when the access token was issued to that app then the token info is '
        'checked first and the user is signed in', () async {
      final api = FakeKakaoApi(
        tokenInfo: {'id': 5150, 'expires_in': 7199, 'app_id': 1234},
        userInfo: {'id': 5150},
      );
      final issuer = RecordingTokenIssuer();

      final result = await _idp(
        api,
        issuer,
      ).loginWithAccessToken(session, accessToken: 'access-token');

      expect(result.token, 'issued-token');
      expect(api.requestedUrls, [kakaoTokenInfoUrl, kakaoUserInfoUrl]);
      expect(
        api.requests.map((final r) => r.headers['Authorization']).toSet(),
        {'Bearer access-token'},
      );
      expect(issuer.issuedFor, [result.authUserId]);
    });

    test('when the access token was issued to another app then the login is '
        'rejected and no user, account or token is created', () async {
      final api = FakeKakaoApi(
        tokenInfo: {'id': 5150, 'expires_in': 7199, 'app_id': 9999},
        userInfo: {'id': 5150},
      );
      final issuer = RecordingTokenIssuer();

      await expectLater(
        _idp(
          api,
          issuer,
        ).loginWithAccessToken(session, accessToken: 'other-app-token'),
        throwsA(isA<KakaoAccessTokenVerificationException>()),
      );

      expect(api.requestedUrls, [kakaoTokenInfoUrl]);
      expect(issuer.issuedFor, isEmpty);
      final accounts = await KakaoAccount.db.find(
        session,
        where: (final t) => t.userIdentifier.equals('5150'),
      );
      expect(accounts, isEmpty);
    });

    test('when a user logs in with an authorization code then the app check is '
        'not used, because the server exchanged the code itself', () async {
      final api = FakeKakaoApi(
        tokenInfo: {'id': 1, 'expires_in': 10, 'app_id': 9999},
        userInfo: {'id': 6006},
      );
      final issuer = RecordingTokenIssuer();
      final idp = _idp(api, issuer);

      final result = await http.runWithClient(
        () => idp.login(
          session,
          code: 'auth-code',
          codeVerifier: 'verifier',
          redirectUri: 'https://app.example.com/callback',
        ),
        () => api.client,
      );

      expect(result.token, 'issued-token');
      expect(api.requestedUrls, [kakaoTokenEndpointUrl, kakaoUserInfoUrl]);
    });
  });
}
