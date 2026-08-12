import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';

import '../exceptions/kakao_exceptions.dart';
import 'kakao_idp_config.dart';
import 'kakao_profile.dart';

// KakaoAccount 는 `serverpod generate` 후 생성되는 모델이다.
import '../generated/protocol.dart';

/// Result of a successful authentication using Kakao as identity provider.
typedef KakaoAuthSuccess = ({
  /// The ID of the `KakaoAccount` database entity.
  UuidValue kakaoAccountId,

  /// The ID of the associated `AuthUser`.
  UuidValue authUserId,

  /// Details of the Kakao account.
  KakaoAccountDetails details,

  /// Whether the associated `AuthUser` was newly created during authentication.
  bool newAccount,

  /// The scopes granted to the associated `AuthUser`.
  Set<Scope> scopes,
});

/// Utility functions for the Kakao identity provider.
///
/// These functions can be used to compose custom authentication and
/// administration flows if needed.
///
/// But for most cases, the methods exposed by [KakaoIdp] and
/// [KakaoIdpAdmin] should be sufficient.
class KakaoIdpUtils {
  /// The method identifier used when issuing authentication tokens.
  ///
  /// serverpod 4.0.0-beta.2 의 `IdentityProvider` 계약이 요구하는
  /// instance getter 의 실제 값 소유자다 (공식 IdP 와 동일한 배치).
  String get method => 'kakao';

  /// Configuration for the Kakao identity provider.
  final KakaoIdpConfig config;

  final AuthUsers _authUsers;

  /// HTTP client used for Kakao user info calls. Injectable for testing.
  final http.Client _httpClient;

  /// Generic OAuth2 PKCE utility for token exchange.
  late final OAuth2PkceUtil _oauth2Util;

  /// Creates a new instance of [KakaoIdpUtils].
  ///
  /// [httpClient] can be injected to mock Kakao API calls in tests; it
  /// defaults to a standard [http.Client].
  KakaoIdpUtils({
    required this.config,
    required final AuthUsers authUsers,
    final http.Client? httpClient,
  }) : _authUsers = authUsers,
       _httpClient = httpClient ?? http.Client() {
    _oauth2Util = OAuth2PkceUtil(config: config.oauth2Config);
  }

  /// Exchanges an `authorization code` for an `access token`.
  ///
  /// This method exchanges the `authorization code` received from Kakao's
  /// OAuth flow for an `access token` using PKCE. The [code] is the
  /// `authorization code` from the callback, and [codeVerifier] is the PKCE
  /// `code verifier` that was used to generate the code challenge.
  ///
  /// The [redirectUri] must match the redirect URI used in the authorization
  /// request.
  ///
  /// This method delegates to the generic [OAuth2PkceUtil] for token exchange,
  /// using Kakao-specific configuration.
  ///
  /// Throws [KakaoAccessTokenVerificationException] if the token exchange
  /// fails.
  Future<String> exchangeCodeForToken(
    final Session session, {
    required final String code,
    required final String codeVerifier,
    required final String redirectUri,
  }) async {
    try {
      final tokenResponse = await _oauth2Util.exchangeCodeForToken(
        code: code,
        codeVerifier: codeVerifier,
        redirectUri: redirectUri,
      );
      return tokenResponse.accessToken;
    } on OAuth2Exception catch (e) {
      session.log(e.toString(), level: LogLevel.debug);
      throw const KakaoAccessTokenVerificationException();
    }
  }

  /// Authenticates a user using an `access token`.
  ///
  /// If the external user ID is not yet known in the system, a new `AuthUser`
  /// is created for it.
  ///
  /// The [transaction] parameter can be used to perform the database
  /// operations within an existing transaction.
  Future<KakaoAuthSuccess> authenticate(
    final Session session, {
    required final String accessToken,
    required final Transaction? transaction,
  }) async {
    final accountDetails = await fetchAccountDetails(
      session,
      accessToken: accessToken,
    );

    var kakaoAccount = await KakaoAccount.db.findFirstRow(
      session,
      where: (final t) =>
          t.userIdentifier.equals(accountDetails.userIdentifier),
      transaction: transaction,
    );

    final createNewUser = kakaoAccount == null;

    final AuthUserModel authUser = switch (createNewUser) {
      true => await _authUsers.create(session, transaction: transaction),
      false => await _authUsers.get(
        session,
        authUserId: kakaoAccount!.authUserId,
        transaction: transaction,
      ),
    };

    if (createNewUser) {
      kakaoAccount = await linkKakaoAuthentication(
        session,
        authUserId: authUser.id,
        accountDetails: accountDetails,
        transaction: transaction,
      );

      await config.onAfterKakaoAccountCreated?.call(
        session,
        authUser,
        kakaoAccount,
        transaction: transaction,
      );
    }

    try {
      final getExtraInfoCallback = config.getExtraKakaoInfoCallback;
      if (getExtraInfoCallback != null) {
        await getExtraInfoCallback(
          session,
          accountDetails: accountDetails,
          accessToken: accessToken,
          transaction: transaction,
        );
      }
    } catch (e) {
      session.logAndThrow('Failed to get extra Kakao account info: $e');
    }

    return (
      kakaoAccountId: kakaoAccount.id!,
      authUserId: kakaoAccount.authUserId,
      details: accountDetails,
      newAccount: createNewUser,
      scopes: authUser.scopes,
    );
  }

  /// Returns the account details for the given [accessToken].
  ///
  /// This method calls Kakao's `/v2/user/me` API.
  ///
  /// Throws [KakaoAccessTokenVerificationException] if the user info retrieval
  /// fails.
  Future<KakaoAccountDetails> fetchAccountDetails(
    final Session session, {
    required final String accessToken,
  }) async {
    // More info on the user API:
    // https://developers.kakao.com/docs/latest/en/kakaologin/rest-api#req-user-info
    final response = await _httpClient.get(
      Uri.https('kapi.kakao.com', '/v2/user/me'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode != 200) {
      session.logAndThrow(
        'Failed to verify access token from Kakao: ${response.statusCode}',
      );
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      session.logAndThrow('Invalid user info from Kakao: $e');
    }

    // Delegate the provider-specific response parsing (nested `kakao_account`
    // / `profile` fields) to the pure [parseKakaoProfile], then apply any
    // caller-configured account validation.
    final KakaoAccountDetails details;
    try {
      details = parseKakaoProfile(data);
      config.kakaoAccountDetailsValidation(details);
    } catch (e) {
      session.logAndThrow('Invalid user info from Kakao: $e');
    }

    return details;
  }

  /// Adds a Kakao authentication to the given [authUserId].
  ///
  /// Returns the newly created Kakao account.
  ///
  /// The [transaction] parameter can be used to perform the database
  /// operations within an existing transaction.
  Future<KakaoAccount> linkKakaoAuthentication(
    final Session session, {
    required final UuidValue authUserId,
    required final KakaoAccountDetails accountDetails,
    final Transaction? transaction,
  }) async {
    return await KakaoAccount.db.insertRow(
      session,
      KakaoAccount(
        userIdentifier: accountDetails.userIdentifier,
        email: accountDetails.email,
        authUserId: authUserId,
      ),
      transaction: transaction,
    );
  }

  /// Returns the possible [KakaoAccount] associated with a session.
  Future<KakaoAccount?> getAccount(final Session session) {
    return switch (session.authenticated) {
      null => Future.value(null),
      _ => KakaoAccount.db.findFirstRow(
        session,
        where: (final t) =>
            t.authUserId.equals(session.authenticated!.authUserId),
      ),
    };
  }
}

extension on Session {
  Never logAndThrow(final String message) {
    log(message, level: LogLevel.debug);
    throw const KakaoAccessTokenVerificationException();
  }
}
