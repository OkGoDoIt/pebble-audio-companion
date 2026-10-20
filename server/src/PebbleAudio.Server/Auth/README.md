# Auth

What lives here today:

- **Admin sign-in**: ASP.NET Core Identity with passkeys only (schema version 3), one user. The first
  passkey is registered at `/admin/setup` with the setup code from the startup log (or
  `PebbleAudio__SetupCode`); after that `/admin/setup` answers 404. See `AdminSetup.cs` and
  `Pages/Admin/{Setup,Login,Passkeys}`.
- **Bearer tokens** for CLI agents: `pat_…`, created and revoked at `/admin/tokens`, stored as SHA-256
  hashes (`ApiTokenService`), checked by `BearerTokenHandler` under the scheme name `Bearer`.
- **The 401 challenge on `/mcp`**: the MCP SDK's `AddMcp` handler answers unauthenticated requests with
  `WWW-Authenticate: Bearer resource_metadata="…/.well-known/oauth-protected-resource/mcp"` and serves that
  metadata document. `Program.cs` also serves it at the root path.

## Next: the OAuth 2.1 authorization server

Hand-rolled (the SDK has none; see `docs/research-verified-2026-10-20.md` §2), opaque tokens hashed at
rest, refresh rotation, `resource` into the token's audience. Endpoints it adds:

| Endpoint | Purpose |
| --- | --- |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata: issuer `PebbleAudio:PublicOrigin`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none"]`, `client_id_metadata_document_supported: true`, `authorization_response_iss_parameter_supported: true` |
| `GET /oauth/authorize` | Authorization code + PKCE, passkey sign-in, a consent page, `iss` on every response |
| `POST /oauth/token` | Code exchange and refresh rotation; form-encoded, `.DisableAntiforgery()` |
| `POST /oauth/register` | Dynamic client registration (RFC 7591) for clients that do not use CIMD |

OAuth access tokens get their own prefix and are validated by `BearerTokenHandler` against the configured
`PublicOrigin + "/mcp"` audience, never the request host.
