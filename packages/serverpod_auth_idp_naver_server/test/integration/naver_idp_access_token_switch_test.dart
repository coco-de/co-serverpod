import 'package:http/http.dart' as http;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_naver_server/serverpod_auth_idp_naver_server.dart';
import 'package:serverpod_auth_idp_server/core.dart'
    show AuthUsers, UserProfiles;
import 'package:test/test.dart';

import '../support/fake_naver_api.dart';
import '../support/recording_token_issuer.dart';
import 'test_tools/serverpod_test_tools.dart';

/// `NaverIdpConfig.allowAccessTokenLogin: false` against a real test database:
/// access-token login is refused without leaving anything behind, while the
/// authorization-code login keeps working.

NaverIdp _idp(final FakeNaverApi api, final RecordingTokenIssuer issuer) =>
    http.runWithClient(
      () => NaverIdp(
        NaverIdpConfig(
          clientId: 'test-client-id',
          clientSecret: 'secret',
          allowAccessTokenLogin: false,
        ),
        tokenIssuer: issuer,
        authUsers: const AuthUsers(),
        userProfiles: const UserProfiles(),
      ),
      () => api.client,
    );

void main() {
  withServerpod('Given NaverIdp with access-token login turned off', (
    final sessionBuilder,
    final endpoints,
  ) {
    late Session session;

    setUp(() {
      session = sessionBuilder.build();
    });

    test('when a user logs in with an access token then the login is refused '
        'and no user, account or token is created', () async {
      final api = FakeNaverApi(userInfo: naverProfile(id: 'naver-5150'));
      final issuer = RecordingTokenIssuer();

      await expectLater(
        _idp(
          api,
          issuer,
        ).loginWithAccessToken(session, accessToken: 'access-token'),
        throwsA(isA<NaverAccessTokenLoginDisabledException>()),
      );

      expect(api.requests, isEmpty);
      expect(issuer.issuedFor, isEmpty);
      final accounts = await NaverAccount.db.find(
        session,
        where: (final t) => t.userIdentifier.equals('naver-5150'),
      );
      expect(accounts, isEmpty);
    });

    test(
      'when a user logs in with an authorization code then it still works',
      () async {
        final api = FakeNaverApi(userInfo: naverProfile(id: 'naver-6006'));
        final issuer = RecordingTokenIssuer();
        final idp = _idp(api, issuer);

        final result = await http.runWithClient(
          () => idp.login(
            session,
            code: 'auth-code',
            redirectUri: 'https://app.example.com/callback',
          ),
          () => api.client,
        );

        expect(result.token, 'issued-token');
        expect(api.requestedUrls, [naverTokenEndpointUrl, naverUserInfoUrl]);
      },
    );
  });
}
