import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';

import 'naver_idp_admin.dart';
import 'naver_idp_config.dart';
import 'naver_idp_utils.dart';

// Account 모델은 `serverpod generate` 산출물이다.
import '../generated/protocol.dart';

/// Main class for the Naver identity provider.
/// The methods defined here are intended to be called from an endpoint.
///
/// The `admin` property provides access to [NaverIdpAdmin], which contains
/// admin-related methods for managing Naver-backed accounts.
///
/// The `utils` property provides access to [NaverIdpUtils], which contains
/// utility methods for working with Naver-backed accounts. These can be used
/// to implement custom authentication flows if needed.
///
/// If you would like to modify the authentication flow, consider creating
/// custom implementations of the relevant methods.
class NaverIdp implements IdentityProvider {
  /// The method used when authenticating with the Naver identity provider.
  @override
  String get method => utils.method;

  /// Admin operations to work with Naver-backed accounts.
  final NaverIdpAdmin admin;

  /// Utility functions for the Naver identity provider.
  final NaverIdpUtils utils;

  /// The configuration for the Naver identity provider.
  final NaverIdpConfig config;

  final TokenIssuer _tokenIssuer;

  final UserProfiles _userProfiles;

  NaverIdp._(
    this.config,
    this._tokenIssuer,
    this.utils,
    this.admin,
    this._userProfiles,
  );

  /// Creates a new instance of [NaverIdp].
  factory NaverIdp(
    final NaverIdpConfig config, {
    required final TokenIssuer tokenIssuer,
    final AuthUsers authUsers = const AuthUsers(),
    final UserProfiles userProfiles = const UserProfiles(),
  }) {
    final utils = NaverIdpUtils(config: config, authUsers: authUsers);
    final admin = NaverIdpAdmin(utils: utils);
    return NaverIdp._(config, tokenIssuer, utils, admin, userProfiles);
  }

  /// {@macro naver_idp_endpoint.login}
  ///
  /// Naver does not document PKCE support, so [codeVerifier] is optional and
  /// may be `null`.
  Future<AuthSuccess> login(
    final Session session, {
    required final String code,
    final String? codeVerifier,
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

  /// {@macro naver_idp_endpoint.login_with_access_token}
  ///
  /// Use this when the client already obtained a Naver `access token` (e.g.
  /// via the native Naver login SDK). The server skips the authorization-code
  /// exchange and authenticates directly with the supplied token.
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
    final NaverAuthSuccess account,
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
          'Failed to create user profile for new Naver user.',
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
          'Failed to update user profile image for existing Naver user.',
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

  /// Determines whether the current session has an associated Naver account.
  Future<bool> hasAccount(final Session session) async =>
      await utils.getAccount(session) != null;

  @override
  Future<void> mergeAuthUsers(
    final Session session, {
    required final UuidValue userToKeepId,
    required final UuidValue userToRemoveId,
    required final Transaction transaction,
  }) async {
    await NaverAccount.db.updateWhere(
      session,
      where: (final t) => t.authUserId.equals(userToRemoveId),
      columnValues: (final t) => [t.authUserId(userToKeepId)],
      transaction: transaction,
    );
  }
}

/// Extension to get the [NaverIdp] instance from the [AuthServices].
extension NaverIdpGetter on AuthServices {
  /// Returns the [NaverIdp] instance from the [AuthServices].
  NaverIdp get naverIdp => AuthServices.getIdentityProvider<NaverIdp>();
}
