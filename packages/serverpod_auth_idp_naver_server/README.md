# serverpod_auth_idp_naver_server

Naver Login (NID) identity provider for Serverpod's authentication module
(`serverpod_auth_idp`). This package is the **canonical OAuth2 mirror** of the
upstream GitHub provider, adapted for Naver.

It uses only the public API surface re-exported by
`package:serverpod_auth_idp_server/core.dart`. The OIDC-only
`IdTokenVerifierConfig` and the internal `IdpBaseEndpoint` are intentionally
not used (they are not exported), and the endpoint extends Serverpod's
`Endpoint` directly. Clients sign in with the OAuth2 authorization code
(`login`, recommended) or with an access token from the native Naver SDK
(`loginWithAccessToken`); see [Login flows](#login-flows).

## Setup

1. Add the dependency to your server package:

   ```yaml
   dependencies:
     serverpod_auth_idp_naver_server: ^0.1.0
   ```

2. Register the Naver module in your server's `config/generator.yaml` and run
   code generation so the `NaverAccount` model is produced:

   ```bash
   serverpod generate
   ```

3. Provide credentials in `passwords.yaml`:

   ```yaml
   naverClientId: 'your-naver-client-id'
   naverClientSecret: 'your-naver-client-secret'
   ```

4. Register the identity provider during server startup:

   ```dart
   AuthServices.registerIdentityProvider(
     NaverIdpConfigFromPasswords(),
   );
   ```

## Login flow

The Flutter client obtains a Naver `authorization code` and (optionally) a
`codeVerifier`, then calls the endpoint:

```dart
final authSuccess = await client.modules.naver.naverIdp.login(
  code: code,
  codeVerifier: codeVerifier, // optional — Naver does not document PKCE
  redirectUri: redirectUri,
);
```

On the server, `NaverIdp.login`:

1. Exchanges the authorization code for an access token at
   `https://nid.naver.com/oauth2.0/token`.
2. Fetches the user profile from `https://openapi.naver.com/v1/nid/me`,
   verifying the top-level `resultcode == '00'` and reading
   `response.{id, email, name, profile_image}`.
3. Creates a new `AuthUser` + `UserProfile` for first-time accounts, or returns
   a token for existing accounts.

## Login flows

| | `login` (authorization code) | `loginWithAccessToken` (native SDK access token) |
| --- | --- | --- |
| The client sends | `code` (+ optional `codeVerifier`) and `redirectUri` | the `accessToken` the SDK returned |
| The server | exchanges the code with its own client credentials, then reads the user info | reads the user info with the token |
| Prefer it | whenever the client can run the code flow | when the native SDK flow is needed |

Prefer the code flow where the client can run it: the server then obtains the
access token itself, with this application's client credentials.

### Turning access token login off (optional)

If your clients do not use a native Naver SDK, set `allowAccessTokenLogin: false`:

```dart
NaverIdpConfig(
  clientId: clientId,
  clientSecret: clientSecret,
  allowAccessTokenLogin: false,
);
```

`NaverIdp.loginWithAccessToken` (and the endpoint method that calls it) then throws
`NaverAccessTokenLoginDisabledException` without calling Naver or touching the
database. `login` is unaffected. The default is `true`, which keeps the current
behaviour. `NaverIdpUtils.authenticate`, which custom flows may call directly, is
not affected by the setting.

### Call timeout

`httpTimeout` (default 30 seconds) is how long one call to a Naver API may take
(token exchange, user info). Past it, the login fails with
`NaverAccessTokenVerificationException`.

## Differences from the GitHub provider

| Aspect | Naver |
| --- | --- |
| `method` | `'naver'` |
| Token endpoint | `https://nid.naver.com/oauth2.0/token` |
| User info | `GET https://openapi.naver.com/v1/nid/me` |
| Credentials location | request body |
| `codeVerifier` | optional (`String?`) — PKCE undocumented |
| Account table | `serverpod_auth_idp_naver_account` |

## License

BSD 3-Clause. See [LICENSE](LICENSE).
