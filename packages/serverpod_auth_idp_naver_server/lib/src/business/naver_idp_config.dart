import 'dart:async';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';

import '../generated/protocol.dart';
import '../exceptions/naver_exceptions.dart';
import 'naver_idp.dart';
import 'naver_profile.dart';

/// Function to be called to check whether a Naver account details match the
/// requirements during registration.
typedef NaverAccountDetailsValidation =
    void Function(NaverAccountDetails accountDetails);

/// Function to be called to extract additional information from Naver APIs
/// using the access token. The [session] and [transaction] can be used to
/// store additional information in the database.
typedef GetExtraNaverInfoCallback =
    Future<void> Function(
      Session session, {
      required NaverAccountDetails accountDetails,
      required String accessToken,
      required Transaction? transaction,
    });

/// Callback to be invoked after a new Naver account has been created and
/// linked to an auth user. The [session] and [transaction] can be used to
/// perform additional database operations.
typedef AfterNaverAccountCreatedFunction =
    FutureOr<void> Function(
      Session session,
      AuthUserModel authUser,
      NaverAccount naverAccount, {
      required Transaction? transaction,
    });

/// Configuration for the Naver identity provider.
class NaverIdpConfig extends IdentityProviderBuilder<NaverIdp> {
  /// Default value of [httpTimeout].
  static const Duration defaultHttpTimeout = Duration(seconds: 30);

  /// The client ID from your Naver application (애플리케이션 Client ID).
  final String clientId;

  /// The client secret from your Naver application (애플리케이션 Client Secret).
  final String clientSecret;

  /// OAuth2 PKCE server config for Naver.
  ///
  /// Naver does not document PKCE support, so the code verifier is optional in
  /// the authentication flow. The configuration nonetheless reuses the generic
  /// OAuth2 PKCE utility for the token exchange.
  late final OAuth2PkceServerConfig oauth2Config;

  /// Validation function for Naver account details.
  ///
  /// This function should throw an exception if the account details do not
  /// match the requirements. If the function returns normally, the account
  /// is considered valid.
  ///
  /// It can be used to enforce additional requirements on the Naver account
  /// details before allowing the user to sign in. Note that Naver users may
  /// decline to share their email or name, so those fields may be null even
  /// for valid accounts.
  ///
  /// To avoid blocking real users with limited consent from signing in,
  /// adjust your validation function with care.
  final NaverAccountDetailsValidation naverAccountDetailsValidation;

  /// Callback that can be used with the access token to extract additional
  /// information from Naver.
  ///
  /// This callback is invoked after the Naver account has been created.
  /// It runs on EVERY authentication attempt.
  ///
  /// **CRITICAL - Do NOT create these models in the callback:**
  /// - [NaverAccount] - Breaks new account detection
  /// - `UserProfile` - Interferes with automatic profile creation
  /// - `AuthUser` - Already handled by the authentication flow
  ///
  /// Creating these models will cause the authentication flow in
  /// [NaverIdp.login] to fail or skip critical steps like user profile
  /// creation.
  ///
  /// **Safe usage:** Store data in your own custom tables, linked by
  /// [NaverAccountDetails.userIdentifier]. Keep operations lightweight.
  final GetExtraNaverInfoCallback? getExtraNaverInfoCallback;

  /// Callback to be invoked after a new Naver account has been created
  /// and linked to an auth user.
  ///
  /// This can be used to perform additional setup tasks after the Naver
  /// account has been created and linked.
  final AfterNaverAccountCreatedFunction? onAfterNaverAccountCreated;

  /// Whether [NaverIdp.loginWithAccessToken] is available. Defaults to `true`.
  ///
  /// With `false`, [NaverIdp.loginWithAccessToken] (and the endpoint method
  /// that calls it) throws [NaverAccessTokenLoginDisabledException] without
  /// calling Naver. Only the authorization code login ([NaverIdp.login]) is
  /// then available; there the server exchanges the code with its own client
  /// credentials.
  ///
  /// Turn it off when your clients do not use a native Naver SDK to obtain an
  /// access token. The setting does not affect [NaverIdpUtils.authenticate],
  /// which custom flows may still call directly.
  final bool allowAccessTokenLogin;

  /// How long a single call to a Naver API may take before it is given up and
  /// the login fails with [NaverAccessTokenVerificationException].
  ///
  /// Applies to the token exchange and the user info call. Defaults to
  /// [defaultHttpTimeout].
  final Duration httpTimeout;

  /// Creates a new instance of [NaverIdpConfig].
  NaverIdpConfig({
    required this.clientId,
    required this.clientSecret,
    this.naverAccountDetailsValidation = validateNaverAccountDetails,
    this.getExtraNaverInfoCallback,
    this.onAfterNaverAccountCreated,
    this.allowAccessTokenLogin = true,
    this.httpTimeout = defaultHttpTimeout,
  }) : oauth2Config = OAuth2PkceServerConfig(
         tokenEndpointUrl: Uri.https('nid.naver.com', '/oauth2.0/token'),
         clientId: clientId,
         clientSecret: clientSecret,
         credentialsLocation: OAuth2CredentialsLocation.body,
         parseTokenResponse: parseNaverTokenResponse,
       );

  /// Default validation function for extracting additional Naver account
  /// details.
  ///
  /// This default implementation accepts all accounts as Naver's optional
  /// fields (email, name) depend on the user's consent. Override this if you
  /// need to enforce specific requirements.
  static void validateNaverAccountDetails(
    final NaverAccountDetails accountDetails,
  ) {
    if (accountDetails.userIdentifier.isEmpty) {
      throw const NaverUserInfoMissingDataException();
    }
  }

  @override
  NaverIdp build({
    required final TokenManager tokenManager,
    required final AuthUsers authUsers,
    required final UserProfiles userProfiles,
  }) {
    return NaverIdp(
      this,
      tokenIssuer: tokenManager,
      authUsers: authUsers,
      userProfiles: userProfiles,
    );
  }
}

/// Creates a new [NaverIdpConfig] from keys on the `passwords.yaml` file.
///
/// This constructor requires that a [Serverpod] instance has already been
/// initialized.
///
/// The following keys must be present in the `passwords.yaml` file:
/// - `naverClientId`: The client ID from your Naver application
/// - `naverClientSecret`: The client secret from your Naver application
///
/// Example `passwords.yaml`:
/// ```yaml
/// naverClientId: 'your-naver-client-id'
/// naverClientSecret: 'your-naver-client-secret'
/// ```
class NaverIdpConfigFromPasswords extends NaverIdpConfig {
  /// Creates a new [NaverIdpConfigFromPasswords] instance.
  NaverIdpConfigFromPasswords({
    super.naverAccountDetailsValidation,
    super.getExtraNaverInfoCallback,
    super.onAfterNaverAccountCreated,
    super.allowAccessTokenLogin,
    super.httpTimeout,
  }) : super(
         clientId: _requirePassword('naverClientId'),
         clientSecret: _requirePassword('naverClientSecret'),
       );

  /// Reads [key] from the `passwords.yaml` file via the public Serverpod API,
  /// throwing a [StateError] when the key is missing.
  static String _requirePassword(final String key) {
    final password = Serverpod.instance.getPassword(key);
    if (password == null) {
      throw StateError(
        'Missing password "$key" in passwords.yaml. Add it before using '
        'NaverIdpConfigFromPasswords.',
      );
    }
    return password;
  }
}
