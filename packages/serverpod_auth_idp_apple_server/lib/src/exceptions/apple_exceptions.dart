/// Exception thrown when a client signs in without a `nonce` while
/// `AppleIdpConfig.requireNonce` is turned on.
class AppleNonceRequiredException implements Exception {
  /// Creates a new [AppleNonceRequiredException].
  const AppleNonceRequiredException();

  @override
  String toString() =>
      'AppleNonceRequiredException: The sign-in request has no nonce, which '
      'this server requires.';
}
