import 'dart:async';

import 'package:serverpod/serverpod.dart';
// Hide the official provider's AppleAccount model so this package's own
// AppleAccount (from the generated protocol) is unambiguous.
import 'package:serverpod_auth_idp_server/core.dart' hide AppleAccount;
import 'package:sign_in_with_apple_server/sign_in_with_apple_server.dart';

import 'apple_idp.dart';

// AppleAccount 는 `serverpod generate` 후 생성되는 모델이다.
// 생성 전까지는 아래 import 가 분석 에러를 일으킬 수 있으나 정상이다.
import '../generated/protocol.dart';

/// Callback to be invoked after a new Apple account has been created and
/// linked to an auth user. The [session] and [transaction] can be used to
/// perform additional database operations.
typedef AfterAppleAccountCreatedFunction =
    FutureOr<void> Function(
      Session session,
      AuthUserModel authUser,
      AppleAccount appleAccount, {
      required Transaction? transaction,
    });

/// Configuration for the Apple identity provider.
///
/// Ported from the official `serverpod_auth_idp_server` Apple provider, with
/// nonce replay protection added in [AppleIdpUtils.authenticate].
class AppleIdpConfig extends IdentityProviderBuilder<AppleIdp> {
  /// The service identifier for the Sign in with Apple project.
  final String serviceIdentifier;

  /// The bundle ID of the Apple-native app using Sign in with Apple.
  final String bundleIdentifier;

  /// The redirect URL used for 3rd party platforms, e.g. Android.
  final String redirectUri;

  /// The team identifier of the parent Apple Developer account.
  final String teamId;

  /// The ID of the key associated with the Sign in with Apple service.
  final String keyId;

  /// The secret contents of the private key file received once from Apple.
  final String key;

  /// The Android package identifier for the app using Sign in with Apple.
  ///
  /// Required for Android Sign in with Apple to work. If not provided, the
  /// web authentication callback route will return a 500 error for Android
  /// clients.
  final String? androidPackageIdentifier;

  /// The web app URL to redirect to after receiving Apple's web callback.
  ///
  /// Required for web Sign in with Apple to work when the server callback
  /// route is used as Apple's redirect URI.
  final String? webRedirectUri;

  /// Callback to be invoked after a new Apple account has been created
  /// and linked to an auth user.
  final AfterAppleAccountCreatedFunction? onAfterAppleAccountCreated;

  /// Creates a new Sign in with Apple configuration.
  const AppleIdpConfig({
    required this.serviceIdentifier,
    required this.bundleIdentifier,
    required this.redirectUri,
    required this.teamId,
    required this.keyId,
    required this.key,
    this.androidPackageIdentifier,
    this.webRedirectUri,
    this.onAfterAppleAccountCreated,
  });

  @override
  AppleIdp build({
    required final TokenManager tokenManager,
    required final AuthUsers authUsers,
    required final UserProfiles userProfiles,
  }) {
    return AppleIdp(
      this,
      tokenManager: tokenManager,
      authUsers: authUsers,
      userProfiles: userProfiles,
    );
  }
}

/// Creates a new [AppleIdpConfig] from keys on the `passwords.yaml` file.
///
/// This constructor requires that a [Serverpod] instance has already been
/// initialized.
///
/// Reads the following keys (identical to the official provider, so no
/// `passwords.yaml` change is required when migrating):
/// - `appleServiceIdentifier`, `appleBundleIdentifier`, `appleRedirectUri`,
///   `appleTeamId`, `appleKeyId`, `appleKey` (required)
/// - `appleAndroidPackageIdentifier`, `appleWebRedirectUri` (optional)
class AppleIdpConfigFromPasswords extends AppleIdpConfig {
  /// Creates a new [AppleIdpConfigFromPasswords] instance.
  AppleIdpConfigFromPasswords({super.onAfterAppleAccountCreated})
    : super(
        serviceIdentifier: _requirePassword('appleServiceIdentifier'),
        bundleIdentifier: _requirePassword('appleBundleIdentifier'),
        redirectUri: _requirePassword('appleRedirectUri'),
        teamId: _requirePassword('appleTeamId'),
        keyId: _requirePassword('appleKeyId'),
        key: _requirePassword('appleKey'),
        androidPackageIdentifier: Serverpod.instance.getPassword(
          'appleAndroidPackageIdentifier',
        ),
        webRedirectUri: Serverpod.instance.getPassword('appleWebRedirectUri'),
      );

  /// Reads a required [key] from the `passwords.yaml` file via the public
  /// Serverpod API, throwing a [StateError] when the key is missing.
  static String _requirePassword(final String key) {
    final password = Serverpod.instance.getPassword(key);
    if (password == null) {
      throw StateError(
        'Missing password "$key" in passwords.yaml. Add it before using '
        'AppleIdpConfigFromPasswords.',
      );
    }
    return password;
  }
}

/// Extension methods for [AppleIdpConfig].
extension AppleIdpConfigExtension on AppleIdpConfig {
  /// Converts the [AppleIdpConfig] to a [SignInWithAppleConfiguration].
  SignInWithAppleConfiguration toSignInWithAppleConfiguration() {
    return SignInWithAppleConfiguration(
      serviceIdentifier: serviceIdentifier,
      bundleIdentifier: bundleIdentifier,
      redirectUri: redirectUri,
      teamId: teamId,
      keyId: keyId,
      key: key,
    );
  }
}
