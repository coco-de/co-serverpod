import 'package:serverpod_auth_idp_apple_server/serverpod_auth_idp_apple_server.dart';

/// An [AppleIdpConfig] with placeholder credentials and the given options.
///
/// Apple credentials are irrelevant in tests: every network call is stubbed.
AppleIdpConfig appleTestConfig({
  final bool requireNonce = false,
  final Duration httpTimeout = AppleIdpConfig.defaultHttpTimeout,
  final int maxRequestBodyBytes = AppleIdpConfig.defaultMaxRequestBodyBytes,
}) => AppleIdpConfig(
  serviceIdentifier: 'com.example.service',
  bundleIdentifier: 'com.example.app',
  redirectUri: 'https://api.example.com/auth/apple/callback',
  teamId: 'TEAMID1234',
  keyId: 'KEYID12345',
  key: 'unused-in-tests',
  requireNonce: requireNonce,
  httpTimeout: httpTimeout,
  maxRequestBodyBytes: maxRequestBodyBytes,
);
