import 'package:serverpod/serverpod.dart'
    show Scope, Session, Transaction, UuidValue;
import 'package:serverpod_auth_idp_server/core.dart'
    show AuthSuccess, TokenIssuer;

/// A [TokenIssuer] that records the users it was asked to issue for and
/// returns a fixed token, so a login can be completed without a token manager.
class RecordingTokenIssuer extends TokenIssuer {
  /// Creates a recording issuer.
  RecordingTokenIssuer();

  /// The users a token was created for, in order.
  final List<UuidValue> issuedFor = [];

  @override
  Future<AuthSuccess> createToken(
    final Session session, {
    required final UuidValue authUserId,
    required final String method,
    final Set<Scope>? scopes,
    final Transaction? transaction,
  }) async {
    issuedFor.add(authUserId);
    return AuthSuccess(
      authStrategy: 'test',
      token: 'issued-token',
      authUserId: authUserId,
      scopeNames: const {},
    );
  }
}
