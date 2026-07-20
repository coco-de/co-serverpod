import 'package:serverpod/serverpod.dart';

import 'apple_idp_utils.dart';

// AppleAccount 는 `serverpod generate` 후 생성되는 모델이다.
import '../generated/protocol.dart';

/// Collection of Apple-account admin methods.
class AppleIdpAdmin {
  final AppleIdpUtils _utils;

  /// Creates a new instance of the admin utilities.
  AppleIdpAdmin({required final AppleIdpUtils utils}) : _utils = utils;

  /// Checks whether all accounts are in good standing with Apple and that the
  /// authorization has not been revoked.
  ///
  /// Accounts are checked at most every 24 hours.
  ///
  /// In case a deactivated account is encountered, [onExpiredUserAuthentication]
  /// is invoked with the auth user's ID. Then all their sessions created
  /// through Sign in with Apple should be revoked.
  Future<void> checkAccountStatus(
    final Session session, {
    required final void Function(UuidValue authUserId)
    onExpiredUserAuthentication,
    final Transaction? transaction,
    final int databaseBatchSize = 100,
  }) async {
    while (true) {
      final appleAccounts = await AppleAccount.db.find(
        session,
        where: (final t) =>
            t.lastRefreshedAt <
            DateTime.now().subtract(const Duration(days: 1)),
        limit: databaseBatchSize,
        transaction: transaction,
      );

      if (appleAccounts.isEmpty) {
        break;
      }

      for (final appleAccount in appleAccounts) {
        await _utils.refreshToken(
          session,
          appleAccount: appleAccount,
          onExpiredUserAuthentication: onExpiredUserAuthentication,
        );
      }
    }
  }
}
