import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';

import 'kakao_idp_admin.dart';
import 'kakao_idp_config.dart';
import 'kakao_idp_utils.dart';

// Account 모델은 `serverpod generate` 산출물이다.
import '../generated/protocol.dart';

/// Main class for the Kakao identity provider.
/// The methods defined here are intended to be called from an endpoint.
///
/// The `admin` property provides access to [KakaoIdpAdmin], which contains
/// admin-related methods for managing Kakao-backed accounts.
///
/// The `utils` property provides access to [KakaoIdpUtils], which contains
/// utility methods for working with Kakao-backed accounts. These can be used
/// to implement custom authentication flows if needed.
///
/// If you would like to modify the authentication flow, consider creating
/// custom implementations of the relevant methods.
class KakaoIdp implements IdentityProvider {
  /// The method used when authenticating with the Kakao identity provider.
  @override
  String get method => utils.method;

  /// Admin operations to work with Kakao-backed accounts.
  final KakaoIdpAdmin admin;

  /// Utility functions for the Kakao identity provider.
  final KakaoIdpUtils utils;

  /// The configuration for the Kakao identity provider.
  final KakaoIdpConfig config;

  final TokenIssuer _tokenIssuer;

  final UserProfiles _userProfiles;

  KakaoIdp._(
    this.config,
    this._tokenIssuer,
    this.utils,
    this.admin,
    this._userProfiles,
  );

  /// Creates a new instance of [KakaoIdp].
  factory KakaoIdp(
    final KakaoIdpConfig config, {
    required final TokenIssuer tokenIssuer,
    final AuthUsers authUsers = const AuthUsers(),
    final UserProfiles userProfiles = const UserProfiles(),
  }) {
    final utils = KakaoIdpUtils(config: config, authUsers: authUsers);
    final admin = KakaoIdpAdmin(utils: utils);
    return KakaoIdp._(config, tokenIssuer, utils, admin, userProfiles);
  }

  /// Validates a Kakao authorization code and either logs in the associated
  /// user or creates a new user account if the Kakao account ID is not yet
  /// known.
  ///
  /// This method exchanges the `authorization code` for an `access token`
  /// using PKCE, then authenticates the user.
  ///
  /// If a new user is created an associated [UserProfile] is also created.
  Future<AuthSuccess> login(
    final Session session, {
    required final String code,
    required final String codeVerifier,
    required final String redirectUri,
    final Transaction? transaction,
  }) async {
    return await DatabaseUtil.runInTransactionOrSavepoint(
      session.db,
      transaction,
      (final transaction) async {
        final accessToken = await utils.exchangeCodeForToken(
          session,
          code: code,
          codeVerifier: codeVerifier,
          redirectUri: redirectUri,
        );

        final account = await utils.authenticate(
          session,
          accessToken: accessToken,
          transaction: transaction,
        );

        return _issueForAccount(session, account, transaction);
      },
    );
  }

  /// {@template kakao_idp.login_with_access_token}
  /// Logs in (or registers) the user from a Kakao `access token` already
  /// obtained on the client via the native Kakao SDK. Skips the
  /// authorization-code exchange and calls Kakao's user API directly.
  /// {@endtemplate}
  Future<AuthSuccess> loginWithAccessToken(
    final Session session, {
    required final String accessToken,
    final Transaction? transaction,
  }) async {
    return await DatabaseUtil.runInTransactionOrSavepoint(
      session.db,
      transaction,
      (final transaction) async {
        final account = await utils.authenticate(
          session,
          accessToken: accessToken,
          transaction: transaction,
        );

        return _issueForAccount(session, account, transaction);
      },
    );
  }

  /// Creates/updates the [UserProfile] for [account] (best effort) and issues
  /// an [AuthSuccess] token. Shared by [login] and [loginWithAccessToken].
  Future<AuthSuccess> _issueForAccount(
    final Session session,
    final KakaoAuthSuccess account,
    final Transaction? transaction,
  ) async {
    final image = account.details.image;
    if (account.newAccount) {
      try {
        await _userProfiles.createUserProfile(
          session,
          account.authUserId,
          UserProfileData(
            fullName: account.details.name?.trim(),
            email: account.details.email,
          ),
          transaction: transaction,
          imageSource: image != null ? UserImageFromUrl(image) : null,
        );
      } catch (e, stackTrace) {
        session.log(
          'Failed to create user profile for new Kakao user.',
          level: LogLevel.error,
          exception: e,
          stackTrace: stackTrace,
        );
      }
    } else if (image != null) {
      try {
        final user = await UserProfile.db.findFirstRow(
          session,
          where: (final t) => t.authUserId.equals(account.authUserId),
          transaction: transaction,
        );
        if (user != null && user.image == null) {
          await _userProfiles.setUserImageFromUrl(
            session,
            account.authUserId,
            image,
            transaction: transaction,
          );
        }
      } catch (e, stackTrace) {
        session.log(
          'Failed to update user profile image for existing Kakao user.',
          level: LogLevel.error,
          exception: e,
          stackTrace: stackTrace,
        );
      }
    }

    return _tokenIssuer.issueToken(
      session,
      authUserId: account.authUserId,
      transaction: transaction,
      method: method,
      scopes: account.scopes,
    );
  }

  /// Determines whether the current session has an associated Kakao account.
  Future<bool> hasAccount(final Session session) async =>
      await utils.getAccount(session) != null;

  @override
  Future<void> mergeAuthUsers(
    final Session session, {
    required final UuidValue userToKeepId,
    required final UuidValue userToRemoveId,
    required final Transaction transaction,
  }) async {
    await KakaoAccount.db.updateWhere(
      session,
      where: (final t) => t.authUserId.equals(userToRemoveId),
      columnValues: (final t) => [t.authUserId(userToKeepId)],
      transaction: transaction,
    );
  }
}

/// Extension to get the [KakaoIdp] instance from the [AuthServices].
extension KakaoIdpGetter on AuthServices {
  /// Returns the [KakaoIdp] instance from the [AuthServices].
  KakaoIdp get kakaoIdp => AuthServices.getIdentityProvider<KakaoIdp>();
}
