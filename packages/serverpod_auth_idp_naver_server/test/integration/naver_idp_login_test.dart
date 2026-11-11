import 'package:http/http.dart' as http;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_naver_server/serverpod_auth_idp_naver_server.dart';
import 'package:serverpod_auth_idp_server/core.dart'
    show AuthUsers, UserProfiles;
import 'package:test/test.dart';

import '../support/fake_naver_api.dart';
import '../support/recording_token_issuer.dart';
import 'test_tools/serverpod_test_tools.dart';

/// `NaverIdp.loginWithAccessToken` and `NaverIdp.login` with the default
/// configuration against a real test database.
///
/// These use only API that existed before the optional access-token switch and
/// the call timeout were added: they describe the behaviour that must not
/// change when those options are left at their defaults.

NaverIdp _idp(final FakeNaverApi api, final RecordingTokenIssuer issuer) =>
    // NaverIdp builds its own NaverIdpUtils (and the OAuth2 helper its own
    // client), so route http.Client() to the stand-in while it is built.
    http.runWithClient(
      () => NaverIdp(
        NaverIdpConfig(clientId: 'test-client-id', clientSecret: 'secret'),
        tokenIssuer: issuer,
        authUsers: const AuthUsers(),
        userProfiles: const UserProfiles(),
      ),
      () => api.client,
    );

void main() {
  withServerpod('Given NaverIdp with the default configuration', (
    final sessionBuilder,
    final endpoints,
  ) {
    late Session session;

    setUp(() {
      session = sessionBuilder.build();
    });

    test('when a new user logs in with an access token then only the user info '
        'API is called and a token is issued for the new account', () async {
      final api = FakeNaverApi(
        userInfo: naverProfile(
          id: 'naver-4242',
          email: 'New@Naver.com',
          name: '신규',
        ),
      );
      final issuer = RecordingTokenIssuer();

      final result = await _idp(
        api,
        issuer,
      ).loginWithAccessToken(session, accessToken: 'access-token');

      expect(result.token, 'issued-token');
      expect(api.requestedUrls, [naverUserInfoUrl]);
      expect(issuer.issuedFor, [result.authUserId]);
      final account = await NaverAccount.db.findFirstRow(
        session,
        where: (final t) => t.userIdentifier.equals('naver-4242'),
      );
      expect(account, isNotNull);
      expect(account!.authUserId, result.authUserId);
      expect(account.email, 'new@naver.com');
    });

    test('when the same user logs in with an access token twice then the '
        'account is reused', () async {
      final api = FakeNaverApi(userInfo: naverProfile(id: 'naver-77'));
      final issuer = RecordingTokenIssuer();
      final idp = _idp(api, issuer);

      final first = await idp.loginWithAccessToken(session, accessToken: 't1');
      final second = await idp.loginWithAccessToken(session, accessToken: 't2');

      expect(second.authUserId, first.authUserId);
      final accounts = await NaverAccount.db.find(
        session,
        where: (final t) => t.userIdentifier.equals('naver-77'),
      );
      expect(accounts, hasLength(1));
    });

    test('when a user logs in with an authorization code then the code is '
        'exchanged and the user info is read', () async {
      final api = FakeNaverApi(userInfo: naverProfile(id: 'naver-9001'));
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
      expect(
        api.requests.last.headers['Authorization'],
        'Bearer exchanged-token',
      );
    });
  });
}
