# serverpod_auth_idp_kakao_server

Kakao (카카오) identity provider for the Serverpod authentication module
(`serverpod_auth_idp`). It mirrors the structure of the official `github`
provider and uses only the public API re-exported from
`package:serverpod_auth_idp_server/core.dart`.

Authentication uses the OAuth2 **authorization code** flow with **PKCE**
(Kakao supports PKCE). The client obtains an authorization code and a code
verifier, then calls the server `login` endpoint which exchanges the code for
an access token and resolves the Kakao user.

## Setup

1. Add the dependency in your server package:

   ```yaml
   dependencies:
     serverpod_auth_idp_kakao_server: ^0.1.0
   ```

2. Register the module in your server's `config/generator.yaml` so that
   `serverpod generate` picks up the `KakaoAccount` model and endpoint.

3. Add the Kakao credentials to `config/passwords.yaml`:

   ```yaml
   kakaoClientId: 'your-kakao-rest-api-key'
   # Only required if the "Client Secret" feature is enabled in the
   # Kakao Developers console:
   kakaoClientSecret: 'your-kakao-client-secret'
   ```

4. Register the identity provider during server start-up:

   ```dart
   import 'package:serverpod_auth_idp_kakao_server/serverpod_auth_idp_kakao_server.dart';

   // Provide the KakaoIdpConfig (or KakaoIdpConfigFromPasswords) to the
   // serverpod_auth_idp AuthServices configuration.
   final kakaoConfig = KakaoIdpConfigFromPasswords();
   ```

## Usage

The client calls the generated `kakaoIdp` endpoint:

```dart
final authSuccess = await client.kakaoIdp.login(
  code: authorizationCode,
  codeVerifier: codeVerifier,
  redirectUri: redirectUri,
);
```

## Access token login (native SDK)

A client that signs in with the native Kakao SDK sends the SDK's access token to
`loginWithAccessToken`; the server resolves the Kakao user with the user info API.
Where the client can use the authorization code flow above, prefer it: the server
then exchanges the code with its own client credentials.

```dart
final authSuccess = await client.kakaoIdp.loginWithAccessToken(
  accessToken: accessToken,
);
```

### Check the app a token was issued to (optional)

Set `expectedAppId` (the numeric **App ID** from the Kakao Developers console,
not the REST API key) to accept only access tokens issued to your app:

```dart
KakaoIdpConfig(clientId: clientId, expectedAppId: 123456);
// or: KakaoIdpConfigFromPasswords() with `kakaoAppId: '123456'` in passwords.yaml
```

`loginWithAccessToken` then calls Kakao's access token information API
(`GET https://kapi.kakao.com/v1/user/access_token_info`) before anything else and
continues only if the `app_id` in its response equals `expectedAppId`. A mismatch,
an error response or a response without a usable `app_id` rejects the login with
`KakaoAccessTokenVerificationException`.

The default is `null`: no extra call is made and the login behaves as before. The
check does not apply to `login`. A `kakaoAppId` password that is not a positive
integer stops the server at start-up with a `StateError`.

### Call timeout

`httpTimeout` (default 30 seconds) is how long one call to a Kakao API may take
(token exchange, user info, token information). Past it, the login fails with
`KakaoAccessTokenVerificationException`.

## Kakao specifics

| Item | Value |
|------|-------|
| `method` | `kakao` |
| Token endpoint | `https://kauth.kakao.com/oauth/token` |
| User info endpoint | `GET https://kapi.kakao.com/v2/user/me` |
| Credentials location | request body |
| PKCE | supported (`codeVerifier` required) |
| Token info endpoint (optional app check) | `GET https://kapi.kakao.com/v1/user/access_token_info` |

User info is parsed from `id` (numeric → string), `kakao_account.email`,
`kakao_account.profile.nickname`, and
`kakao_account.profile.profile_image_url`.

## License

BSD 3-Clause License. See [LICENSE](LICENSE).
