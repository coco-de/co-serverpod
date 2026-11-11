import 'dart:async';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';

import '../exceptions/kakao_exceptions.dart';
import 'kakao_idp.dart';
import 'kakao_profile.dart';

// KakaoAccount 는 `serverpod generate` 후 생성되는 모델이다.
// 생성 전까지는 아래 import 가 분석 에러를 일으킬 수 있으나 정상이다.
import '../generated/protocol.dart';

/// Function to be called to check whether a Kakao account details match the
/// requirements during registration.
typedef KakaoAccountDetailsValidation =
    void Function(KakaoAccountDetails accountDetails);

/// Function to be called to extract additional information from Kakao APIs
/// using the access token. The [session] and [transaction] can be used to
/// store additional information in the database.
typedef GetExtraKakaoInfoCallback =
    Future<void> Function(
      Session session, {
      required KakaoAccountDetails accountDetails,
      required String accessToken,
      required Transaction? transaction,
    });

/// Callback to be invoked after a new Kakao account has been created and
/// linked to an auth user. The [session] and [transaction] can be used to
/// perform additional database operations.
typedef AfterKakaoAccountCreatedFunction =
    FutureOr<void> Function(
      Session session,
      AuthUserModel authUser,
      KakaoAccount kakaoAccount, {
      required Transaction? transaction,
    });

/// Configuration for the Kakao identity provider.
class KakaoIdpConfig extends IdentityProviderBuilder<KakaoIdp> {
  /// Default value of [httpTimeout].
  static const Duration defaultHttpTimeout = Duration(seconds: 30);

  /// The REST API key (client ID) from your Kakao Developers application.
  final String clientId;

  /// The client secret from your Kakao Developers application.
  ///
  /// This is only used if the "Client Secret" feature is enabled in the
  /// Kakao Developers console. When it is disabled, this should be `null`.
  final String? clientSecret;

  /// OAuth2 PKCE server config for Kakao.
  late final OAuth2PkceServerConfig oauth2Config;

  /// Validation function for Kakao account details.
  ///
  /// This function should throw an exception if the account details do not
  /// match the requirements. If the function returns normally, the account
  /// is considered valid.
  ///
  /// It can be used to enforce additional requirements on the Kakao account
  /// details before allowing the user to sign in. Note that Kakao users may
  /// decline to share their email or profile, so email and name may be null
  /// even for valid accounts.
  ///
  /// To avoid blocking real users with limited consent from signing in,
  /// adjust your validation function with care.
  final KakaoAccountDetailsValidation kakaoAccountDetailsValidation;

  /// Callback that can be used with the access token to extract additional
  /// information from Kakao.
  ///
  /// This callback is invoked after the Kakao account has been created.
  /// It runs on EVERY authentication attempt.
  ///
  /// **CRITICAL - Do NOT create these models in the callback:**
  /// - [KakaoAccount] - Breaks new account detection
  /// - [UserProfile] - Interferes with automatic profile creation
  /// - [AuthUser] - Already handled by the authentication flow
  ///
  /// Creating these models will cause the authentication flow in
  /// [KakaoIdp.login] to fail or skip critical steps like user profile
  /// creation.
  ///
  /// **Safe usage:** Store data in your own custom tables, linked by
  /// [KakaoAccountDetails.userIdentifier]. Keep operations lightweight.
  final GetExtraKakaoInfoCallback? getExtraKakaoInfoCallback;

  /// Callback to be invoked after a new Kakao account has been created
  /// and linked to an auth user.
  ///
  /// This can be used to perform additional setup tasks after the Kakao
  /// account has been created and linked.
  final AfterKakaoAccountCreatedFunction? onAfterKakaoAccountCreated;

  /// Optional: the numeric Kakao app id that [KakaoIdp.loginWithAccessToken]
  /// accepts access tokens for. It is the "App ID" of your application in the
  /// Kakao Developers console (not the REST API key).
  ///
  /// When set, [KakaoIdp.loginWithAccessToken] first calls Kakao's access token
  /// information API (`GET /v1/user/access_token_info`) and continues only if
  /// the `app_id` it returns equals this value. If the call fails or the
  /// response carries no usable `app_id`, the login is rejected.
  ///
  /// When `null` (the default) no such call is made and access tokens are
  /// validated by the user info API only, as before. The check is not used by
  /// [KakaoIdp.login]: there the server exchanges the authorization code with
  /// its own client credentials.
  final int? expectedAppId;

  /// How long a single call to a Kakao API may take before it is given up and
  /// the login fails with [KakaoAccessTokenVerificationException].
  ///
  /// Applies to the token exchange, the user info call and the access token
  /// information call. Defaults to [defaultHttpTimeout].
  final Duration httpTimeout;

  /// Creates a new instance of [KakaoIdpConfig].
  KakaoIdpConfig({
    required this.clientId,
    this.clientSecret,
    this.kakaoAccountDetailsValidation = validateKakaoAccountDetails,
    this.getExtraKakaoInfoCallback,
    this.onAfterKakaoAccountCreated,
    this.expectedAppId,
    this.httpTimeout = defaultHttpTimeout,
  }) : oauth2Config = OAuth2PkceServerConfig(
         tokenEndpointUrl: Uri.https('kauth.kakao.com', '/oauth/token'),
         clientId: clientId,
         // Kakao's client secret is optional (only required when the
         // "Client Secret" feature is enabled). OAuth2PkceServerConfig requires
         // a non-null value, so an empty string is sent when unset — Kakao
         // ignores an empty client_secret when the feature is disabled.
         clientSecret: clientSecret ?? '',
         credentialsLocation: OAuth2CredentialsLocation.body,
         parseTokenResponse: parseKakaoTokenResponse,
       );

  /// Default validation function for Kakao account details.
  ///
  /// This default implementation accepts all accounts as Kakao's optional
  /// fields (email, name) are intentionally optional for user privacy.
  /// Override this if you need to enforce specific requirements.
  static void validateKakaoAccountDetails(
    final KakaoAccountDetails accountDetails,
  ) {
    if (accountDetails.userIdentifier.isEmpty) {
      throw const KakaoUserInfoMissingDataException();
    }
  }

  /// Parses the optional app id setting (for example the `kakaoAppId` password)
  /// into a value for [expectedAppId].
  ///
  /// Returns `null` when [value] is `null`, which leaves the check off. A value
  /// that is not a positive integer throws a [StateError]: a malformed setting
  /// must stop the server at start-up instead of silently turning the check
  /// off.
  static int? parseExpectedAppId(final String? value) {
    if (value == null) return null;
    final appId = int.tryParse(value.trim());
    if (appId == null || appId <= 0) {
      throw StateError(
        'The Kakao app id setting must be a positive integer (the "App ID" in '
        'the Kakao Developers console). Remove the setting to turn the app '
        'check off.',
      );
    }
    return appId;
  }

  @override
  KakaoIdp build({
    required final TokenManager tokenManager,
    required final AuthUsers authUsers,
    required final UserProfiles userProfiles,
  }) {
    return KakaoIdp(
      this,
      tokenIssuer: tokenManager,
      authUsers: authUsers,
      userProfiles: userProfiles,
    );
  }
}

/// Creates a new [KakaoIdpConfig] from keys on the `passwords.yaml` file.
///
/// This constructor requires that a [Serverpod] instance has already been
/// initialized.
///
/// The following keys are read from the `passwords.yaml` file:
/// - `kakaoClientId` (required): The REST API key from your Kakao application.
/// - `kakaoClientSecret` (optional): The client secret, only required when the
///   "Client Secret" feature is enabled in the Kakao Developers console.
/// - `kakaoAppId` (optional): The numeric app id for [expectedAppId]. Leave it
///   out to keep the app check off. A value that is not a positive integer
///   throws a [StateError].
///
/// Example `passwords.yaml`:
/// ```yaml
/// kakaoClientId: 'your-kakao-rest-api-key'
/// kakaoClientSecret: 'your-kakao-client-secret'
/// kakaoAppId: '123456'
/// ```
class KakaoIdpConfigFromPasswords extends KakaoIdpConfig {
  /// Creates a new [KakaoIdpConfigFromPasswords] instance.
  ///
  /// [expectedAppId] overrides the `kakaoAppId` password when given.
  KakaoIdpConfigFromPasswords({
    super.kakaoAccountDetailsValidation,
    super.getExtraKakaoInfoCallback,
    super.onAfterKakaoAccountCreated,
    super.httpTimeout,
    final int? expectedAppId,
  }) : super(
         clientId: _requirePassword('kakaoClientId'),
         clientSecret: Serverpod.instance.getPassword('kakaoClientSecret'),
         expectedAppId:
             expectedAppId ??
             KakaoIdpConfig.parseExpectedAppId(
               Serverpod.instance.getPassword('kakaoAppId'),
             ),
       );

  /// Reads a required [key] from the `passwords.yaml` file via the public
  /// Serverpod API, throwing a [StateError] when the key is missing.
  static String _requirePassword(final String key) {
    final password = Serverpod.instance.getPassword(key);
    if (password == null) {
      throw StateError(
        'Missing password "$key" in passwords.yaml. Add it before using '
        'KakaoIdpConfigFromPasswords.',
      );
    }
    return password;
  }
}
