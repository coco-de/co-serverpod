import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';

import '../generated/protocol.dart';
import '../exceptions/naver_exceptions.dart';
import 'naver_idp_config.dart';
import 'naver_profile.dart';

/// Result of a successful authentication using Naver as identity provider.
typedef NaverAuthSuccess = ({
  /// The ID of the `NaverAccount` database entity.
  UuidValue naverAccountId,

  /// The ID of the associated `AuthUser`.
  UuidValue authUserId,

  /// Details of the Naver account.
  NaverAccountDetails details,

  /// Whether the associated `AuthUser` was newly created during authentication.
  bool newAccount,

  /// The scopes granted to the associated `AuthUser`.
  Set<Scope> scopes,
});

/// Utility functions for the Naver identity provider.
///
/// These functions can be used to compose custom authentication and
/// administration flows if needed.
///
/// But for most cases, the methods exposed by [NaverIdp] and
/// `NaverIdpAdmin` should be sufficient.
class NaverIdpUtils {
  /// The method identifier used when issuing authentication tokens.
  ///
  /// serverpod 4.0.0-beta.2 의 `IdentityProvider` 계약이 요구하는
  /// instance getter 의 실제 값 소유자다 (공식 IdP 와 동일한 배치).
  String get method => 'naver';

  /// Configuration for the Naver identity provider.
  final NaverIdpConfig config;

  final AuthUsers _authUsers;

  /// HTTP client used for Naver user info calls. Injectable for testing.
  final http.Client _httpClient;

  /// Generic OAuth2 PKCE utility for token exchange.
  late final OAuth2PkceUtil _oauth2Util;

  /// Creates a new instance of [NaverIdpUtils].
  ///
  /// [httpClient] can be injected to mock Naver API calls in tests; it
  /// defaults to a standard [http.Client].
  NaverIdpUtils({
    required this.config,
    required final AuthUsers authUsers,
    final http.Client? httpClient,
  }) : _authUsers = authUsers,
       _httpClient = httpClient ?? http.Client() {
    _oauth2Util = OAuth2PkceUtil(config: config.oauth2Config);
  }

  /// Exchanges an `authorization code` for an `access token`.
  ///
  /// This method exchanges the `authorization code` received from Naver's
  /// OAuth flow for an `access token`. The [code] is the `authorization code`
  /// from the callback, and [codeVerifier] is the optional `PKCE code`
  /// verifier. Naver does not document PKCE support, so [codeVerifier] may be
  /// `null` or empty.
  ///
  /// The [redirectUri] must match the redirect URI used in the authorization
  /// request.
  ///
  /// This method delegates to the generic [OAuth2PkceUtil] for token exchange,
  /// using Naver-specific configuration.
  ///
  /// Throws [NaverAccessTokenVerificationException] if the token exchange
  /// fails.
  Future<String> exchangeCodeForToken(
    final Session session, {
    required final String code,
    required final String? codeVerifier,
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
      throw const NaverAccessTokenVerificationException();
    }
  }

  /// Authenticates a user using an `access token`.
  ///
  /// If the external user ID is not yet known in the system, a new `AuthUser`
  /// is created for it.
  ///
  /// The [transaction] parameter can be used to perform the database operations
  /// within an existing transaction.
  Future<NaverAuthSuccess> authenticate(
    final Session session, {
    required final String accessToken,
    required final Transaction? transaction,
  }) async {
    final accountDetails = await fetchAccountDetails(
      session,
      accessToken: accessToken,
    );

    var naverAccount = await NaverAccount.db.findFirstRow(
      session,
      where: (final t) =>
          t.userIdentifier.equals(accountDetails.userIdentifier),
      transaction: transaction,
    );

    final createNewUser = naverAccount == null;

    final AuthUserModel authUser = switch (createNewUser) {
      true => await _authUsers.create(session, transaction: transaction),
      false => await _authUsers.get(
        session,
        authUserId: naverAccount!.authUserId,
        transaction: transaction,
      ),
    };

    if (createNewUser) {
      naverAccount = await linkNaverAuthentication(
        session,
        authUserId: authUser.id,
        accountDetails: accountDetails,
        transaction: transaction,
      );

      await config.onAfterNaverAccountCreated?.call(
        session,
        authUser,
        naverAccount,
        transaction: transaction,
      );
    }

    try {
      final getExtraInfoCallback = config.getExtraNaverInfoCallback;
      if (getExtraInfoCallback != null) {
        await getExtraInfoCallback(
          session,
          accountDetails: accountDetails,
          accessToken: accessToken,
          transaction: transaction,
        );
      }
    } catch (e) {
      session.logAndThrow('Failed to get extra Naver account info: $e');
    }

    return (
      naverAccountId: naverAccount.id!,
      authUserId: naverAccount.authUserId,
      details: accountDetails,
      newAccount: createNewUser,
      scopes: authUser.scopes,
    );
  }

  /// Returns the account details for the given [accessToken].
  ///
  /// This method calls Naver's user info API.
  ///
  /// Throws [NaverAccessTokenVerificationException] if the user info retrieval
  /// fails.
  Future<NaverAccountDetails> fetchAccountDetails(
    final Session session, {
    required final String accessToken,
  }) async {
    // More info on the user info API:
    // https://developers.naver.com/docs/login/profile/profile.md
    final response = await _httpClient.get(
      Uri.parse('https://openapi.naver.com/v1/nid/me'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode != 200) {
      session.logAndThrow(
        'Failed to verify access token from Naver: ${response.statusCode}',
      );
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      session.logAndThrow('Invalid user info from Naver: $e');
    }

    // Delegate the provider-specific response parsing (resultcode unwrapping,
    // `response` object, field extraction) to the pure [parseNaverProfile],
    // then apply any caller-configured account validation.
    final NaverAccountDetails details;
    try {
      details = parseNaverProfile(data);
      config.naverAccountDetailsValidation(details);
    } catch (e) {
      session.logAndThrow('Invalid user info from Naver: $e');
    }

    return details;
  }

  /// Adds a Naver authentication to the given [authUserId].
  ///
  /// Returns the newly created Naver account.
  ///
  /// The [transaction] parameter can be used to perform the database operations
  /// within an existing transaction.
  Future<NaverAccount> linkNaverAuthentication(
    final Session session, {
    required final UuidValue authUserId,
    required final NaverAccountDetails accountDetails,
    final Transaction? transaction,
  }) async {
    return await NaverAccount.db.insertRow(
      session,
      NaverAccount(
        userIdentifier: accountDetails.userIdentifier,
        email: accountDetails.email,
        authUserId: authUserId,
      ),
      transaction: transaction,
    );
  }

  /// Returns the possible [NaverAccount] associated with a session.
  Future<NaverAccount?> getAccount(final Session session) {
    return switch (session.authenticated) {
      null => Future.value(null),
      _ => NaverAccount.db.findFirstRow(
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
    throw const NaverAccessTokenVerificationException();
  }
}
