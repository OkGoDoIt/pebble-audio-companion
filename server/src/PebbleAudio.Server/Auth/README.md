# Auth

- **Admin sign-in**: ASP.NET Core Identity with passkeys only (schema version 3), one user. The first
  passkey is registered at `/setup` with the setup code from the startup log (or
  `PebbleAudio__SetupCode`); after that `/setup` answers 404. Sign-in is `/sign-in`, more passkeys are added in
  Settings. See `AdminSetup.cs` and `Pages/Admin/{Setup,Login,Settings}`.
- **Bearer tokens on `/mcp`** (`BearerTokenHandler`, scheme `Bearer`): personal tokens `pat_…` (made on the connect pages and
  revoked in Who can read, `ApiTokenService`) and OAuth access tokens `oat_…` (`OAuthTokenService`). Both are
  SHA-256 hashes at rest. The principal carries the user id, the client's name, and one `scope` claim per granted
  scope; tool code checks them with `User.HasScope(ArchiveScopes.Write)`.
- **The Pebble plugin's `/plugin/status` and `/plugin/today`** (`PluginModule.Policy`): the same `Bearer` scheme,
  personal tokens only (an `oat_…` token's audience is `/mcp`; it gets a 403), with `archive:read`. A plain 401
  without the MCP challenge. `POST /plugin/link` (anonymous, rate-limited like `POST /link`) exchanges a one-time
  code from `/connect/pebble-plugin` for a read-only `pat_…` named "Pebble plugin".
- **The 401 challenge on `/mcp`**: the MCP SDK's `AddMcp` handler answers unauthenticated requests (and unknown,
  expired, revoked, or wrong-audience tokens) with `WWW-Authenticate: Bearer resource_metadata="…/.well-known/oauth-protected-resource/mcp"`
  and serves that metadata document. `Program.cs` also serves it at the root path. `UseMcpChallengeScope` adds
  `scope="archive:read archive:write"` to that challenge (the MCP spec says it SHOULD carry one); both are named, as
  `scopes_supported` lists them, so a client asks for both and the person chooses on the consent page.
- **CORS** (`BrowserClients`): `/mcp`, both metadata documents, and `/oauth/token`, `/oauth/register`, and
  `/oauth/revoke` answer browser-run clients (the MCP Inspector) from any origin, without credentials, exposing
  `WWW-Authenticate`. Nothing else, the admin area included, sends CORS headers.
- **Scopes on tools** (`McpScopeFilters`): `/mcp` needs `archive:read`. A tool not marked read-only also needs
  `archive:write`; a read-only connection does not see it in `tools/list`, and calling it answers with an error plus
  `_meta["mcp/www_authenticate"]` (`error="insufficient_scope"` with an `error_description`). Every tool declares its
  scopes in `_meta["securitySchemes"]` (`oauth2`), which ChatGPT needs before it offers to reconnect.

## The OAuth 2.1 authorization server

Hand-rolled (the SDK has none, and OpenIddict has neither DCR nor CIMD; `docs/research-verified-2026-10-20.md` §2),
so ChatGPT ("Add custom MCP server", Authentication OAuth), Claude custom connectors, and Claude Code sign in with no
manual client setup. Every URL comes from `PebbleAudio:PublicOrigin` (`OAuthUrls`), never the request's host: the
issuer is that origin byte for byte, the resource (token audience) is `<origin>/mcp`.

| Endpoint | What it does |
| --- | --- |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata: S256 only, `none` only (public clients), CIMD and DCR, `iss` on responses, scopes `archive:read`, `archive:write`, `offline_access`. No OpenID Connect, and no `/.well-known/openid-configuration`. |
| `GET /oauth/authorize` | The Razor Page `Pages/OAuth/Authorize`. Checks the client and redirect URI (a problem there is a page, never a redirect), then response type, PKCE S256, state, resource (`<origin>/mcp` compared in canonical form, so a trailing slash, an upper-case host, or the default port still match; or absent), and scope; sends a signed-out person through the passkey sign-in and back (before any fetch, for an app whose metadata document the server has not seen, so an anonymous request cannot make it fetch a URL); asks Allow or Deny. Every redirect, error or not, carries `iss`. |
| `POST /oauth/token` | Form-encoded, antiforgery off. `authorization_code` (60-second one-time code bound to client, redirect URI, PKCE challenge, resource, scopes, and user; a second exchange ends what the first started) and `refresh_token` (rotated every time). |
| `POST /oauth/register` | RFC 7591 for public clients with https or loopback redirect URIs (and Cursor's one private-use redirect); 20 per address per hour; a registration that never connects is deleted after a week. A client that asks for `client_secret_basic` or `client_secret_post` (Gemini, reportedly) is registered as a public client and answered `token_endpoint_auth_method: "none"`, as RFC 7591 §3.2.1 allows; any other method is refused. |
| `POST /oauth/revoke` | RFC 7009. A refresh token ends its grant; an access token ends itself. |

How apps identify themselves:

- **CIMD**: a `client_id` that is an https URL is fetched through `PublicHttp` (public addresses only, no redirects,
  3 seconds, 16 KB, a 200 with JSON), checked (its `client_id` is the URL, redirect URIs are https or loopback, no
  secret), and cached for its `Cache-Control` max-age within 5 minutes to a day. When a fetch fails, the app's row
  (the last copy that validated) is used, then the copies in `KnownClients/` of ChatGPT's, Claude's, and Claude Code's
  documents: claude.ai has answered server fetches from some datacenter addresses with a challenge page, and Claude
  does not fall back to DCR once CIMD is advertised. Refresh a copy with
  `curl -o Auth/KnownClients/claude.json https://claude.ai/oauth/mcp-oauth-client-metadata`.
- **DCR**: `dcr_…` client ids from `/oauth/register`.
- **Redirect URIs** match exactly, except a loopback registration (`http://localhost/…`, `http://127.0.0.1/…`,
  `http://[::1]/…`) matches the same host, path, and query on any port (RFC 8252). Expected:
  `https://chatgpt.com/connector_platform_oauth_redirect`, `https://chatgpt.com/connector/oauth/{id}`,
  `https://claude.ai/api/mcp/auth_callback`, Claude Code's `http://localhost:<port>/callback`, Codex's
  `http://127.0.0.1:<port>/callback`, Cursor's `http://localhost:8787/callback` and
  `https://www.cursor.com/agents/mcp/oauth/callback`, and Muse's `https://agent.meta.ai/api/hatch/oauth/callback`.
  One custom scheme is allowed, by its exact scheme and host with no port: Cursor's
  `cursor://anysphere.cursor-mcp/oauth/callback` (`OAuthRedirects.IsKnownApp`). Any other custom scheme is refused,
  since any app on a device can claim one. The consent page calls a loopback or a known app's redirect "An app on
  this device".

Tokens and grants (`Data/OAuth*.cs`, tables from the `OAuth_AuthorizationServer` migration):

- A **grant** is one connection: created by the code exchange, it owns the refresh-token family. Deleting it (the
  admin's Disconnect, the phone's revoke, or reuse detection) ends its tokens and its event subscriptions at once.
- **Access tokens** `oat_…` last the "Connected app access" setting (default 60 minutes). **Refresh tokens** `ort_…`
  last the "Connected app sign-in" setting (default 60 days), and each refresh starts that period again.
- **Rotation**: every refresh returns a new refresh token and marks the old one used. The old one presented again
  within 60 seconds gets a fresh pair (ChatGPT and Claude race their own refreshes); after that it ends the grant.
  Expired, revoked, or unknown refresh tokens get `invalid_grant`.
- Every grant gets a refresh token whether or not the app asked for `offline_access`.

Where people see it: Who can read (`/access`) lists each app from the same access list as the phone (name, what it
may do, last read) with Disconnect, which ends every connection of that app, and `OAuthConnections` is the `IConnectedAssistantSource` behind the phone's `access` list
in `GET /sync/status` (sync-protocol.md §5): one entry per app with a live grant, revoked per app.
