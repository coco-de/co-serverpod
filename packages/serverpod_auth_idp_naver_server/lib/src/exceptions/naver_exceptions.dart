/// Exception thrown when verifying a Naver access token fails.
///
/// This can happen when the authorization code could not be exchanged for an
/// access token, or when Naver's user info endpoint rejects the access token.
class NaverAccessTokenVerificationException implements Exception {
  /// Creates a new [NaverAccessTokenVerificationException].
  const NaverAccessTokenVerificationException();

  @override
  String toString() =>
      'NaverAccessTokenVerificationException: Failed to verify the Naver '
      'access token.';
}

/// Exception thrown when a client asks to log in with a Naver access token
/// while access-token login is turned off.
///
/// See `NaverIdpConfig.allowAccessTokenLogin`.
class NaverAccessTokenLoginDisabledException implements Exception {
  /// Creates a new [NaverAccessTokenLoginDisabledException].
  const NaverAccessTokenLoginDisabledException();

  @override
  String toString() =>
      'NaverAccessTokenLoginDisabledException: Logging in with a Naver '
      'access token is turned off. Use the authorization code login.';
}

/// Exception thrown when the user info from Naver is missing required data.
///
/// Naver requires the `id` field to be present. If it is missing — or if a
/// configured validation function rejects the account details — this exception
/// is thrown.
class NaverUserInfoMissingDataException implements Exception {
  /// Creates a new [NaverUserInfoMissingDataException].
  const NaverUserInfoMissingDataException();

  @override
  String toString() =>
      'NaverUserInfoMissingDataException: The user info received from Naver is '
      'missing required data.';
}
