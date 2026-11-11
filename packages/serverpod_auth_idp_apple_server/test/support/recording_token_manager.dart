import 'package:serverpod/serverpod.dart'
    show AuthenticationInfo, Scope, Session, Transaction, UuidValue;
import 'package:serverpod_auth_idp_server/core.dart'
    show AuthSuccess, TokenInfo, TokenManager;

/// A [TokenManager] that records `revokeAllTokens` calls and throws for
/// everything else, so a test notices any unexpected use.
class RecordingTokenManager extends TokenManager {
  /// Creates a recording manager.
  RecordingTokenManager();

  /// The `(authUserId, method)` pairs `revokeAllTokens` was called with.
  final List<(UuidValue?, String?)> revokedAll = [];

  @override
  Future<void> revokeAllTokens(
    final Session session, {
    required final UuidValue? authUserId,
    final Transaction? transaction,
    final String? method,
    final String? tokenIssuer,
  }) async {
    revokedAll.add((authUserId, method));
  }

  @override
  Future<AuthSuccess> createToken(
    final Session session, {
    required final UuidValue authUserId,
    required final String method,
    final Set<Scope>? scopes,
    final Transaction? transaction,
  }) => throw StateError('createToken is not used in this test.');

  @override
  Future<void> revokeToken(
    final Session session, {
    required final String tokenId,
    final Transaction? transaction,
    final String? tokenIssuer,
  }) => throw StateError('revokeToken is not used in this test.');

  @override
  Future<List<TokenInfo>> listTokens(
    final Session session, {
    required final UuidValue? authUserId,
    final String? method,
    final String? tokenIssuer,
    final Transaction? transaction,
  }) => throw StateError('listTokens is not used in this test.');

  @override
  Future<AuthenticationInfo?> validateToken(
    final Session session,
    final String token,
  ) => throw StateError('validateToken is not used in this test.');
}
