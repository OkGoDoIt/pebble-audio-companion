# Conversation-archive server: verified research reference

Research date 2026-10-20. Condensed from research workflow `wf_e3455a79-78b` (10 topic agents plus a critic). Each fact ends with its source. **UNVERIFIED** marks a claim the researchers flagged as unverified. The "Unverified" lists and every snippet are verbatim from the result.

Names used throughout: origin `https://pebbleaudio.okgodoit.com`; MCP URL `https://pebbleaudio.okgodoit.com/mcp`. The droplet is DigitalOcean Ubuntu 22.04, 1 vCPU / 2 GB, at 134.209.0.150. It is shared with situ, domainotron, and todo, behind nginx 1.18 and certbot, with PostgreSQL 16.

## Must know before building

1. **SDK version.** Pin `ModelContextProtocol.AspNetCore` and `ModelContextProtocol.Extensions.Apps` at **2.2.0**; the "1.4.1" in one topic is stale. Set `SessionMode = HttpServerSessionMode.Stateless` explicitly. (https://api.nuget.org/v3-flatcontainer/modelcontextprotocol.aspnetcore/index.json)
2. **Events capability.** The SDK's `ServerCapabilities` has no `events` property, but ChatGPT reads a top-level `capabilities.events = {}` in `server/discover`. Override `server/discover` (with `RequestHandlers`, MCPEXP002, or an outgoing filter) to emit both `events` and `extensions["io.modelcontextprotocol/events"]`, and curl it before building events. (https://raw.githubusercontent.com/modelcontextprotocol/csharp-sdk/v2.2.0/src/ModelContextProtocol.Core/Protocol/ServerCapabilities.cs)
3. **Hand-rolled AS.** The SDK has no authorization server, and OpenIddict has neither DCR nor CIMD. Hand-roll the AS: about 7 endpoints and 4 tables, opaque tokens, no JWT. (https://github.com/openiddict/openiddict-core/issues/2404)
4. **One issuer string.** Use `https://pebbleaudio.okgodoit.com` (no trailing slash) byte-identically as the AS `issuer`, as the single PRM `authorization_servers` entry (Claude reads only the first), and as `iss` on every authorization response, errors included. Also set `authorization_response_iss_parameter_supported: true`. Otherwise ChatGPT falls back to callback-ID redirects or rejects the response. (https://developers.openai.com/plugins/build/auth)
5. **Exact resource.** The PRM `resource` must equal `https://pebbleaudio.okgodoit.com/mcp` exactly as typed. Check token audience against the configured `PublicBaseUrl + "/mcp"`, never the request host. No nginx redirect on `/mcp`, and the name needs an IPv4 A record. (https://claude.com/docs/connectors/building/authentication)
6. **AS metadata essentials.**
   - `code_challenge_methods_supported: ["S256"]` (clients MUST refuse without it).
   - `token_endpoint_auth_methods_supported: ["none"]` (the RFC 8414 default is `client_secret_basic`).
   - `client_id_metadata_document_supported: true`. Claude uses CIMD only when this and `none` are both present.

   (https://www.rfc-editor.org/rfc/rfc8414.html)
7. **Sign-in starts on a 401.** Return 401, never a 200 `isError` (Claude ignores `WWW-Authenticate` on a 200), with `WWW-Authenticate: Bearer resource_metadata="https://pebbleaudio.okgodoit.com/.well-known/oauth-protected-resource/mcp", scope="archive:read"`. Choose one owner for this: the SDK's `AddMcp` (which emits no `scope=` or `error=`) or our own middleware. Serve the PRM at both the `/mcp`-suffixed and root well-known paths. (https://claude.com/docs/connectors/building/lazy-authentication)
8. **Auth scheme scoping.** Cookie auth is the app default. Scope the opaque `Bearer` handler and the MCP challenge to the `/mcp` policy; otherwise the Razor admin, viewer, and consent pages return 401 instead of redirecting (critic).
9. **`/oauth/token`.** Accept `application/x-www-form-urlencoded` and call `.DisableAntiforgery()`. Claude allows 10 s (30 s for refresh). An expired refresh token gets `invalid_grant`. Rotate refresh tokens (MUST for public clients), with a 60 s reuse grace per family. (https://claude.com/docs/connectors/building/authentication)
10. **No OIDC scopes.** Never advertise `openid`, `email`, or `profile`, and never serve `/.well-known/openid-configuration`: ChatGPT requests advertised OIDC scopes. `offline_access` goes only in the AS `scopes_supported`, never in the PRM or `WWW-Authenticate`. (https://developers.openai.com/plugins/build/auth)
11. **CIMD fetcher.** No redirects, 200 only, at most 5 KB (16 KB allowed), and a `ConnectCallback` SSRF guard. Keep a last-good cache plus repo-seeded copies of the three known documents: claude.ai's Cloudflare has 403-challenged datacenter fetches, and once CIMD is advertised, Claude won't fall back to DCR. (https://github.com/anthropics/claude-code/issues/84263)
12. **search and fetch.** `search(query)` returns `{results:[{id,title,url}]}` and `fetch(id)` returns `{id,title,text,url,metadata}`. Return each as `structuredContent` plus the same JSON string in `content`, with an `outputSchema`, and a non-empty, absolute, token-free https `url`. Without a url, ChatGPT makes no citation. (https://developers.openai.com/api/docs/mcp.md)
13. **Tool annotations.** Every tool, including app-only widget helpers, gets a `title`, explicit `readOnlyHint`, `destructiveHint`, and `openWorldHint` booleans, and a name of 64 characters or fewer. ChatGPT treats any tool lacking `readOnlyHint` as a write action that needs confirmation. (https://developers.openai.com/api/docs/guides/custom-mcp-server.md)
14. **Claude limits.** About 150,000 characters per tool result (above that, with the sandbox on, the widget stops hydrating) and 240 s per call. Claude Code allows 25,000 tokens. Never run ffmpeg inside a tool call. (https://claude.com/docs/connectors/building.md)
15. **Widgets.**
    - A `ui://` resource with mimeType `text/html;profile=mcp-app`.
    - `_meta.ui.resourceUri` and `_meta["openai/outputTemplate"]`, emitted unconditionally.
    - Our origin in `csp.resourceDomains`, which is media-src for audio.
    - `ui.domain` left unset: Claude requires exactly `9ddf9da6bce2a3bb2f4ae0f3b55e8899.claudemcpcontent.com`, and a wrong value means no render.

    (https://claude.com/docs/connectors/building/mcp-apps/troubleshooting)
16. **ChatGPT MCP Events.**
    - Protocol 2026-07-28, webhooks only, in Work chats and dots only.
    - The secret is `whsec_` plus base64 that decodes to 24-64 bytes; signing is a Standard Webhooks `v1` HMAC.
    - Callback verification runs synchronously inside `events/subscribe`, not on the queue; failure is -32015 (the draft says -32027).
    - The body cap is 256 KiB.

    (https://developers.openai.com/plugins/build/mcp-events.md)
17. **ffmpeg and Speex.** Jammy's ffmpeg 4.4.2 has no native Speex decoder (it arrived in 5.0); it decodes through `libspeex`. Always pass `-ac 1`. Smoke-test `apt-get install --no-install-recommends ffmpeg` on a real phone file first. (https://raw.githubusercontent.com/FFmpeg/FFmpeg/release/5.0/Changelog)
18. **Droplet prerequisites.**
    - Upgrade the runtime from 10.0.7 to 10.0.13 through the backports PPA.
    - Confirm `Microsoft.AspNetCore.App` is in `dotnet --list-runtimes`.
    - The name serves `todo.okgodoit.com`'s certificate, so running certbot is a hard prerequisite.
    - nginx 1.18 needs `proxy_http_version 1.1`, `proxy_buffering off` on `/mcp`, and a raised `client_max_body_size` on `/sync`.

    (https://nginx.org/en/docs/http/ngx_http_proxy_module.html)
19. **One config sheet.** The topics disagree on port (5080 vs 5110), root (`/opt` vs `/srv`), key dir, connection-string name, env-file mode, and `ProtectSystem`. Write one config sheet (critic) that uses:
    - `MemoryMax` only, never together with `DOTNET_GCHeapHardLimit`;
    - peer auth, after checking `pg_hba.conf`;
    - systemd timers, not cron;
    - a plain loopback bind, since socket activation is untested;
    - CI on `ubuntu-24.04` with a `postgres:16` service and `dotnet tool restore`.
20. **Open decisions and gaps.** Roger must decide: nginx and certbot instead of Caddy (no Cloudflare proxy), the GitHub repo, his ChatGPT plan (it gates Events and write tools), a Postgres restart plus a B2 account, and the admin login. Two areas are unresearched: the `/sync` contract with the iPhone and the app's own user login (critic).

## 1. MCP C# SDK

### Verified facts

- **Releases.** `ModelContextProtocol.AspNetCore` latest stable is 2.2.0 (2026-08-13). Earlier: 2.1.0 (08-05), 2.0.0 (07-28, aligned with spec 2026-07-28), 1.4.1 (07-09), and 1.0.0 (02-25). Nothing newer as of 2026-10-20. (https://www.nuget.org/packages/ModelContextProtocol.AspNetCore)
- **Lockstep packages.** At 2.2.0: `ModelContextProtocol.Core`, `ModelContextProtocol`, `ModelContextProtocol.AspNetCore`, `ModelContextProtocol.Extensions.Apps`, and `ModelContextProtocol.Extensions.Tasks`. The Extensions packages exist since 2.0.0-preview.3. (https://api.nuget.org/v3-flatcontainer/modelcontextprotocol.extensions.apps/index.json)
- **Unreleased fixes.** main has fixes through 2026-10-20 (#1719, a server/discover timeout interrupting OAuth; #1903; #1844; #1924), so expect a 2.2.x or 2.3. (https://github.com/modelcontextprotocol/csharp-sdk/releases)
- **License.** Apache-2.0. The repo is moving from MIT; older contributions remain MIT. (https://raw.githubusercontent.com/modelcontextprotocol/csharp-sdk/main/LICENSE)
- **Targets.** net10.0, net9.0, and net8.0. `FrameworkReference Microsoft.AspNetCore.App`, so the host needs the ASP.NET Core shared runtime, not only `Microsoft.NETCore.App`. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/src/ModelContextProtocol.AspNetCore/ModelContextProtocol.AspNetCore.csproj)
- **Dependencies at 10.0.10.** `Microsoft.Extensions.Caching.Abstractions`, `.Hosting.Abstractions`, `.Logging.Abstractions`, `System.IO.Pipelines`, and `System.Net.ServerSentEvents`, plus `Microsoft.Extensions.AI.Abstractions` 10.8.3. (https://api.nuget.org/v3-flatcontainer/modelcontextprotocol/2.2.0/modelcontextprotocol.nuspec)
- **Protocol versions.** `McpProtocolVersions.SupportedProtocolVersions`: 2024-11-05, 2025-03-26, 2025-06-18, and 2025-11-25 (initialize handshake), plus 2026-07-28 (per-request `_meta`, no initialize). (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/src/Common/McpProtocolVersions.cs)
- **2.0.0 implements 2026-07-28.**
  - Removed: initialize (SEP-2575), and session state with `Mcp-Session-Id` (SEP-2567).
  - Added: MRTR (SEP-2322), caching hints, an extensions framework (SEP-2133), and Tasks and Apps as separate packages.
  - Deprecated: Roots, Sampling, and Logging (MCP9005).
  - Auth: RFC 9207 issuer validation, PKCE S256 required in metadata, and Enterprise Managed Authorization (SEP-990).

  (https://github.com/modelcontextprotocol/csharp-sdk/releases)
- **server/discover.** The server registers a `server/discover` handler. `DiscoverResult` defaults to `TimeToLive = 0` and `CacheScope = Private`, because spec PR #2855 makes `ttlMs` and `cacheScope` required there. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/src/ModelContextProtocol.Core/Server/McpServerImpl.cs)
- **Caching hints.** `ICacheableResult` (`TimeToLive` → `ttlMs` in ms; `CacheScope` → `public`/`private`) is on server/discover, tools/list, prompts/list, resources/list, resources/templates/list, and resources/read. Only DiscoverResult gets defaults; the others stay null unless set, for example in a `WithRequestFilters` `AddListToolsFilter`. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/src/ModelContextProtocol.Core/Protocol/ICacheableResult.cs)
- **Session modes.** `HttpServerSessionMode` is `Stateless` (the 2.x default), `Stateful`, or `StatefulForInitializeClients` (hybrid, new in 2.2.0).
  - Stateless still answers 2025-11-25-and-older `initialize` clients, one POST at a time.
  - Stateless has no GET, DELETE, or `/sse`, and no server-to-client requests or unsolicited notifications; MRTR replaces them.
  - Stateful rejects 2026-07-28 requests with -32022, so the client downgrades.

  (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/src/ModelContextProtocol.AspNetCore/HttpServerSessionMode.cs)
- **Set the mode explicitly.** The docs say: "We recommend every server set SessionMode explicitly rather than relying on the default." Stateless mints no `Mcp-Session-Id`. Legacy SSE is off by default (`EnableLegacySse` obsolete, MCP9004), and it throws at startup when combined with Stateless. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/docs/concepts/stateless/stateless.md)
- **Hosting.** `builder.Services.AddMcpServer(...).WithHttpTransport(o => o.SessionMode = HttpServerSessionMode.Stateless).WithTools<T>().WithResources<T>().WithPrompts<T>()` and `app.MapMcp("/mcp")`. `MapMcp(pattern = "")` returns `IEndpointConventionBuilder`, so `.RequireAuthorization()` and `.RequireCors()` chain onto it. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/samples/ProtectedMcpServer/Program.cs)
- **Built-in RFC 9728.** `AuthenticationBuilder.AddMcp(o => o.ResourceMetadata = new ProtectedResourceMetadata { ... })` registers `McpAuthenticationHandler` under `McpAuthenticationDefaults.AuthenticationScheme`.
  - It serves `/.well-known/oauth-protected-resource/<resource-path>`, deriving the resource from the request's scheme, host, and path.
  - On challenge it appends `WWW-Authenticate: Bearer resource_metadata="..."` to the 401.
  - It performs no authentication itself: `ForwardAuthenticate` defaults to the scheme `"Bearer"`.

  (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/src/ModelContextProtocol.AspNetCore/Authentication/McpAuthenticationHandler.cs)
- **ProtectedResourceMetadata fields.** `resource`, `authorization_servers`, `bearer_methods_supported` (default `["header"]`), `scopes_supported`, `jwks_uri`, `resource_name`, `resource_documentation`, `resource_policy_uri`, `resource_tos_uri`, and the DPoP and mTLS fields. `McpAuthenticationOptions.ResourceMetadataUri` overrides the path. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/src/ModelContextProtocol.Core/Authentication/ProtectedResourceMetadata.cs)
- **No authorization server.** The sample validates JWTs from a separate `tests/ModelContextProtocol.TestOAuthServer`. (https://github.com/modelcontextprotocol/csharp-sdk/tree/v2.2.0/tests/ModelContextProtocol.TestOAuthServer)
- **Per-item auth.** `AddAuthorizationFilters()` enables `[Authorize]`, `[Authorize(Policy=...)]`, and `[AllowAnonymous]` per tool, prompt, and resource. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/docs/concepts/filters.md)
- **Tool attribute.** `McpServerToolAttribute` has `Name`, `Title`, `Destructive`, `Idempotent`, `OpenWorld`, and `ReadOnly` (mapping to the `*Hint` annotations), `UseStructuredContent` (emits `outputSchema` plus `structuredContent`), `OutputSchemaType`, and `IconSource`. `McpMetaAttribute` (AllowMultiple) adds `_meta` entries. `Result.Meta` is on every result. `ResourceLinkBlock` has type `resource_link`. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/src/ModelContextProtocol.Core/Server/McpServerToolAttribute.cs)
- **Resources and prompts.** Resources use `[McpServerResourceType]` with `[McpServerResource(UriTemplate=..., Name=..., MimeType=...)]` methods returning `TextResourceContents` or `BlobResourceContents`. Prompts use `[McpServerPromptType]` with `[McpServerPrompt]` methods returning `ChatMessage` or `PromptMessage`. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/docs/concepts/resources/resources.md)
- **MCP Apps.** In `ModelContextProtocol.Extensions.Apps`, experimental (MCPEXP003).
  - `[McpAppUi(ResourceUri = "ui://...", Visibility = [...])]` plus `.WithMcpApps()` writes `_meta.ui = { resourceUri, visibility }`.
  - `McpApps.HtmlMimeType = "text/html;profile=mcp-app"`, and resources take `[McpMeta("ui", "{csp, prefersBorder, ...}")]`.
  - The extension id is `io.modelcontextprotocol/ui`, and `McpApps.GetUiCapability(clientCaps)` handles fallback.

  (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/docs/concepts/apps/apps.md)
- **Tasks.** SEP-2663 requires 2026-07-28. Clients opt in through `_meta` `io.modelcontextprotocol/tasks`. Stateless HTTP needs a DI-singleton or durable `IMcpTaskStore`, and `CreateTaskAsync` must persist before it returns. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/docs/concepts/tasks/tasks.md)
- **No events support.** There are no MCP Events types and no issue or PR for them. 2.1.0 added only an opt-in `subscriptions/listen` handler (`WithSubscriptionsListenHandler`, SEP-2575). (https://github.com/modelcontextprotocol/csharp-sdk/tree/v2.2.0/src/ModelContextProtocol.Core/Protocol)
- **Custom methods.** Add them through `McpServerOptions.RequestHandlers`: each `McpServerRequestHandler` is a `Method` plus a `Func<JsonRpcRequest, CancellationToken, ValueTask<JsonNode?>>`. Experimental (MCPEXP002), and they take precedence over built-ins. An incoming message filter can also answer a method. Extensions are advertised via `ServerCapabilities.Extensions`. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/src/ModelContextProtocol.Core/Server/McpServerRequestHandler.cs)
- **UNVERIFIED:** MCP Events is draft SEP-3415, and ChatGPT reportedly supports only webhook delivery (September 2026) and requires 2026-07-28. Section 4 confirms both from OpenAI's docs. (https://hookdeck.com/webhooks/guides/mcp-events)
- **HttpContext.** `IHttpContextAccessor.HttpContext` reflects the current POST (always, in stateless mode), so tools reach `HttpContext.User` for per-user scoping. (https://github.com/modelcontextprotocol/csharp-sdk/blob/v2.2.0/docs/concepts/httpcontext/httpcontext.md)
- **Critic-verified.** v2.2.0 `ServerCapabilities` has only `experimental`, `logging`, `prompts`, `resources`, `tools`, `completions`, and `extensions`. There is no `events` property and no JsonExtensionData. (https://raw.githubusercontent.com/modelcontextprotocol/csharp-sdk/v2.2.0/src/ModelContextProtocol.Core/Protocol/ServerCapabilities.cs)

### Recommendations

- **Packages.** Pin `ModelContextProtocol.AspNetCore` 2.2.0 and `ModelContextProtocol.Extensions.Apps` 2.2.0. Skip `Extensions.Tasks`, because jobs run on our own Postgres queue.
- **Session mode.** Set `SessionMode = HttpServerSessionMode.Stateless` explicitly. It needs no session affinity, and restarts lose nothing.
- **Auth wiring.** Register the opaque-token validator as an `AuthenticationHandler` under `"Bearer"`, with the MCP scheme as the challenge, so the 401 carries `resource_metadata`. Scope both to the `/mcp` policy (critic).
- **PRM.** `.AddMcp(o => o.ResourceMetadata = new() { Resource = "https://pebbleaudio.okgodoit.com/mcp", AuthorizationServers = { "https://pebbleaudio.okgodoit.com" }, ScopesSupported = [...] })`. The AS metadata is our own Minimal API.
- **Proxying.** Call `app.UseForwardedHeaders()` before `UseAuthentication`; otherwise URLs come out as `http://127.0.0.1:port`. On `/mcp` in nginx, set `proxy_buffering off` and a long `proxy_read_timeout`, because POST responses are SSE.
- **Cache hints.** Set `ttlMs`/`cacheScope` with `WithRequestFilters`: `AddListToolsFilter`, `AddListPromptsFilter`, and `AddListResourcesFilter` get `Public` with a long TTL; `AddReadResourceFilter` gets `Private`, except `ui://` (critic).
- **Annotations.** On read tools: `ReadOnly = true, Destructive = false, OpenWorld = false, Idempotent = true`. Use `UseStructuredContent = true` with record return types, and `ResourceLinkBlock` items pointing at `conversation://`.
- **Apps.** `[McpAppUi(ResourceUri = "ui://pebble/conversation-card.html")]`, the HTML as `[McpServerResource(MimeType = McpApps.HtmlMimeType)]` with `[McpMeta("ui", csp json)]`, `.WithMcpApps()`, and `<NoWarn>$(NoWarn);MCPEXP003</NoWarn>`.
- **Events.** Implement `events/list`, `events/subscribe`, and `events/unsubscribe` with `RequestHandlers` (MCPEXP002). Deliver webhooks on the Postgres queue with Standard Webhooks signing, and keep this code isolated.
- **Runtime check.** On the droplet, `dotnet --list-runtimes` must show `Microsoft.AspNetCore.App 10.0.x`. Upgrade from 10.0.7, or publish self-contained if the PPA lags.

### Risks

- The MCPEXP003 and MCPEXP002 APIs can break in minor releases. Pin exact versions and re-test on each upgrade.
- `events/*` follows a draft, and ChatGPT's guide is the only real contract.
- Stateless mode means no unsolicited notifications, `list_changed`, `resources/subscribe` push, sampling, or elicitation (except MRTR on 2026-07-28).
- The built-in challenge lacks `scope=` and `error="invalid_token"`.
- The derived `resource` (host, scheme, trailing slash) can mismatch the RFC 8707 value. Set `ResourceMetadata.Resource` explicitly.
- The runtime is 10.0.7 while the dependencies are at 10.0.10, and the ASP.NET shared framework on the droplet is unchecked.
- main has post-2.2.0 fixes, so plan a bump.
- The default `InMemoryMcpTaskStore` loses tasks on restart.

### Critic flags

- **Stale version.** The dotnet topic's "1.4.1" is stale. Only 2.x has stateless 2026-07-28, `server/discover`, and `Extensions.Apps`.
- **Events key.** The events snippet below sets only `ServerCapabilities.Extensions`. ChatGPT's top-level `events` key needs a `server/discover` override or an outgoing filter.
- **Challenge owner.** Choose one owner for the 401: SDK `AddMcp`, or our own middleware with `scope=` and `error=`. The SDK serves only the path-suffixed PRM, so add the root PRM separately.
- **Program.cs bugs.** Do not copy the snippet as-is:
  - It makes Bearer and MCP the app-wide default schemes, which breaks the Razor pages; the cookie scheme must be the default.
  - Its `OpaqueBearerHandler` derives the audience from `Request.Scheme/Host`; use `PublicBaseUrl`.
  - Its read filter makes every `resources/read` private with TTL 0; branch so `ui://` is public with 3600000.
  - It enables `XForwardedHost`, which is spoofable without `AllowedHosts`; drop it.
  - It names a tool `search_conversations`, which conflicts with OpenAI's `search`/`fetch` contract (section 10).
- **UI gating (gap).** In stateless mode, `tools/list` from a 2025-11-25 client carries no client capabilities, so `McpApps.GetUiCapability(clientCaps)` may return null. Emit `_meta.ui` and `openai/outputTemplate` unconditionally.
- **Apps spec target (gap).** Nobody confirmed which Apps spec revision `Extensions.Apps` 2.2.0 targets, and its doc comment cites `io.modelcontextprotocol/apps` while the spec id is `io.modelcontextprotocol/ui`. Read `McpApps.cs`.
- **Caching MUST (gap).** The 2026-07-28 MUST (`ttlMs` and `cacheScope` on complete results) is unmet on `tools/call`. Set it through filters.

### Unverified (verbatim)

- Whether Microsoft and Anthropic formally co-maintain the SDK in 2026. The README calls it 'The official C# SDK' under the modelcontextprotocol org but names neither company, and no maintainer statement was found.
- Exact SEP-3415 events wire format (events/list, events/subscribe params, delivery block, TTL refresh) and ChatGPT's webhook requirements. The only sources found are secondary guides from Hookdeck, WorkOS and Smithery, not the SEP text or OpenAI's own docs.
- Whether ChatGPT and Claude.ai currently send 2026-07-28 server/discover or still use 2025-11-25 initialize against remote servers. Stateless mode handles both either way.
- Whether ChatGPT still also needs the legacy openai/outputTemplate _meta key besides _meta.ui.resourceUri. WithMcpApps writes only the nested _meta.ui object. If needed, add [McpMeta("openai/outputTemplate", "ui://...")].
- Whether the Ubuntu backports PPA on 22.04 has an aspnetcore-runtime-10.0 patch newer than 10.0.7. Not checked.
- The snippet below follows the v2.2.0 public signatures read from source, but it has not been compiled. In particular, check the request-filter lambda shape (next => async (ctx, ct) => ...) and the TextResourceContents required members when building.

### Snippets

**csproj (net10.0, pinned packages)**

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <!-- MCP Apps (MCPEXP003) and custom request handlers (MCPEXP002) are experimental -->
    <NoWarn>$(NoWarn);MCPEXP003;MCPEXP002</NoWarn>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="ModelContextProtocol.AspNetCore" Version="2.2.0" />
    <PackageReference Include="ModelContextProtocol.Extensions.Apps" Version="2.2.0" />
  </ItemGroup>
</Project>
```

**Program.cs: stateless Streamable HTTP, one tool, one resource, one prompt, opaque bearer auth with RFC 9728 401 challenge**

```csharp
using System.ComponentModel;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Options;
using ModelContextProtocol.AspNetCore;
using ModelContextProtocol.AspNetCore.Authentication;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

var builder = WebApplication.CreateBuilder(args);
var baseUrl = builder.Configuration["PublicBaseUrl"]!; // https://pebbleaudio.okgodoit.com

// nginx terminates TLS; the MCP auth handler builds resource_metadata from Request.Scheme/Host.
builder.Services.Configure<ForwardedHeadersOptions>(o =>
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto | ForwardedHeaders.XForwardedHost);

builder.Services.AddSingleton<ITokenStore, PostgresTokenStore>(); // our opaque-token lookup (hash compare)
builder.Services.AddHttpContextAccessor();

builder.Services.AddAuthentication(o =>
    {
        o.DefaultAuthenticateScheme = "Bearer";                               // our opaque-token handler
        o.DefaultChallengeScheme = McpAuthenticationDefaults.AuthenticationScheme; // 401 + WWW-Authenticate resource_metadata
    })
    .AddScheme<AuthenticationSchemeOptions, OpaqueBearerHandler>("Bearer", null) // McpAuthenticationOptions.ForwardAuthenticate defaults to "Bearer"
    .AddMcp(o => o.ResourceMetadata = new()
    {
        Resource = $"{baseUrl}/mcp",
        AuthorizationServers = { baseUrl },   // Claude uses only the first entry
        ScopesSupported = ["archive:read"],
        ResourceName = "Pebble Audio",
    }); // serves GET /.well-known/oauth-protected-resource/mcp
builder.Services.AddAuthorization();

builder.Services.AddMcpServer(o => o.ServerInfo = new Implementation { Name = "pebble-audio", Version = "1.0.0" })
    .WithHttpTransport(o => o.SessionMode = HttpServerSessionMode.Stateless) // explicit, per SDK guidance
    .WithTools<ArchiveTools>()
    .WithResources<ArchiveResources>()
    .WithPrompts<ArchivePrompts>()
    .WithRequestFilters(f =>
    {
        f.AddListToolsFilter(next => async (ctx, ct) =>
        {
            var r = await next(ctx, ct);
            r.TimeToLive = TimeSpan.FromHours(1); r.CacheScope = CacheScope.Public; // ttlMs / cacheScope
            return r;
        });
        f.AddReadResourceFilter(next => async (ctx, ct) =>
        {
            var r = await next(ctx, ct);
            r.TimeToLive = TimeSpan.Zero; r.CacheScope = CacheScope.Private;
            return r;
        });
    });
    // .WithMcpApps();  // with ModelContextProtocol.Extensions.Apps + [McpAppUi] on tools

var app = builder.Build();
app.UseForwardedHeaders();
app.UseAuthentication();   // also answers the protected-resource metadata request
app.UseAuthorization();
app.MapMcp("/mcp").RequireAuthorization();
app.Run();

// ---- opaque bearer validation (no JWT) ----
sealed class OpaqueBearerHandler(IOptionsMonitor<AuthenticationSchemeOptions> o, ILoggerFactory l, UrlEncoder e, ITokenStore tokens)
    : AuthenticationHandler<AuthenticationSchemeOptions>(o, l, e)
{
    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        string? h = Request.Headers.Authorization;
        if (h is null || !h.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) return AuthenticateResult.NoResult();
        var grant = await tokens.ValidateAsync(h[7..].Trim(), resource: $"{Request.Scheme}://{Request.Host}/mcp", Context.RequestAborted);
        if (grant is null) return AuthenticateResult.Fail("invalid_token");
        var id = new ClaimsIdentity([new(ClaimTypes.NameIdentifier, grant.UserId), new("scope", grant.Scope), new("client_id", grant.ClientId)], Scheme.Name);
        return AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(id), Scheme.Name));
    }
}

// ---- one tool ----
[McpServerToolType]
public sealed class ArchiveTools(IHttpContextAccessor http)
{
    [McpServerTool(Name = "search_conversations", Title = "Search conversations",
        ReadOnly = true, Destructive = false, Idempotent = true, OpenWorld = false, UseStructuredContent = true)]
    [Description("Full-text search over the user's recorded conversations.")]
    public SearchResult Search([Description("Words to look for")] string query, int limit = 10)
    {
        var userId = http.HttpContext!.User.FindFirstValue(ClaimTypes.NameIdentifier)!;
        // ... Postgres FTS scoped to userId ...
        return new SearchResult([]);
    }
}
public sealed record SearchHit(string Id, string Title, DateTimeOffset StartedAt, string Snippet);
public sealed record SearchResult(IReadOnlyList<SearchHit> Hits);

// ---- one resource ----
[McpServerResourceType]
public sealed class ArchiveResources
{
    [McpServerResource(UriTemplate = "conversation://{id}", Name = "conversation", MimeType = "text/markdown")]
    [Description("Full transcript of one conversation.")]
    public static TextResourceContents Get(string id) =>
        new() { Uri = $"conversation://{id}", MimeType = "text/markdown", Text = "..." };
}

// ---- one prompt ----
[McpServerPromptType]
public sealed class ArchivePrompts
{
    [McpServerPrompt(Name = "recap_day"), Description("Recap what I talked about on a given day.")]
    public static ChatMessage RecapDay([Description("Date, YYYY-MM-DD")] string date) =>
        new(ChatRole.User, $"Use search_conversations to find and summarize my conversations on {date}.");
}
```

**MCP Apps widget wiring (Extensions.Apps 2.2.0)**

```csharp
// tool -> _meta.ui = { resourceUri: "ui://pebble/conversation-card.html" }  (requires .WithMcpApps())
[McpServerTool(Name = "show_conversation", ReadOnly = true, OpenWorld = false, UseStructuredContent = true)]
[McpAppUi(ResourceUri = "ui://pebble/conversation-card.html")]
public ConversationCard Show(string id) => /* structuredContent the widget renders */ default!;

// resource served as text/html;profile=mcp-app
[McpServerResource(UriTemplate = "ui://pebble/conversation-card.html", Name = "conversation-card", MimeType = McpApps.HtmlMimeType)]
[McpMeta("ui", """{"prefersBorder":true,"csp":{"connectDomains":[]}}""")]
public static string ConversationCardUi() => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "ui", "conversation-card.html"));
```

**Custom events/* methods via experimental RequestHandlers (MCPEXP002)**

```csharp
builder.Services.AddMcpServer(o =>
{
    o.Capabilities = new ServerCapabilities { Extensions = new Dictionary<string, object> { ["io.modelcontextprotocol/events"] = new { } } }; // id per SEP-3415 draft; verify
    o.RequestHandlers = [
        new McpServerRequestHandler { Method = "events/list", Handler = (req, ct) => EventsApi.ListAsync(req, ct) },
        new McpServerRequestHandler { Method = "events/subscribe", Handler = (req, ct) => EventsApi.SubscribeAsync(req, ct) },   // persist sub, enqueue webhook jobs
        new McpServerRequestHandler { Method = "events/unsubscribe", Handler = (req, ct) => EventsApi.UnsubscribeAsync(req, ct) },
    ];
});
// Handler signature: Func<JsonRpcRequest, CancellationToken, ValueTask<JsonNode?>>
```

## 2. OAuth for ChatGPT and Claude

This is our own OAuth 2.1 authorization server inside the app, so that ChatGPT, Claude (claude.ai, Desktop, mobile, Claude Code), Codex, and MCP Inspector can sign in to `https://pebbleaudio.okgodoit.com/mcp`.

### Verified facts

**MCP 2026-07-28 spec**

- **PRM.** Servers MUST implement RFC 9728 PRM, and PRM MUST include `authorization_servers` with ≥1 entry. Clients use the 401's `resource_metadata` URL if present. Otherwise they probe `https://host/.well-known/oauth-protected-resource/<mcp-path>`, then `https://host/.well-known/oauth-protected-resource`. (https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery)
- **AS discovery.** For a path-less issuer, clients try `/.well-known/oauth-authorization-server`, then `/.well-known/openid-configuration`. The document's `issuer` MUST be identical to the issuer used to build the URL, or the metadata is rejected. (https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery)
- **Registration.** CIMD is SHOULD for AS and clients. DCR is MAY and explicitly deprecated (backwards compatibility only). Client order: pre-registered → CIMD (if `client_id_metadata_document_supported`) → DCR (if `registration_endpoint`) → manual entry. (https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration)
- **CIMD rules.** The AS:
  - SHOULD fetch URL-shaped client_ids;
  - MUST check the document's `client_id` equals the URL exactly;
  - MUST check the request's `redirect_uri` is in the document;
  - MUST check the JSON is valid with the required fields;
  - SHOULD cache per HTTP cache headers.

  Required fields are `client_id`, `client_name`, and `redirect_uris`, and the client_id URL is https with a path. (https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration)
- **CIMD draft -02.** `draft-ietf-oauth-client-id-metadata-document-02` (6 July 2026; MCP still cites -00).
  - The client_id URL is https, has a path, has no userinfo, fragment, or dot segments, and should have no query. It is compared by simple string comparison.
  - The AS MUST NOT follow redirects, MUST treat any non-200 as an error, SHOULD read at most about 5 KB, MUST NOT cache errors or invalid documents, and MAY set its own minimum and maximum cache lifetime.
  - No `client_secret` or `client_secret_*` method is allowed.
  - The AS MUST NOT fetch RFC 6890 special-use addresses (SSRF), except loopback in development.
  - It SHOULD show the client_id hostname on consent.

  (https://datatracker.ietf.org/doc/draft-ietf-oauth-client-id-metadata-document/)
- **Security.** The AS MUST rotate refresh tokens for public clients, SHOULD issue short-lived access tokens, MUST serve every endpoint over HTTPS, and MUST match redirect URIs exactly. Redirects are localhost or https. The AS MUST clearly show the redirect hostname, and SHOULD warn when every redirect is localhost. (https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations)
- **PKCE.** Without `code_challenge_methods_supported`, clients MUST refuse to continue, and they MUST use S256. (https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations)
- **Resource and audience.** Clients MUST send RFC 8707 `resource` on both the authorization and token requests: the canonical URI with lowercase scheme and host, and no trailing slash unless it matters. The server MUST verify the token audience is itself, MUST 401 invalid or expired tokens, and MUST NOT pass tokens through. Tokens MUST NOT be sent in the query string. (https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
- **iss.** The AS SHOULD include `iss` in every authorization response, errors included (RFC 9207); this is expected to become a MUST. If it does so, it MUST advertise `authorization_response_iss_parameter_supported: true`. Clients compare by simple string comparison, with no normalization. (https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
- **offline_access and step-up.** Clients MAY add `offline_access` when the AS `scopes_supported` lists it. Servers SHOULD NOT put it in the `WWW-Authenticate` scope or the PRM `scopes_supported`. Insufficient scope gets a 403 with `WWW-Authenticate: Bearer error="insufficient_scope", scope="...", resource_metadata="..."`. (https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)

**RFCs**

- **RFC 9728.** Only `resource` is REQUIRED. `scopes_supported` and `resource_name` are RECOMMENDED; `authorization_servers`, `bearer_methods_supported`, `resource_documentation`, and the rest are OPTIONAL. The response is a 200 with `application/json`. The well-known path goes between host and path. When the PRM URL came from `WWW-Authenticate`, `resource` MUST equal the requested resource URL. (https://www.rfc-editor.org/rfc/rfc9728.html)
- **RFC 8414.** `issuer`, `authorization_endpoint`, `token_endpoint`, and `response_types_supported` are REQUIRED. An omitted `token_endpoint_auth_methods_supported` means `client_secret_basic`, so list `none` explicitly. An omitted `code_challenge_methods_supported` means no PKCE. `grant_types_supported` defaults to authorization_code plus implicit. The issuer is https with no query or fragment. (https://www.rfc-editor.org/rfc/rfc8414.html)
- **RFC 7591 (DCR).**
  - Request: POST `application/json` with top-level metadata.
  - Success: 201 with `client_id` plus the echoed metadata; `client_secret_expires_at` is REQUIRED only when a secret is issued.
  - Errors: 400 `{error, error_description}` with `invalid_redirect_uri`, `invalid_client_metadata`, `invalid_software_statement`, or `unapproved_software_statement`.
  - Unknown metadata MUST be ignored.
  - Defaults: `client_secret_basic`, `[authorization_code]`, and `[code]`.

  (https://www.rfc-editor.org/rfc/rfc7591.html)
- **RFC 8707.** `resource` is an absolute URI with no fragment and may repeat. An unknown, invalid, or disallowed one gets `invalid_target`. Tokens SHOULD be audience-restricted. (https://www.rfc-editor.org/rfc/rfc8707.html)
- **RFC 9207.** A supporting AS MUST include `iss` in both success and error responses, identical to the metadata `issuer`. The flag is `authorization_response_iss_parameter_supported` (default false). (https://www.rfc-editor.org/rfc/rfc9207.html)

**Claude**

- **Redirect URIs.** The hosted apps (claude.ai web, Desktop, mobile, Cowork) use exactly `https://claude.ai/api/mcp/auth_callback`. Claude Code uses an RFC 8252 loopback redirect on an ephemeral port (for example `http://localhost:3118/callback`), so match `http://localhost/callback` and `http://127.0.0.1/callback` with the port ignored. (https://claude.com/docs/connectors/building/authentication)
- **CIMD and scopes.** Claude uses CIMD only if the AS metadata has `"client_id_metadata_document_supported": true` and `"none"` in `token_endpoint_auth_methods_supported`; otherwise DCR. PKCE S256 on every request. Scope comes from the 401 challenge, else the PRM `scopes_supported`, and it adds `offline_access` if the AS `scopes_supported` lists it. (https://claude.com/docs/connectors/building/authentication)
- **Rules:**
  - Sign-in starts only on a 401; `WWW-Authenticate` on a 200 is ignored.
  - Only the first `authorization_servers` entry is used.
  - The PRM `resource` must exactly equal the MCP URL as typed, including the path.
  - Discovery, registration, and token calls get 10 s; refresh gets 30 s.
  - `/token` accepts `application/x-www-form-urlencoded`; `/register` uses `application/json`.
  - An expired refresh token gets `invalid_grant`, and a rotated refresh token comes back in the same response.
  - Egress is `160.79.104.0/21`.

  (https://claude.com/docs/connectors/building/authentication)
- **Caching and re-auth.** Claude caches PRM and AS metadata per URL for about 5 min. A 403 triggers re-auth only with `error="insufficient_scope"`. A 200 with `isError: true` never starts sign-in. (https://claude.com/docs/connectors/building/lazy-authentication)
- **Claude CIMD** `https://claude.ai/oauth/mcp-oauth-client-metadata`: `client_id` = that URL, `client_name` `Claude`, `client_uri` `https://claude.ai`, `redirect_uris` `[https://claude.ai/api/mcp/auth_callback]`, `grant_types` `[authorization_code, refresh_token, urn:ietf:params:oauth:grant-type:jwt-bearer]`, `response_types` `[code]`, `token_endpoint_auth_method` `none`. (https://claude.ai/oauth/mcp-oauth-client-metadata)
- **Claude Code CIMD** `https://claude.ai/oauth/claude-code-client-metadata`: `client_name` `Claude Code`, `redirect_uris` `[http://localhost/callback, http://127.0.0.1/callback]`, `grant_types` `[authorization_code, refresh_token]`, `response_types` `[code]`, `token_endpoint_auth_method` `none`. (https://claude.ai/oauth/claude-code-client-metadata)
- **Cloudflare challenges.** An open issue (Aug-Oct 2026) reports claude.ai's Cloudflare sometimes answering server fetches of `/oauth/claude-code-client-metadata` with `403 cf-mitigated: challenge`, depending on source-IP reputation (Fly.io shared egress; DO not mentioned). Workaround: cache and serve the last good copy. (https://github.com/anthropics/claude-code/issues/84263)
- **Connectivity.** IPv4-only, and a public A record is required. A 3xx to another host drops `Authorization`. Accept the canonical `aud` form (lowercase scheme and host, no trailing slash, no default port). Errors carry an `ofid_` reference for github.com/anthropics/claude-ai-mcp. (https://claude.com/docs/connectors/building/troubleshooting)
- **Testing.** There is no staging harness. Add a custom connector (any plan, Customize > Connectors), use `npx @modelcontextprotocol/inspector --cli <url> --transport http --method tools/list`, or in Claude Code run `claude mcp add --transport http <name> <url>`, then `/mcp`. (https://claude.com/docs/connectors/building/testing)

**ChatGPT**

- **Redirect URIs and client_ids.** `https://chatgpt.com/connector_platform_oauth_redirect` (stable) and CIMD client_id `https://chatgpt.com/oauth/client.json` when the AS meets the issuer-identification rules. Otherwise `https://chatgpt.com/connector/oauth/{callback_id}` and `https://chatgpt.com/oauth/{callback_id}/client.json`. (https://developers.openai.com/plugins/build/auth)
- **Issuer-identification rules.** `authorization_response_iss_parameter_supported: true`, the same exact issuer string in the AS metadata and the PRM `authorization_servers`, and `iss` in every success and error authorization response, compared by exact match. ChatGPT and Codex reject a missing or mismatched `iss`. (https://developers.openai.com/plugins/build/auth)
- **Metadata requirements.** `issuer`, `authorization_endpoint`, `token_endpoint`, and `code_challenge_methods_supported` containing `S256` (no S256 = unsupported). `client_id_metadata_document_supported: true` enables CIMD, and `registration_endpoint` enables DCR. The auth method comes from the intersection of the AS list and ChatGPT's CIMD list (`none`, `private_key_jwt`), preferring its singular `token_endpoint_auth_method`; the AS should reject methods outside the intersection. (https://developers.openai.com/plugins/build/auth)
- **ChatGPT CIMD** `https://chatgpt.com/oauth/client.json`: `token_endpoint_auth_method` `private_key_jwt`, `token_endpoint_auth_methods_supported` `[none, private_key_jwt]`, RS256, `jwks_uri` `https://chatgpt.com/oauth/jwks.json`, `redirect_uris` `[https://chatgpt.com/connector_platform_oauth_redirect]`, and grant types authorization_code and refresh_token. An AS that offers only `none` gets public-client requests. (https://chatgpt.com/oauth/client.json)
- **Behavior.**
  - `resource=<MCP URL>` goes on both the authorize and token requests, and ChatGPT expects it copied into the token audience.
  - `Authorization: Bearer` goes on every MCP request.
  - Its 401 example is `Bearer resource_metadata="...", scope="..."`.
  - DCR runs once per connection and the client_id is reused, so a dead client means `invalid_client`.
  - Advertised `openid`, `email`, or `profile` scopes are requested by default.

  (https://developers.openai.com/plugins/build/auth)
- **Setup.** chatgpt.com/plugins → + → Add custom MCP server, with auth OAuth, No authentication, or "OAuth or no authentication". Static credentials are used first if given, else CIMD (if advertised and chosen) or DCR. There is no static bearer-header option. Tools without `readOnlyHint` are write actions needing confirmation. (https://developers.openai.com/api/docs/guides/custom-mcp-server)
- **Egress IPs.** Published at `https://openai.com/chatgpt-connectors.json`; they change over time. (https://developers.openai.com/api/docs/guides/ip-addresses)

**Tools and libraries**

- **MCP Inspector.** `npx @modelcontextprotocol/inspector` (Node ≥22.19) supports DCR, static `--client-id`/`--client-secret`, or `--client-metadata-url` (CIMD). Callbacks: web `http://127.0.0.1:6274/oauth/callback` (follows the page origin); CLI and TUI `http://127.0.0.1:6276/oauth/callback`. It handles a mid-session 401 and `insufficient_scope` step-up, and `--relogin` revokes at the AS. (https://modelcontextprotocol.io/docs/2026-07-28/tools/inspector/authorization)
- **OpenIddict.** `OpenIddict.AspNetCore` 7.7.2 (Apache-2.0, net10.0) has no DCR (#2404 open, targeting 8.0.0-preview.5). CIMD PR #2416 was closed unmerged on Feb 3, 2026, with CIMD called "too early". (https://github.com/openiddict/openiddict-core/issues/2404)
- **SDK coverage.** SDK 2.2.0 covers only the resource-server side (`McpAuthenticationOptions.ResourceMetadata`, and `ResourceMetadataUri` defaulting to `/.well-known/oauth-protected-resource/<resource-path>`, used in the 401). It has no AS. (https://csharp.sdk.modelcontextprotocol.io/v1/api/ModelContextProtocol.AspNetCore.Authentication.McpAuthenticationOptions.html)
- **Antiforgery.** Form-binding Minimal API endpoints require antiforgery by default, and `.DisableAntiforgery()` opts out. `/token` needs the opt-out; the consent POST keeps antiforgery. (https://learn.microsoft.com/en-us/aspnet/core/security/anti-request-forgery?view=aspnetcore-10.0)

### Recommendations

The exact PRM, AS-metadata, 401, authorize, token, and DCR wire shapes are in the snippets below.

**Decisions**

- **One origin for both roles.** Issuer `https://pebbleaudio.okgodoit.com` (no path, no trailing slash); resource `https://pebbleaudio.okgodoit.com/mcp`. Users type exactly that URL.
- **Hand-roll the AS.** Not OpenIddict. Use the SDK only for transport, plus either `McpAuthenticationOptions` or about 20 lines of our own PRM and challenge middleware, not both.

**Endpoints and metadata**

- **Endpoints.**
  - `GET /.well-known/oauth-protected-resource/mcp` and `GET /.well-known/oauth-protected-resource` (same JSON)
  - `GET /.well-known/oauth-authorization-server`
  - `GET /oauth/authorize`, plus `POST /oauth/authorize/consent`
  - `POST /oauth/token`
  - `POST /oauth/register` (the DCR fallback)
  - `POST /oauth/revoke` (RFC 7009, optional; Inspector `--relogin`)

  No `/.well-known/openid-configuration`.
- **Metadata contents.** PRM: one `authorization_servers` entry, `scopes_supported ["archive:read"]`, and `bearer_methods_supported ["header"]`. AS metadata: `none` as the only auth method (Claude requires it, and ChatGPT picks it from the intersection, so no private_key_jwt or JWKS work), plus `offline_access` in `scopes_supported`.
- **The 401.** Every `/mcp` request without a valid bearer gets it, initialize and GET/DELETE included, from middleware before the SDK runs, with a JSON body `{error, error_description}`. Add `error="invalid_token"` when a token was sent but is unknown, expired, revoked, or for the wrong audience.

**Authorize flow**

- **Client resolution.** A `client_id` starting with `https://` is CIMD; otherwise look it up in `oauth_clients`. An invalid `client_id` or `redirect_uri` gets an error page and NEVER a redirect. All other errors redirect with `error`, `error_description`, `state`, and `iss`.
- **CIMD fetcher.**
  - Use `SocketsHttpHandler { AllowAutoRedirect = false, ConnectCallback }` that refuses non-global addresses (loopback, RFC 1918, 100.64/10, link-local, ::1, fc00::/7).
  - Time out after about 3 s, require a 200 with JSON, and read at most 5 KB (16 KB allowed).
  - Validate the draft-02 URL shape.
  - Require `client_id` == URL, `redirect_uris` present, `client_name` present (or fall back to the host), and no `client_secret`.
  - Accept `token_endpoint_auth_method` absent, `none`, or `private_key_jwt` with `none` also listed, and always enforce `none` at `/token`.
  - Ignore unsupported grant_types (Claude lists jwt-bearer).
- **CIMD cache.** An `oauth_cimd_cache` table (url, json, fetched_at, expires_at, etag).
  - Use `Cache-Control` max-age clamped to 5 min-24 h; never cache failures; serve stale-if-error.
  - Seed repo copies of the claude.ai, Claude Code, and `chatgpt.com/oauth/client.json` documents.
  - Keep an admin "client trust" list with those three preapproved; other CIMD URLs get a stronger consent warning.
- **Redirect matching.** Exact string match. The only exception is an http `localhost`, `127.0.0.1`, or `[::1]` registration, where scheme, host, path, and query are compared and the port is ignored (RFC 8252 7.3). Expect:
  - `https://claude.ai/api/mcp/auth_callback`
  - `https://chatgpt.com/connector_platform_oauth_redirect`
  - a DCR ChatGPT client's `https://chatgpt.com/connector/oauth/{callback_id}`
  - Inspector `:6274` and `:6276`
- **Authorize validation.**
  - `response_type=code` only.
  - `code_challenge` is required, and `code_challenge_method` must be `S256` (plain or missing gets `invalid_request`). The challenge is 43 base64url characters.
  - `state` is echoed verbatim.
  - `scope` is a subset of {`archive:read`, `offline_access`}; empty means `archive:read`.
  - `resource` must canonicalize to `https://pebbleaudio.okgodoit.com/mcp`, otherwise `invalid_target`; if missing, default to it.
- **Consent.** Behind the app's own cookie login. Show the client_id host (not `client_name` alone), the redirect host, plain-language scopes, and a loopback-only warning. Keep antiforgery, and remember consent per (client_id, scope).
- **Codes.** A 302 with `code`, `state`, and `iss=https%3A%2F%2Fpebbleaudio.okgodoit.com`; errors use the same shape (`error=access_denied`). The code is 32 random bytes in base64url, hashed, single-use, with a 2-5 min TTL. It is bound to client_id, redirect_uri, code_challenge, scope, resource, and user. A second redemption revokes every token issued from it.

**Tokens**

- **Token endpoint.** Form-encoded only, `.DisableAntiforgery()`, no CORS, `Cache-Control: no-store`, and `Pragma: no-cache`.
  - Code grant: `redirect_uri` must equal the authorize one; `code_verifier` is 43-128 characters with `BASE64URL(SHA256(verifier)) == challenge`; an optional `resource` must match.
  - `client_secret` or Basic auth from a `none` client gets `invalid_client`.
  - Response: `{access_token, token_type:"Bearer", expires_in:3600, refresh_token (only with offline_access), scope}`.
  - Errors: 400 `invalid_request`, `invalid_grant`, `unsupported_grant_type`, `invalid_scope`, `invalid_target`; 401 `invalid_client`.
  - Stay under 1 s.
- **Refresh.**
  - Rotate every time: return a new token and mark the old one used.
  - Store opaque tokens as SHA-256 hashes, with a `family_id` per grant. Lifetime: 90-day sliding, with a 1-year cap.
  - Expired, revoked, or unknown tokens get 400 `invalid_grant`.
  - Reusing a rotated token within 60 s from the same client_id gets a fresh pair (this tolerates ChatGPT and Claude refresh races). After that, revoke the family.
  - Serialize per family with `SELECT … FOR UPDATE`.
- **Access tokens.** 32 random bytes, prefixed `pa_at_`, stored hashed with user_id, client_id, scope, audience, and expires_at (1 h). The `/mcp` middleware checks audience == the MCP URL, not expired or revoked, and the `archive:read` scope (missing scope gets a 403 `insufficient_scope`). No JWT or JWKS: lookup is a DB read.
- **DCR.**
  - Open registration, accepting `redirect_uris` (https or loopback http), `client_name`, `client_uri`, `logo_uri`, `grant_types`, `response_types`, `scope`, and `token_endpoint_auth_method` `none` only (anything else gets `invalid_client_metadata`). Ignore unknown fields.
  - Respond 201 with no secret. client_ids never start with `https://` (draft-02 7.1).
  - Rate-limit per IP and cap the client count. Delete clients with no token after 7 days, but keep any with a live grant.
- **Personal access tokens.** The admin can mint PATs (`pa_pat_`, audience = the MCP URL, no refresh) for Codex, Cursor, OpenCode, Gemini, and Claude Code.

**Schema, proxy, and testing**

- **Schema (EF migrations).**
  - `oauth_clients`, `oauth_cimd_cache`, `oauth_consents`, and `oauth_authorization_codes`.
  - `oauth_tokens` with columns kind (access, refresh, or pat), hash, family_id, parent_id, used_at, revoked_at, expires_at timestamptz, client_id, user_id, scope, and audience.
  - A nightly cleanup job on the queue.
- **nginx.** Build every OAuth URL from `PublicBaseUrl`, set `proxy_buffering off` on `/mcp`, and put no WAF or bot rules on `/.well-known/*`, `/oauth/*`, or `/mcp`.
- **Tests (one `WebApplicationFactory` host).**
  1. The full CIMD flow with a stubbed fetcher, through refresh rotation and family revocation after the grace window.
  2. DCR with a random-port loopback redirect.
  3. The exact 401 shape, plus a wrong-audience 401.
  4. `iss` on success and error redirects.
  5. The SSRF guard rejecting 127.0.0.1 and 10.x.
- **Rollout order.**
  1. Locally: `dotnet run` with `PublicBaseUrl=https://localhost:5001`, then the Inspector (web, and `--cli https://localhost:5001/mcp --transport http --method tools/list`).
  2. `curl -i` every well-known URL and an unauthenticated POST `/mcp`.
  3. Deploy, then from the droplet curl the three CIMD URLs (does Cloudflare challenge DO?).
  4. `claude mcp add --transport http pebble https://pebbleaudio.okgodoit.com/mcp`.
  5. claude.ai Add custom connector.
  6. ChatGPT Add custom MCP server with CIMD, then DCR. Expect Claude's 5-minute discovery cache.

### Risks

- **CIMD fetch failure.** A Cloudflare challenge to the DO IP would break Claude sign-in outright (no DCR fallback). Mitigate with seeded and last-good copies.
- **Refresh races.** 2026 ChatGPT reports describe refreshes before every call and re-auth loops. Strict reuse detection without a grace window logs users out.
- **Mid-session 401.** ChatGPT reportedly doesn't always re-run OAuth after one and shows an error until Reconnect. Use long refresh lifetimes and no silent revocation.
- **Exact-string traps.** A trailing slash, an http URL from a missing `X-Forwarded-Proto`, or an nginx 301 breaks ChatGPT and Claude with vague errors.
- **iss advertising.** Advertise `iss` support only if every response path really sends `iss`; otherwise ChatGPT switches to callback-ID redirects or rejects.
- **Antiforgery.** Without `.DisableAntiforgery()`, `/token` rejects form posts, and JSON-only endpoints answer 415.
- **Open DCR** is an abuse surface (rate-limit and GC it). It is deprecated but still needed for Inspector and older clients.
- **SSRF.** Without the CIMD `ConnectCallback` guard, the droplet can be made to fetch its internal services.
- **Plan gating.** Full MCP connectors are reported for Business, Enterprise, and Edu, with Pro read/fetch only in developer mode; mark tools `readOnlyHint: true`.
- **OIDC scopes.** Advertised OIDC scopes would make ChatGPT expect an id_token and UserInfo.

### Critic flags

- **One challenge owner.** Use our middleware (with `scope=` and `error=`) or the SDK's `AddMcp`; both hosts accept either, since both fall back to the PRM `scopes_supported`. Serve the PRM at both well-known URLs.
- **Audience.** Check it against `PublicBaseUrl + "/mcp"`, never the request host.
- **Antiforgery opt-out.** The cookie scheme is the default; Bearer and MCP are scoped to `/mcp`. Use `DisableAntiforgery()` on `/oauth/token` only (the critic's must-fix; the dotnet topic also listed `/oauth/register`, which is JSON).
- **User login (gap).** Nothing exists yet for the consent page's login: choose ASP.NET Core Identity (.NET 10 has passkey support) or a minimal hand-rolled passkey or password login.
- **CORS (gap).** Browser-based clients (Inspector web UI in direct mode) calling `/.well-known/*`, `/oauth/token`, and `/mcp` from a browser origin were not checked.
- **Other clients (gap).** Auth paths for Codex, Cursor, OpenCode, Gemini CLI, and Meta Muse (CIMD, DCR, or a static bearer) are unconfirmed.

### Unverified (verbatim)

- The ChatGPT help-center article (help.openai.com/en/articles/12584461) returned 403 to WebFetch. Its warning that ChatGPT may lose access when offline_access is not advertised, and the plan-availability details, come from search-result summaries only.
- Whether ChatGPT sends offline_access by itself when the AS lists it (Claude's docs say Claude does; OpenAI's auth page does not say).
- Whether the droplet's DigitalOcean IP is challenged by claude.ai's Cloudflare when fetching CIMD documents; test from the box with curl after deploy.
- The exact contents of ChatGPT's client.json beyond key names and short values (the copyright limits on verbatim quoting meant only a structured summary was taken). Re-fetch from the droplet when seeding the cache.
- Whether Codex, Cursor, OpenCode, Gemini CLI and Meta Muse support CIMD or only DCR or static bearer headers; not researched in this topic.
- Exact property names and behavior of ModelContextProtocol.AspNetCore 2.x authentication (only the v1 API page for McpAuthenticationOptions was read).
- Whether IFormCollection (as opposed to [FromForm] and IFormFile) triggers the automatic antiforgery check in .NET 10; apply .DisableAntiforgery() on /token regardless.
- No official conformance suite for authorization servers was found: modelcontextprotocol/conformance tests clients. Cloudflare's workers-oauth-provider has its own suite, not checked.

### Snippets

**Protected resource metadata: GET /.well-known/oauth-protected-resource/mcp (and same body at /.well-known/oauth-protected-resource)**

```json
{
  "resource": "https://pebbleaudio.okgodoit.com/mcp",
  "authorization_servers": ["https://pebbleaudio.okgodoit.com"],
  "scopes_supported": ["archive:read"],
  "bearer_methods_supported": ["header"],
  "resource_name": "Pebble Audio conversation archive"
}
```

**Authorization server metadata: GET /.well-known/oauth-authorization-server**

```json
{
  "issuer": "https://pebbleaudio.okgodoit.com",
  "authorization_endpoint": "https://pebbleaudio.okgodoit.com/oauth/authorize",
  "token_endpoint": "https://pebbleaudio.okgodoit.com/oauth/token",
  "registration_endpoint": "https://pebbleaudio.okgodoit.com/oauth/register",
  "revocation_endpoint": "https://pebbleaudio.okgodoit.com/oauth/revoke",
  "scopes_supported": ["archive:read", "offline_access"],
  "response_types_supported": ["code"],
  "response_modes_supported": ["query"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none"],
  "revocation_endpoint_auth_methods_supported": ["none"],
  "client_id_metadata_document_supported": true,
  "authorization_response_iss_parameter_supported": true
}
```

**401 from /mcp (no token / bad token)**

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://pebbleaudio.okgodoit.com/.well-known/oauth-protected-resource/mcp", scope="archive:read"
Content-Type: application/json

{"error":"invalid_token","error_description":"Sign in required"}

(when a token was presented but is expired/revoked/wrong audience, use:
WWW-Authenticate: Bearer error="invalid_token", error_description="Token expired", resource_metadata="https://pebbleaudio.okgodoit.com/.well-known/oauth-protected-resource/mcp", scope="archive:read")

403 step-up shape (if a second scope is ever added):
WWW-Authenticate: Bearer error="insufficient_scope", scope="archive:read archive:write", resource_metadata="https://pebbleaudio.okgodoit.com/.well-known/oauth-protected-resource/mcp"
```

**Authorization request (Claude hosted, CIMD) and response with iss**

```http
GET /oauth/authorize?response_type=code
  &client_id=https%3A%2F%2Fclaude.ai%2Foauth%2Fmcp-oauth-client-metadata
  &redirect_uri=https%3A%2F%2Fclaude.ai%2Fapi%2Fmcp%2Fauth_callback
  &code_challenge=<43 b64url chars>&code_challenge_method=S256
  &scope=archive%3Aread%20offline_access
  &resource=https%3A%2F%2Fpebbleaudio.okgodoit.com%2Fmcp
  &state=<opaque>

HTTP/1.1 302 Found
Location: https://claude.ai/api/mcp/auth_callback?code=<code>&state=<same>&iss=https%3A%2F%2Fpebbleaudio.okgodoit.com

Error variant (also carries iss):
Location: https://claude.ai/api/mcp/auth_callback?error=access_denied&state=<same>&iss=https%3A%2F%2Fpebbleaudio.okgodoit.com

Known client_ids / redirect URIs to expect:
- https://claude.ai/oauth/mcp-oauth-client-metadata -> https://claude.ai/api/mcp/auth_callback
- https://claude.ai/oauth/claude-code-client-metadata -> http://localhost:<any>/callback, http://127.0.0.1:<any>/callback
- https://chatgpt.com/oauth/client.json -> https://chatgpt.com/connector_platform_oauth_redirect
- (fallback if iss unsupported) https://chatgpt.com/oauth/{callback_id}/client.json -> https://chatgpt.com/connector/oauth/{callback_id}
```

**Token endpoint request/response**

```http
POST /oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code&code=<code>&redirect_uri=https%3A%2F%2Fclaude.ai%2Fapi%2Fmcp%2Fauth_callback&client_id=https%3A%2F%2Fclaude.ai%2Foauth%2Fmcp-oauth-client-metadata&code_verifier=<verifier>&resource=https%3A%2F%2Fpebbleaudio.okgodoit.com%2Fmcp

HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store
Pragma: no-cache

{"access_token":"pa_at_…","token_type":"Bearer","expires_in":3600,"refresh_token":"pa_rt_…","scope":"archive:read offline_access"}

Refresh:
grant_type=refresh_token&refresh_token=pa_rt_…&client_id=<same>&resource=https%3A%2F%2Fpebbleaudio.okgodoit.com%2Fmcp
-> 200 with NEW refresh_token (old one marked used); expired/revoked -> 400 {"error":"invalid_grant"}
```

**DCR request/response (RFC 7591)**

```http
POST /oauth/register
Content-Type: application/json

{"client_name":"MCP Inspector","redirect_uris":["http://127.0.0.1:6274/oauth/callback"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none","scope":"archive:read offline_access"}

HTTP/1.1 201 Created
Content-Type: application/json
Cache-Control: no-store

{"client_id":"dcr_7Hq…","client_id_issued_at":1792454400,"client_name":"MCP Inspector","redirect_uris":["http://127.0.0.1:6274/oauth/callback"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none","scope":"archive:read offline_access"}

Error: 400 {"error":"invalid_redirect_uri","error_description":"redirect_uris must be https or loopback http"}
```

**C# sketch: PKCE check, loopback-aware redirect match, resource canonicalization**

```csharp
static bool PkceOk(string verifier, string challenge) {
  if (verifier.Length is < 43 or > 128) return false;
  var hash = SHA256.HashData(Encoding.ASCII.GetBytes(verifier));
  return CryptographicOperations.FixedTimeEquals(
    Encoding.ASCII.GetBytes(Base64Url.EncodeToString(hash)), Encoding.ASCII.GetBytes(challenge));
}

static bool RedirectMatches(string registered, string requested) {
  if (registered == requested) return true;
  if (!Uri.TryCreate(registered, UriKind.Absolute, out var r) || !Uri.TryCreate(requested, UriKind.Absolute, out var q)) return false;
  bool loop = r.Scheme == "http" && (r.Host is "localhost" or "127.0.0.1" or "[::1]");
  return loop && q.Scheme == r.Scheme && q.Host == r.Host
      && q.AbsolutePath == r.AbsolutePath && q.Query == r.Query; // port ignored (RFC 8252 7.3)
}

static string? CanonicalResource(string? s) {
  if (s is null) return "https://pebbleaudio.okgodoit.com/mcp";
  if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || u.Fragment != "") return null;
  var c = $"{u.Scheme.ToLowerInvariant()}://{u.Host.ToLowerInvariant()}{(u.IsDefaultPort ? "" : ":" + u.Port)}{u.AbsolutePath.TrimEnd('/')}";
  return c == "https://pebbleaudio.okgodoit.com/mcp" ? c : null; // null -> invalid_target
}

// Minimal API: app.MapPost("/oauth/token", TokenHandler).DisableAntiforgery();
```

**CIMD fetcher guard (SocketsHttpHandler)**

```csharp
var handler = new SocketsHttpHandler {
  AllowAutoRedirect = false,
  ConnectTimeout = TimeSpan.FromSeconds(2),
  ConnectCallback = async (ctx, ct) => {
    var addrs = await Dns.GetHostAddressesAsync(ctx.DnsEndPoint.Host, ct);
    var ok = addrs.FirstOrDefault(IsGloballyRoutable) ?? throw new HttpRequestException("blocked address");
    var s = new Socket(ok.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
    await s.ConnectAsync(ok, ctx.DnsEndPoint.Port, ct);
    return new NetworkStream(s, ownsSocket: true);
  }
};
// IsGloballyRoutable rejects loopback, 10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16, 0/8, ::1, fc00::/7, fe80::/10, IPv4-mapped forms.
// Client timeout 3 s; read <= 16 KB (draft recommends 5 KB); require 200 + JSON; doc.client_id == url; redirect_uris non-empty; no client_secret.
// On failure: use last-good row from oauth_cimd_cache (or repo-seeded copy for the 3 known IDs); never cache the failure.
```

## 3. MCP Apps widgets

### Verified facts

**Spec and resources**

- **Spec.** MCP Apps is SEP-1865, extension id `io.modelcontextprotocol/ui`. Stable revision 2026-01-26 is `specification/2026-01-26/apps.mdx` in github.com/modelcontextprotocol/ext-apps; the draft is `specification/draft/apps.mdx`. Those are the only two directories. (https://github.com/modelcontextprotocol/ext-apps/tree/main/specification)
- **Draft-only features.** `ui/download-file`, view `sampling/createMessage`, `ui/notifications/request-teardown`, app-provided tools, and the "Metadata Location" rule (resources/read `_meta.ui` beats resources/list). (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/draft/apps.mdx)
- **Docs.** modelcontextprotocol.io/extensions/apps/overview (`/docs/extensions/apps` 308s there). API docs: apps.extensions.modelcontextprotocol.io and modelcontextprotocol.github.io/ext-apps/api. (https://modelcontextprotocol.io/extensions/apps/overview)
- **UI resources.** A `ui://` URI with mimeType `text/html;profile=mcp-app`, and a valid HTML5 document in `text` or base64 `blob`. They are predeclared, and servers MAY omit UI-only resources from resources/list. (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/draft/apps.mdx)
- **Tool link and visibility.** A tool links its UI via `_meta.ui.resourceUri`. `_meta.ui.visibility` defaults to `["model","app"]`, and `["app"]` hides the tool from the model but keeps it callable from the widget. The flat `_meta["ui/resourceUri"]` is deprecated and "will be removed before GA" (the SDK's `registerAppTool` still writes both). (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/draft/apps.mdx)

**The bridge protocol**

- **Handshake.** JSON-RPC 2.0 over `window.postMessage`.
  1. The view sends `ui/initialize` `{appInfo, appCapabilities, protocolVersion}` (SDK 2.0.3 sends `"2026-01-26"`).
  2. The host replies `{protocolVersion, hostCapabilities, hostInfo, hostContext}`.
  3. The view sends `ui/notifications/initialized`. The host MUST NOT send anything to the view before that.

  (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/draft/apps.mdx)
- **Host → view notifications.** `ui/notifications/tool-input` (full arguments, once, before the result), `tool-input-partial` (optional), `tool-result` (the full CallToolResult: `content`, `structuredContent`, `_meta`), `tool-cancelled`, and `host-context-changed` (a partial context to merge). A `ui/resource-teardown` request comes before unmount, and the host SHOULD wait for the reply. (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/draft/apps.mdx)
- **View → host requests.**
  - `tools/call` (needs `hostCapabilities.serverTools`) and `resources/read`
  - `ui/open-link {url}` and `ui/message {role, content}`
  - `ui/request-display-mode {mode}` (returns the mode actually set)
  - `ui/update-model-context {content?, structuredContent?}` (overwrites)
  - `notifications/message` and `ping`
  - the notification `ui/notifications/size-changed {width, height}`

  (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/draft/apps.mdx)
- **Sizing.** `hostContext.containerDimensions` is either fixed height/width or maxHeight/maxWidth. With flexible dimensions, the host MUST resize on `size-changed`. The SDK's autoResize measures `documentElement` at `height:max-content` with a ResizeObserver. (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/draft/apps.mdx)
- **Display modes.** `inline`, `fullscreen`, and `pip`. The view MUST declare `appCapabilities.availableDisplayModes`, check `hostContext.availableDisplayModes` before requesting, and accept a different mode back. ChatGPT also reads `_meta["openai/ui"].availableDisplayModes` on resource contents. (https://developers.openai.com/apps-sdk/reference)

**CSP and the SDK**

- **CSP.** `_meta.ui.csp` maps `connectDomains` → connect-src, `resourceDomains` → script/style/img/font/media-src, `frameDomains` → frame-src, and `baseUriDomains` → base-uri. With no CSP declared, the host MUST use `default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none'`. Hosts may tighten it but MUST NOT allow undeclared domains. So audio from our server needs our origin in `resourceDomains`, and `connectDomains` is only for the widget's own `fetch()`. (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/draft/apps.mdx)
- **blob: media.** The default media-src has no `blob:`. The reference basic-host adds `blob:`, and its video example plays a `blob:` URL from a resources/read blob. (https://github.com/modelcontextprotocol/ext-apps/blob/main/examples/basic-host/serve.ts)
- **No SDK needed.** "you don't need an SDK to talk MCP with the host". OpenAI's decoupled example uses a raw `window.parent.postMessage` bridge that checks `event.source === window.parent`. (https://developers.openai.com/apps-sdk/mcp-apps-in-chatgpt)
- **The npm package.** `@modelcontextprotocol/ext-apps` 2.0.3 (2026-09-25, MIT) ships `dist/src/app-with-deps.js`, a self-contained ESM bundle (`App`, `PostMessageTransport`, zod included, no bare imports) of about 418 KB minified, about 98 KB gzipped. It is served at `unpkg.com/@modelcontextprotocol/ext-apps@2.0.3/dist/src/app-with-deps.js` and the same jsDelivr path. The wire protocol is unchanged from 1.x. (https://registry.npmjs.org/@modelcontextprotocol/ext-apps)
- **Claude's quickstart** loads `App` from unpkg (1.7.5) with `resourceDomains ['https://unpkg.com']`, but says: "For production, serve the client script from your own origin, or bundle it into the HTML, and list only that origin in resourceDomains." `'self'` is the sandbox origin. (https://claude.com/docs/connectors/building/mcp-apps/quickstart)
- **No OpenAI detection.** SDK 2.0.3's `App.connect()` defaults to `PostMessageTransport(window.parent, window.parent)` with no `window.openai` detection (the migration doc's "auto-detects OpenAI env" looks stale); ChatGPT speaks the standard bridge. (https://github.com/modelcontextprotocol/ext-apps/blob/main/docs/migrate_from_openai_apps.md)

**ChatGPT**

- **Output template.** `_meta["openai/outputTemplate"]` is a compatibility alias for `_meta.ui.resourceUri`, for render tools only. Build on the standard keys, and use `window.openai` only for extras. (https://developers.openai.com/apps-sdk/mcp-apps-in-chatgpt)
- **`window.openai` extras** (feature-detect each one):
  - Data: `toolInput`, `toolOutput`, `toolResponseMetadata`, `widgetState`/`setWidgetState`.
  - Actions: `callTool`, `sendFollowUpMessage`, `uploadFile`, `selectFiles`, `getFileDownloadUrl`, `openExternal({href, redirectUrl})`, `setOpenInAppUrl`.
  - Display: `requestDisplayMode`, `requestModal`, `requestClose`, `notifyIntrinsicHeight`.
  - Context: theme, displayMode, maxHeight, safeArea, and locale.

  (https://developers.openai.com/apps-sdk/reference)
- **Visibility and domains.** Result `structuredContent` and `content` go to the model and the component and into the transcript; `_meta` goes only to the component, which is where signed URLs belong. `_meta.ui.domain` is an origin, "required when submitting a plugin with UI; must be unique per plugin" (default `https://web-sandbox.oaiusercontent.com`; alias `openai/widgetDomain`). `_meta["openai/widgetCSP"].redirect_domains` is still needed for `openExternal` targets. The `_meta` keys are listed in section 10. (https://developers.openai.com/apps-sdk/reference)
- **Caching.** "Treat the resource URI as a cache key": a breaking HTML/JS/CSS change needs a new URI (for example `ui://project-board/v1.html`) and updated tools. (https://developers.openai.com/apps-sdk/mcp-apps-in-chatgpt)

**Claude**

- **`ui.domain`.** Must be exactly `{first 32 hex of SHA-256(full connector URL)}.claudemcpcontent.com`, hashing scheme, path, and trailing slash. A mismatch shows `Invalid ui.domain format` or `ui.domain mismatch`. For `https://pebbleaudio.okgodoit.com/mcp` it is `9ddf9da6bce2a3bb2f4ae0f3b55e8899.claudemcpcontent.com` (computed locally; the docs' example reproduced). (https://claude.com/docs/connectors/building/mcp-apps/troubleshooting)
- **iOS Referer.** iOS WebKit (Safari and the Claude app) omits Referer on cross-origin subresources, so allowlist on Origin (`*.claudemcpcontent.com`) with a matching `Access-Control-Allow-Origin`. Tool calls go through Anthropic's backend IPs, not the device. (https://claude.com/docs/connectors/building/mcp-apps/troubleshooting)
- **External links.** Every `ui/open-link` shows an "Open external link" modal, always for custom connectors. Only Directory connectors can skip it, via "Allowed link URIs", after a real user gesture, and a resolved request doesn't prove a tab opened. (https://claude.com/docs/connectors/building/mcp-apps/external-links)
- **Mobile and touch.** Mobile uses WKWebView or Android WebView with no camera, mic, or location, and connectors must be added on web or desktop first. On touch, the conversation owns vertical scroll and inline height is capped and clipped. Tap targets ≥44pt, respect `safeAreaInsets`. Unset `prefersBorder` means borderless on web and bordered on mobile. `frameDomains` is restricted pending review. (https://claude.com/docs/connectors/building/mcp-apps/design-guidelines)
- **Size limit.** A result over about 150,000 characters with the code sandbox active is written to the sandbox, the widget gets a pointer, and it never hydrates. Claude Code's limit is 25,000 tokens (`MAX_MCP_OUTPUT_TOKENS`). (https://claude.com/docs/connectors/building/mcp-apps/troubleshooting)
- **Theming.** `hostContext.styles.variables` (`--color-*`, `--font-*`, `--border-radius-*`, `--border-width-*`) and `styles.css.fonts` (Anthropic Sans from `https://assets.claude.ai`, which must be in `resourceDomains`). Recommended: transparent html/body, `<meta name="color-scheme" content="light dark">`, and `prefersBorder:false`. (https://claude.com/docs/connectors/building/mcp-apps/transparent-theming)
- **Instances.** A new iframe per tool call, and old ones are never unmounted. One connector's widgets share a `*.claudemcpcontent.com` origin (allow-same-origin), so a BroadcastChannel reaches all of them. On iOS, `toolInfo.id` is undefined on rehydrate. (https://claude.com/docs/connectors/building/mcp-apps/instance-supersession)
- **Availability.** Interactive connectors launched 2026-01-26 on web, Cowork, Desktop, iOS, and Android. (https://support.claude.com/en/articles/13454812-use-interactive-connectors-in-claude)
- **UNVERIFIED:** Claude does not support resource subscriptions, sampling, or "advanced or draft capabilities". This came from a search summary here; section 10 read the page directly. (https://claude.com/docs/connectors/building)

**Core spec**

- **Caching (2026-07-28).** Complete results (resources/read, tools/list, resources/list, and others) MUST carry `ttlMs` (integer ≥0; absent = 0) and `cacheScope` (`'public'`/`'private'`). `'private'` caches MUST NOT be shared across authorization contexts. Hosts may prefetch and cache UI resources. (https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching)

### Recommendations

- **Bridge.** Use the inline plain-JS bridge (the skeleton below, about 80 lines), not the 418 KB SDK. If the SDK is wanted, vendor `app-with-deps.js` 2.0.3 into wwwroot, served from our origin; never unpkg in production. Do the full handshake (`"2026-01-26"`, `availableDisplayModes`), answer `ping` and `ui/resource-teardown` with `{}`, render from `tool-result`, and fall back to `window.openai.toolOutput` only if it is already set.
- **URIs.** One HTML and one versioned `ui://` URI per widget for both hosts: `ui://pebble/conversation-card.v1.html`, `day-timeline.v1.html`, and `clip-player.v1.html`. Widget resources/read gets `ttlMs` 3600000 `public`; tools/call and data reads get `private`.
- **Tool split.**
  - Render tools (`show_conversation`, `show_day`, `play_clip`) get `_meta.ui.resourceUri`, the mirrored `openai/outputTemplate`, and invoking/invoked strings; skip the flat `ui/resourceUri`.
  - Data tools (`search`, `get_transcript`) get no template.
  - Widget-only helpers (`get_clip_url`, `load_more`) get `visibility ["app"]` plus `openai/widgetAccessible:true`.
- **Audio.**
  - The play button calls `get_clip_url {clipId}`, which mints a roughly 10-minute HMAC URL `https://pebbleaudio.okgodoit.com/clips/{id}.m4a?exp=..&sig=..` in result `_meta`. Never store one in a render result.
  - `resourceDomains ["https://pebbleaudio.okgodoit.com"]` (optionally `https://assets.claude.ai`), and leave `connectDomains` empty.
  - The clip endpoint authorizes by signature only (never Referer or Origin), supports Range/206, and sends `audio/mp4`.
- **`ui.domain`.** Leave it unset (no in-widget CORS or OAuth is needed). If ever needed, use Claude's hash value and test whether ChatGPT honours `openai/widgetDomain` over `ui.domain`.
- **Layout.** Lean results (a summary, the first page, and ids; pagination via app-only calls). Inline cards fit their content, while the timeline and long transcripts go fullscreen after checking modes. ≥44px targets, safe-area padding, transparent background, `color-scheme light dark`, and host CSS variables with token fallbacks.
- **Links and supersession.** "Open in archive" uses `ui/open-link` (expect Claude's modal), falling back to `openExternal`. Stamp results `{seq, createdAt}` and use a BroadcastChannel so old players stop.
- **Where to test.** ext-apps basic-host, Claude Desktop Developer Mode, Safari Web Inspector against the iPhone Claude app, and ChatGPT developer mode.

### Risks

- `blob:` media-src in production hosts is undocumented, so prefer direct https on a declared domain.
- The two hosts' `ui.domain` formats conflict, and a wrong value blocks Claude.
- Signed URLs in persisted results expire and are visible to the model.
- The draft keeps moving; code only to the stable methods.
- The flat `ui/resourceUri` will be removed before GA.
- The ~150 KB limit silently blanks the widget.
- Tall inline widgets get clipped on mobile.
- The external-link modal can't be suppressed.
- A hand-written bridge must track spec changes.
- Old Claude instances keep playing without supersession.

### Critic flags

- **Clip serving.** This topic uses nginx X-Accel-Redirect to internal `/var/lib/pebbleaudio/clips`; section 9 uses Kestrel `PhysicalFile(enableRangeProcessing: true)`. The nginx route needs www-data access into StateDirectory, so prefer Kestrel.
- **URL placement.** The `get_clip_url` sample also copies the signed URL into `structuredContent`, contradicting the `_meta`-only advice.
- **Stateless rendering (gap).** Rendering against a stateless 2026-07-28 server is unchecked.
- **Helper annotations (gap).** App-only helpers need `readOnlyHint:true`, or ChatGPT may prompt on widget-initiated calls.

### Unverified (verbatim)

- Which bridge methods ChatGPT supports beyond those it documents (ui/initialize, tool-input, tool-result, tools/call, ui/message, ui/update-model-context). OpenAI's MCP Apps pages do not mention ui/open-link, ui/notifications/size-changed, or ui/request-display-mode, so the skeleton falls back to window.openai.openExternal, notifyIntrinsicHeight, and requestDisplayMode.
- Whether Claude forwards the tool result `_meta` to the widget in ui/notifications/tool-result. The spec says params is the full CallToolResult, but I found no Claude-specific statement. The skeleton also reads structuredContent as a fallback.
- The exact CSP ChatGPT and Claude apply in production, in particular whether media-src includes blob:, and whether `resourceDomains` reliably maps to media-src in both. The spec says it does.
- Whether audio from a resourceDomains origin plays inside the Claude iOS/Android WebViews and the ChatGPT mobile apps without extra permissions. Nothing documented forbids it, but I tested no device.
- Any byte-size limit on the ui:// HTML resource in either host. None is documented.
- Whether ChatGPT prefers openai/widgetDomain over ui.domain when both are present.
- Whether ChatGPT honours ttlMs/cacheScope (MCP 2026-07-28) or only caches by resource URI. Its docs only say to treat the URI as a cache key.
- Whether either host's MCP Apps support already works against a server that speaks only the stateless 2026-07-28 core protocol. That belongs to the transport topic and I did not check it here.
- The Claude statement that resource subscriptions, sampling, and draft capabilities are unsupported comes from a search-result summary of claude.com/docs/connectors/building, not a direct read.

### Snippets

**Tool descriptor (tools/list entry) for a render tool plus an app-only helper**

```json
{
  "name": "play_clip",
  "title": "Play clip",
  "description": "Show a playable clip of a recorded conversation.",
  "inputSchema": {"type":"object","properties":{"clipId":{"type":"string"}},"required":["clipId"]},
  "annotations": {"readOnlyHint": true},
  "_meta": {
    "ui": { "resourceUri": "ui://pebble/clip-player.v1.html" },
    "openai/outputTemplate": "ui://pebble/clip-player.v1.html",
    "openai/toolInvocation/invoking": "Finding the clip…",
    "openai/toolInvocation/invoked": "Clip ready"
  }
}

{
  "name": "get_clip_url",
  "description": "Widget-only: mint a short-lived playback URL.",
  "inputSchema": {"type":"object","properties":{"clipId":{"type":"string"}},"required":["clipId"]},
  "_meta": { "ui": { "resourceUri": "ui://pebble/clip-player.v1.html", "visibility": ["app"] },
             "openai/widgetAccessible": true, "openai/visibility": "private" }
}
```

**resources/read result for the widget (same HTML for both hosts)**

```jsonc
{
  "contents": [{
    "uri": "ui://pebble/clip-player.v1.html",
    "mimeType": "text/html;profile=mcp-app",
    "text": "<!DOCTYPE html>…",
    "_meta": {
      "ui": {
        "prefersBorder": false,
        "csp": {
          "connectDomains": [],
          "resourceDomains": ["https://pebbleaudio.okgodoit.com", "https://assets.claude.ai"]
        }
      },
      "openai/ui": { "availableDisplayModes": ["inline", "fullscreen"] }
    }
  }],
  "ttlMs": 3600000,
  "cacheScope": "public"
}
// resourceDomains -> script/style/img/font/media-src, so the <audio> URL on our origin is allowed.
// Do NOT set ui.domain unless needed; for Claude it would be 9ddf9da6bce2a3bb2f4ae0f3b55e8899.claudemcpcontent.com
```

**Tool results: render result (lean, no URL) and app-only URL result**

```jsonc
// play_clip result (stored in transcript; ChatGPT shows structuredContent to the model)
{ "content": [{"type":"text","text":"Clip from Tue 14 Oct, 2:14–2:16 pm: “…we should ship Friday…”"}],
  "structuredContent": { "clipId": "c_8f2", "title": "Planning call", "startedAt": "2026-10-14T14:14:05-07:00", "durationSec": 96,
                         "excerpt": "…we should ship Friday…", "seq": 18233, "createdAt": 1760998445000 },
  "_meta": { "viewerUrl": "https://pebbleaudio.okgodoit.com/c/c_8f2" } }

// get_clip_url result (app-only; minted at tap time, ~10 min expiry)
{ "content": [{"type":"text","text":"ok"}],
  "structuredContent": { "url": "https://pebbleaudio.okgodoit.com/clips/c_8f2.m4a?exp=1761000000&sig=…" },
  "_meta": { "url": "https://pebbleaudio.okgodoit.com/clips/c_8f2.m4a?exp=1761000000&sig=…" } }
```

**Minimal widget HTML that works in ChatGPT and Claude (no SDK, no bundler)**

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Clip</title>
<style>
  html, body { margin: 0; background: transparent; }
  body { font: 15px/1.4 var(--font-sans, system-ui, sans-serif);
         color: var(--color-text-primary, CanvasText); }
  .card { padding: 12px; display: grid; gap: 8px; }
  .meta { color: var(--color-text-secondary, GrayText); font-size: 13px; }
  button { min-height: 44px; min-width: 44px; padding: 0 14px; font: inherit; cursor: pointer;
           border-radius: var(--border-radius-md, 8px);
           border: 1px solid var(--color-border-primary, currentColor);
           background: var(--color-background-secondary, transparent); color: inherit; }
  .row { display: flex; gap: 8px; flex-wrap: wrap; }
  audio { width: 100%; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<div class="card" id="root">
  <div id="title">Loading…</div>
  <div class="meta" id="when"></div>
  <div id="excerpt"></div>
  <audio id="player" controls preload="none" hidden></audio>
  <div class="row">
    <button id="play" disabled>Play</button>
    <button id="open" disabled>Open in archive</button>
  </div>
</div>
<script type="module">
// ---- MCP Apps bridge: JSON-RPC 2.0 over postMessage (spec 2026-01-26) ----
const PROTOCOL = "2026-01-26";
const pending = new Map(); let nextId = 1;
const handlers = {};                       // notification method -> fn(params)
let host = { caps: {}, ctx: {} };
const post = (msg) => window.parent.postMessage({ jsonrpc: "2.0", ...msg }, "*");
const request = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextId++; pending.set(id, { resolve, reject }); post({ id, method, params });
});
const notify = (method, params = {}) => post({ method, params });

window.addEventListener("message", (e) => {
  if (e.source !== window.parent) return;   // only trust the host frame
  const m = e.data; if (!m || m.jsonrpc !== "2.0") return;
  if (m.id !== undefined && !m.method) {    // response to one of our requests
    const p = pending.get(m.id); if (!p) return; pending.delete(m.id);
    m.error ? p.reject(m.error) : p.resolve(m.result); return;
  }
  if (m.id !== undefined && m.method) {     // host -> view request: must answer
    if (m.method === "ui/resource-teardown") { document.getElementById("player").pause(); }
    post({ id: m.id, result: {} });          // ping, ui/resource-teardown
    return;
  }
  handlers[m.method]?.(m.params ?? {});      // notification
});

// ---- size reporting (host resizes iframe when dimensions are flexible) ----
function reportSize() {
  const el = document.documentElement, prev = el.style.height;
  el.style.height = "max-content";
  const height = Math.ceil(el.getBoundingClientRect().height); el.style.height = prev;
  const width = Math.ceil(window.innerWidth);
  notify("ui/notifications/size-changed", { width, height });
  window.openai?.notifyIntrinsicHeight?.(height);   // ChatGPT extra, feature-detected
}

// ---- host context (theme, CSS variables, safe area, display modes) ----
function applyContext(ctx) {
  host.ctx = { ...host.ctx, ...ctx };
  const vars = host.ctx.styles?.variables ?? {};
  for (const [k, v] of Object.entries(vars)) if (v) document.documentElement.style.setProperty(k, v);
  if (host.ctx.theme) { document.documentElement.dataset.theme = host.ctx.theme;
                        document.documentElement.style.colorScheme = host.ctx.theme; }
  const s = host.ctx.safeAreaInsets;
  if (s) Object.assign(document.body.style, { paddingTop: s.top + "px", paddingRight: s.right + "px",
                                              paddingBottom: s.bottom + "px", paddingLeft: s.left + "px" });
}

// ---- app ----
const $ = (id) => document.getElementById(id);
let data = null, meta = {};
function render(result) {
  data = result?.structuredContent ?? data; meta = result?._meta ?? meta;
  if (!data) { $("title").textContent = result?.content?.[0]?.text ?? "No clip"; return; }
  $("title").textContent = data.title;
  $("when").textContent = new Date(data.startedAt).toLocaleString(host.ctx.locale, { dateStyle: "medium", timeStyle: "short" });
  $("excerpt").textContent = data.excerpt ?? "";
  $("play").disabled = false; $("open").disabled = !meta.viewerUrl;
  reportSize();
}
async function callTool(name, args) {
  try { return await request("tools/call", { name, arguments: args }); }
  catch (err) { if (window.openai?.callTool) return window.openai.callTool(name, args); throw err; }
}
$("play").onclick = async () => {
  $("play").disabled = true;
  try {
    const r = await callTool("get_clip_url", { clipId: data.clipId });
    const url = r?._meta?.url ?? r?.structuredContent?.url;
    const a = $("player"); a.src = url; a.hidden = false; reportSize(); await a.play();
  } catch { $("excerpt").textContent = "Couldn’t load this clip."; }
  finally { $("play").disabled = false; }
};
$("open").onclick = async () => {
  try { await request("ui/open-link", { url: meta.viewerUrl }); }
  catch { window.openai?.openExternal?.({ href: meta.viewerUrl }); }
};
async function goFullscreen() {   // e.g. for the day timeline
  if (!(host.ctx.availableDisplayModes ?? []).includes("fullscreen")) return;
  try { await request("ui/request-display-mode", { mode: "fullscreen" }); }
  catch { await window.openai?.requestDisplayMode?.({ mode: "fullscreen" }); }
}

handlers["ui/notifications/tool-input"] = () => {};
handlers["ui/notifications/tool-result"] = render;
handlers["ui/notifications/tool-cancelled"] = () => { $("title").textContent = "Cancelled"; reportSize(); };
handlers["ui/notifications/host-context-changed"] = (ctx) => { applyContext(ctx); reportSize(); };

// Handshake: register handlers first, then initialize.
try {
  const init = await request("ui/initialize", {
    protocolVersion: PROTOCOL,
    appInfo: { name: "Pebble clip player", version: "1.0.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }
  });
  host.caps = init?.hostCapabilities ?? {}; applyContext(init?.hostContext ?? {});
  if (init?.hostContext?.styles?.css?.fonts) {
    const st = document.createElement("style"); st.textContent = init.hostContext.styles.css.fonts; document.head.append(st);
  }
  notify("ui/notifications/initialized");
} catch { /* host without MCP Apps bridge; fall through to window.openai */ }

// ChatGPT may pre-populate globals before/instead of the notification.
if (window.openai?.toolOutput) render({ structuredContent: window.openai.toolOutput,
                                        _meta: window.openai.toolResponseMetadata ?? {} });
new ResizeObserver(reportSize).observe(document.body);
reportSize();
</script>
</body>
</html>
```

**Optional: load the official SDK without a bundler (vendored, served from our origin)**

```html
<!-- copy node_modules/@modelcontextprotocol/ext-apps/dist/src/app-with-deps.js (v2.0.3, MIT) to wwwroot/vendor/ext-apps-2.0.3.js
     and add "https://pebbleaudio.okgodoit.com" to _meta.ui.csp.resourceDomains -->
<script type="module">
  import { App } from "https://pebbleaudio.okgodoit.com/vendor/ext-apps-2.0.3.js";
  const app = new App({ name: "Pebble clip player", version: "1.0.0" }, { availableDisplayModes: ["inline","fullscreen"] });
  app.ontoolresult = (r) => render(r);          // set handlers BEFORE connect()
  app.onhostcontextchanged = (ctx) => applyContext(ctx);
  await app.connect();                           // ui/initialize + initialized + autoResize
  // app.callServerTool({ name, arguments }), app.openLink({ url }), app.requestDisplayMode({ mode })
</script>
```

**nginx location for signed clip audio (Range-friendly, no Referer/Origin gating)**

```nginx
location /clips/ {
  proxy_pass http://127.0.0.1:5080;     # ASP.NET verifies exp+sig, then returns X-Accel-Redirect
  proxy_set_header Range $http_range;   # forward byte ranges; Safari/WKWebView require 206 support
  proxy_set_header If-Range $http_if_range;
}
location /_protected_clips/ {
  internal;
  alias /var/lib/pebbleaudio/clips/;    # m4a files
  types { audio/mp4 m4a; }
  add_header Cache-Control "private, max-age=600";
}
```

## 4. MCP Events

ChatGPT's MCP Events and the MCP Triggers & Events draft, SEP-3415.

### Verified facts

**Availability and capability**

- **Where it works.** Only in Work chats on ChatGPT web, in Work chats in the desktop app with Cloud selected, and in dots. Workspace controls for plugins and event-triggered tasks apply. (https://developers.openai.com/plugins/build/mcp-events.md)
- **Requirements.** MCP 2.0, protocol 2026-07-28, persistent subscription storage, and outbound HTTPS to callbacks. Webhook delivery and callback verification only: no polling, no streaming push, and no gap or terminated control notifications. (https://developers.openai.com/plugins/build/mcp-events.md)
- **OpenAI's capability shape.** `server/discover` carries `capabilities.events = {}`, for example `{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"events":{}}}`. (https://developers.openai.com/plugins/build/mcp-events.md)
- **SEP-3415's shape.** The SEP (opened 2026-10-05, open) moves it to `capabilities.extensions["io.modelcontextprotocol/events"]` with optional `listChanged`, noting that a top-level `events` is what "at least one deployed client reads". Advertise both. (https://github.com/modelcontextprotocol/modelcontextprotocol/pull/3415)

**Methods**

- **events/list.** `events/list`, `events/subscribe`, and `events/unsubscribe` are on the same authenticated endpoint. `events/list` returns `events[]` with `name`, `description`, `delivery` (for example `["webhook"]`), `inputSchema` (the subscription arguments), and `payloadSchema` (the `data` shape), paginated by `nextCursor` → `cursor`. Return only events the account may discover. (https://developers.openai.com/plugins/build/mcp-events.md)
- **Subscribe params.** `{name, arguments, cursor (null), ttlMs?, delivery:{mode:'webhook', url:'https://...', secret:'whsec_<base64>'}}`. ChatGPT supplies the URL and secret, and the secret must decode to 24-64 bytes or the call gets -32602 InvalidParams. (https://developers.openai.com/plugins/build/mcp-events.md)
- **Subscribe result.** `{id, refreshBefore, cursor, truncated}` (plus `resultType:'complete'` under the SEP). `id` is deterministic over (principal, callback URL, event name, arguments). Subscribe is an idempotent upsert, with arguments compared as canonical JSON. (https://developers.openai.com/plugins/build/mcp-events.md)
- **Unsubscribe.** Params `{name, arguments, delivery:{mode:'webhook', url}}`; the subscription id is NOT accepted. The result is `{}`, idempotent, and authorized against the account. (https://developers.openai.com/plugins/build/mcp-events.md)

**Verification, errors, and SSRF**

- **Verification.** It runs from OUR server before any data is sent.
  - We POST a signed `{"type":"verification","challenge":"<single-use nonce>"}` with its own `webhook-id` (for example `msg_verification_123`), `webhook-timestamp`, `webhook-signature`, and `X-MCP-Subscription-Id`.
  - ChatGPT answers 2xx `{"challenge":"<same>"}`, compared in constant time.
  - Cache success per (principal, URL), bounded.

  (https://developers.openai.com/plugins/build/mcp-events.md)
- **Error codes.** Failure is -32015 CallbackEndpointError with `data.reason` (`challenge_failed`, `timeout`) per OpenAI. The draft renumbered it to -32027 on 2026-10-08 (provisional). The others: -32023 NotFound, -32024 Forbidden, -32025 ResourceExhausted, -32026 Unsupported. (https://github.com/modelcontextprotocol/experimental-ext-triggers-events/blob/main/docs/design-sketch-proposal.md)
- **SSRF.** HTTPS only. Resolve and validate at connect time, connect to the validated IP while keeping SNI, block non-public ranges, and never follow redirects, for both verification and delivery. (https://developers.openai.com/plugins/build/mcp-events.md)

**Delivery**

- **Shape.** One object per POST: `{eventId, name, timestamp (ISO 8601 with zone), data (per payloadSchema), cursor}`. A top-level `type` marks a control envelope. Headers: `Content-Type: application/json`, `webhook-id` (= eventId), `webhook-timestamp` (Unix seconds), `webhook-signature` (Standard Webhooks v1), and `X-MCP-Subscription-Id`. (https://developers.openai.com/plugins/build/mcp-events.md)
- **Limits and acks.** At most 256 KiB (262,144 bytes) per body, so send a summary and let a read tool fetch the rest. Only 2xx acks. ChatGPT processes asynchronously and may batch events into one task run. (https://developers.openai.com/plugins/build/mcp-events.md)
- **Retries.** Bounded exponential backoff with the same event ID but a fresh timestamp and signature each attempt; never retry 410 or 413. The draft suggests 3-5 attempts within 10-15 min, with 410 non-retryable for that delivery only. (https://github.com/modelcontextprotocol/experimental-ext-triggers-events/blob/main/docs/design-sketch-proposal.md)
- **Ordering.** Best-effort: out of order or duplicated. Receivers dedupe on `eventId`, and write tools must be idempotent. (https://github.com/modelcontextprotocol/experimental-ext-triggers-events/blob/main/docs/design-sketch-proposal.md)
- **Signature.** `base64(HMAC-SHA256(key, webhook-id + '.' + webhook-timestamp + '.' + rawBody))`, sent as `v1,<base64>`, with `key` = the bytes after `whsec_`. Several space-separated signatures are allowed during rotation. Reject timestamps more than 5 min old. (https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
- **Lifecycle.**
  - ChatGPT refreshes by re-subscribing before `refreshBefore`, with the same identity and the last cursor.
  - An omitted `ttlMs` means the server default; `ttlMs: null` means no expiry (and only then may `refreshBefore` be null).
  - A refresh may rotate the secret, so dual-sign briefly.
  - Persist state across restarts, recheck access, and stop on revocation.

  (https://developers.openai.com/plugins/build/mcp-events.md)

**User flow and plans**

- **User flow.** In a Work chat or dot, the user asks ChatGPT to monitor an event and what to do. Events show on the plugin page next to tools and need a Refresh after changes. (https://developers.openai.com/plugins/build/mcp-events.md)
- **Personal plugin.** chatgpt.com/plugins → + → Add custom MCP server → `/mcp` URL → auth → accept the warning → Create as a plugin, then install it from the personal plugins view. (https://developers.openai.com/plugins/quickstart.md)
- **Non-Work chats** may fall back to scheduled polling (for example every 5 min), per a third-party vendor doc. (https://agentmail.to/docs/integrations/mcp-events)
- **Dots** need Pro 100/200/500 (18+, outside the EEA, UK, and Switzerland), Business Premium, or Enterprise, and don't work on mobile web. (https://learn.chatgpt.com/docs/dots)
- **server/discover.** 2026-07-28 defines `server/discover`, with `supportedVersions` and `resultType`. (https://modelcontextprotocol.io/specification/2026-07-28/basic/lifecycle)

### Recommendations

- **Capabilities.** Advertise both `capabilities.events = {}` and `extensions['io.modelcontextprotocol/events'] = {}`, with `resultType:'complete'` on every `events/*` result.
- **Error codes as config.** Callback failure defaults to -32015 (switch to -32027 when SEP-3415 lands). Bad arguments, a non-https URL, or a bad secret get -32602; no principal gets -32024.
- **Outbound delivery.** No inbound nginx route. Delivery is a Postgres queue job (one row per event per subscription) on a `BackgroundService`.
- **Signing.** Hand-roll it with `HMACSHA256` (about 10 lines; serialize once, then sign and send the same bytes). NuGet `StandardWebhooks` 1.1.2 (codefactors) is an alternative.
- **Webhook HttpClient.** A named `"webhook"` client: `AllowAutoRedirect=false`, and a `ConnectCallback` rejecting loopback, RFC 1918, 169.254/16, 100.64/10, ::1, fc00::/7, fe80::/10, and IPv4-mapped forms. 10 s timeout.
- **Tables.**
  - Subscriptions: id = truncated SHA-256 of canonical principal|url|name|arguments; principal, name, arguments jsonb, callback_url, secret, previous_secret plus rotation_until, refresh_before timestamptz, verified_at, active, and last_error.
  - A verification cache keyed by (principal, url).
- **TTL and retries.** A finite default TTL (an admin setting, 24 h-7 d), with `ttlMs:null` allowed since we persist. Return `cursor:null` and `truncated:false` in v1. Retries are admin-tunable: about 5 attempts with jitter within about 15 min, retrying network errors, 408, 425, 429, and 5xx, and stopping on 410 and 413. eventId is `evt_<conversationId>_<revision>`.
- **Payloads.** Metadata, a short summary, and a viewer URL, never transcripts; the payload is untrusted text.
- **Events.** `conversation.created` and `conversation.updated` (maybe a daily digest), filtered server-side via `inputSchema` (keyword, participant, minDurationSeconds). Emit only on sync-originated changes, never on ChatGPT write-backs (feedback loop). Suppress or coalesce during imports and cap concurrency.
- **End-to-end test.** In a Work chat with the personal plugin: refresh, subscribe params, verification echo, 2xx delivery, filters, unsubscribe, restart and refresh, and a bad signature.

### Risks

- The spec is moving: codes went from -32011..-32015 to -32023..-32027, and the key moved to `extensions`, while ChatGPT documents the old forms.
- Plan gating (Work chats or dots; Pro or Business Premium/Enterprise for dots; Plus+ reportedly for event tasks) may make it untestable.
- ChatGPT needs OAuth (no static headers), so the AS must work first.
- The callback URL is client-supplied, so without guards it is SSRF to internal services or `169.254.169.254`.
- Duplicates and batching mean write tools must be idempotent.
- Standard Webhooks' 410 means "disable endpoint", but follow the MCP semantics ("don't retry this event").

### Critic flags

- **Events key.** The SDK can't emit `capabilities.events`. Override `server/discover` (RequestHandlers beat built-ins) or post-process with a filter, then curl it.
- **Synchronous verification (gap).** Verification must be synchronous inside `events/subscribe`: the result or -32015 goes in the same JSON-RPC response, so it can't use the queue. ChatGPT's subscribe timeout is unknown, so allow about 5 s inline with the guarded client.
- **Protocol revision (gap).** Unknown whether ChatGPT and Claude.ai send 2026-07-28 `server/discover` or 2025-11-25 `initialize`. Capture traffic on the first live connect.
- **Plan (gap).** Roger's ChatGPT plan is unknown.

### Unverified (verbatim)

- Which ttlMs ChatGPT actually sends, and how far ahead of refreshBefore it refreshes. Not documented. AgentMail grants 72 h by default (30 d max), but that is one vendor's choice.
- Which callback host or domain ChatGPT uses (receiver.example.com in the docs is a placeholder), and whether ChatGPT itself rejects stale timestamps or checks for duplicate webhook-ids.
- Whether ChatGPT reads the SEP-3415 extensions['io.modelcontextprotocol/events'] key at all, and whether it accepts -32027 as well as -32015.
- Whether ChatGPT sends a ttlMs:null (no-expiry) request, and whether it ever sends a non-null cursor on refresh.
- The exact plans eligible for event-triggered tasks in Work. help.openai.com/articles/10291617 returned 403 to direct fetch. A search snippet said Plus, Pro, Business, Enterprise and Edu.
- Where the user-facing batching settings live (OpenAI mentions 'the task's batching settings' but the UI for them is not documented), and whether event-triggered tasks show up under Scheduled for custom plugins.
- Which retry status codes ChatGPT expects: 408/429/5xx retryable comes only from AgentMail's docs, not OpenAI's.
- Whether the official C# MCP SDK (ModelContextProtocol on NuGet) supports custom events/* methods on 2026-07-28 stateless Streamable HTTP. Not checked under this topic. A hand-written JSON-RPC dispatch for these three methods is simple either way.

### Snippets

**server/discover result (advertise both keys)**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "resultType": "complete",
    "supportedVersions": ["2026-07-28"],
    "capabilities": {
      "tools": {},
      "resources": {},
      "events": {},
      "extensions": { "io.modelcontextprotocol/events": {} }
    }
  }
}
```

**Sample events/list response for the conversation archive**

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "resultType": "complete",
    "events": [
      {
        "name": "conversation.created",
        "description": "A recorded conversation finished syncing from the phone and has a transcript.",
        "delivery": ["webhook"],
        "inputSchema": {
          "type": "object",
          "properties": {
            "keyword": { "type": "string", "description": "Only conversations whose transcript or summary mentions this word or phrase." },
            "minDurationSeconds": { "type": "integer", "minimum": 0, "description": "Only conversations at least this long." }
          },
          "additionalProperties": false
        },
        "payloadSchema": {
          "type": "object",
          "properties": {
            "conversationId": { "type": "string" },
            "title": { "type": "string" },
            "startedAt": { "type": "string", "format": "date-time" },
            "endedAt": { "type": "string", "format": "date-time" },
            "durationSeconds": { "type": "integer" },
            "summary": { "type": "string" },
            "url": { "type": "string" }
          },
          "required": ["conversationId", "startedAt", "endedAt", "url"],
          "additionalProperties": false
        }
      }
    ]
  }
}
```

**events/subscribe request from ChatGPT and our result**

```jsonc
// request
{"jsonrpc":"2.0","id":3,"method":"events/subscribe","params":{"name":"conversation.created","arguments":{"keyword":"roof"},"delivery":{"mode":"webhook","url":"https://<chatgpt-receiver>/mcp-events/<id>","secret":"whsec_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="},"cursor":null,"ttlMs":86400000}}
// result (after a successful verification POST)
{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","id":"sub_3f9a1c0e7b52d4a8","refreshBefore":"2026-10-21T18:40:00Z","cursor":null,"truncated":false}}
// verification failure
{"jsonrpc":"2.0","id":3,"error":{"code":-32015,"message":"CallbackEndpointError","data":{"reason":"challenge_failed"}}}
// unsubscribe request -> result {} 
{"jsonrpc":"2.0","id":4,"method":"events/unsubscribe","params":{"name":"conversation.created","arguments":{"keyword":"roof"},"delivery":{"mode":"webhook","url":"https://<chatgpt-receiver>/mcp-events/<id>"}}}
```

**Sample signed webhook POST (signature computed for real with the example secret)**

```http
Secret: whsec_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=   (key = bytes 0x00..0x1f)

POST https://<chatgpt-receiver>/mcp-events/<id>
Content-Type: application/json
webhook-id: evt_conv_01JB8Z3K2Q
webhook-timestamp: 1792521727
webhook-signature: v1,wWRpublnHm9z7T0ecnov1isYAxFOtmSax65jYIp2wsY=
X-MCP-Subscription-Id: sub_3f9a1c0e7b52d4a8

{"eventId":"evt_conv_01JB8Z3K2Q","name":"conversation.created","timestamp":"2026-10-20T18:42:07Z","data":{"conversationId":"conv-2026-10-20-1842","title":"Call with Dana about the roof","startedAt":"2026-10-20T18:12:30Z","endedAt":"2026-10-20T18:41:55Z","durationSeconds":1765,"summary":"Dana quoted the roof repair and asked to move the start date.","url":"https://pebbleaudio.okgodoit.com/c/conv-2026-10-20-1842"},"cursor":null}

(Body is exactly those 430 bytes, compact JSON, no trailing newline. 1792521727 = 2026-10-20T18:42:07Z.)

Verification POST, same secret and timestamp:
webhook-id: msg_verification_7f3a9c
webhook-signature: v1,L7hCZcdxlvfgE1cAGcQWXPt1+D1GgWcwMQIjbGo1tKs=
body: {"type":"verification","challenge":"q8Zr3mX0b1V2nYk7"}
expected 2xx reply body: {"challenge":"q8Zr3mX0b1V2nYk7"}
```

**Standard Webhooks HMAC in C# (no dependency)**

```csharp
using System.Security.Cryptography;
using System.Text;

static byte[] DecodeSecret(string whsec)
{
    if (!whsec.StartsWith("whsec_", StringComparison.Ordinal)) throw new ArgumentException("bad secret");
    var key = Convert.FromBase64String(whsec[6..]);
    if (key.Length is < 24 or > 64) throw new ArgumentException("secret must decode to 24-64 bytes");
    return key;
}

// body = the exact bytes that will be sent (serialize once)
static string Sign(byte[] key, string webhookId, long unixSeconds, ReadOnlySpan<byte> body)
{
    var prefix = Encoding.UTF8.GetBytes($"{webhookId}.{unixSeconds}.");
    var toSign = new byte[prefix.Length + body.Length];
    prefix.CopyTo(toSign, 0);
    body.CopyTo(toSign.AsSpan(prefix.Length));
    return "v1," + Convert.ToBase64String(HMACSHA256.HashData(key, toSign));
}

// Rotation window: header = Sign(newKey,...) + " " + Sign(oldKey,...)
// Verify challenge echo: CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(sent), Encoding.UTF8.GetBytes(echoed))
// Verify (for tests): split header on ' ', accept if any 'v1,' entry FixedTimeEquals the computed one and |now - ts| <= 300 s.
```

## 5. .NET 10, EF Core, Npgsql, Postgres FTS, task queue, Kestrel, nginx, systemd

### Verified facts

**Runtime**

- **.NET 10 LTS.** Released Nov 11, 2025; end of support Nov 14, 2028; latest patch 10.0.13 (Oct 13, 2026). .NET 8 and 9 end Nov 10, 2026. (https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core)
- **Droplet runtime.** 10.0.7 is six patches behind. The backports PPA already has `dotnet10 10.0.113-10.0.13-0ubuntu1~22.04.1~ppa1` for jammy, so `apt update && apt upgrade aspnetcore-runtime-10.0` gets it. (https://launchpad.net/~dotnet/+archive/ubuntu/backports)
- **Ubuntu 22.04 install.** .NET 10 is supported only via `sudo add-apt-repository ppa:dotnet/backports` then `apt-get install -y aspnetcore-runtime-10.0`; the built-in feed has only 8.0, 7.0, and 6.0. (https://learn.microsoft.com/en-us/dotnet/core/install/linux-ubuntu-install)
- **PPA support.** Canonical's backports support is best-effort and ends with Microsoft's or Ubuntu's support period. Don't mix it with packages.microsoft.com .NET packages. (https://learn.microsoft.com/en-us/dotnet/core/install/linux-ubuntu-decision)
- **Framework-dependent publishing.** It is the default: `dotnet publish -c Release -r linux-x64 --self-contained false`. Since .NET 8 a RID no longer implies self-contained (`PublishSingleFile` and `PublishAot` still do). Framework-dependent apps roll forward to the newest installed 10.0.x patch; self-contained ones don't. (https://learn.microsoft.com/en-us/dotnet/core/deploying/)
- **The breaking change.** The .NET 8 SDK made runtime-specific apps framework-dependent by default. (https://learn.microsoft.com/en-ca/dotnet/Core/compatibility/sdk/8.0/runtimespecific-app-default)

**EF Core and Npgsql**

- **Versions.**
  - `Microsoft.EntityFrameworkCore` 10.0.13 (2026-10-13).
  - `Microsoft.EntityFrameworkCore.Design`, `dotnet-ef`, and `Microsoft.Extensions.Hosting.Systemd`: 10.0.13.
  - `Npgsql.EntityFrameworkCore.PostgreSQL` 10.0.3 (2026-07-10) and `Npgsql` 10.0.3 (2026-05-27).
  - EF 11 is rc.2 only.

  (https://api.nuget.org/v3-flatcontainer/npgsql.entityframeworkcore.postgresql/index.json)
- **Npgsql EF compatibility.** Npgsql EF 10.0.3 depends on EF Core and Relational `[10.0.4, 11.0.0)` and Npgsql 10.0.3, so it works with EF 10.0.13. License: PostgreSQL. (https://api.nuget.org/v3-flatcontainer/npgsql.entityframeworkcore.postgresql/10.0.3/npgsql.entityframeworkcore.postgresql.nuspec)
- **FTS mapping.** `.HasGeneratedTsVectorColumn(p => p.SearchVector, "english", p => new { p.Title, p.Body }).HasIndex(p => p.SearchVector).HasMethod("GIN")` with an `NpgsqlTsVector` property, or `.IsTsVectorExpressionIndex("english")`. Translations: `ToTsVector`, `PlainToTsQuery`, `PhraseToTsQuery`, `WebSearchToTsQuery`, `Matches` (@@), `Rank` (ts_rank), `RankCoverDensity` (ts_rank_cd), and `tsquery.GetResultHeadline(text[, options])` (ts_headline). (https://www.npgsql.org/efcore/mapping/full-text-search.html)
- **Date and time.** A UTC `DateTime` maps to timestamptz; Local or Unspecified maps to timestamp, and writing non-UTC to timestamptz throws. `DateTimeOffset` works only with Offset=0, and timestamptz reads back as UTC `DateTime`. In 10.0, date and time map to `DateOnly`/`TimeOnly`. NodaTime is recommended. Don't use `Npgsql.EnableLegacyTimestampBehavior`. (https://www.npgsql.org/doc/types/datetime.html)
- **JSON (EF 10).** `ComplexProperty(c => c.Details, d => d.ToJson())` gives jsonb (owned ToJson is pre-EF 10; `[Column(TypeName="jsonb")]` POCO mapping is deprecated). `JsonDocument` maps to jsonb for open payloads. (https://www.npgsql.org/efcore/mapping/json.html)
- **EF 10 release notes.** ToJson columns are `jsonb NOT NULL`. Breaking: array Contains → `= ANY(...)` unless a GIN index on the array is modelled. (https://github.com/npgsql/doc/blob/main/conceptual/EFCore.PG/release-notes/10.0.md)
- **Enums.** `UseNpgsql(cs, o => o.MapEnum<T>("name"))` (EF 9+). Migrations add values, PostgreSQL can't remove them, and renames need raw SQL. (https://www.npgsql.org/efcore/mapping/enum.html)

**Postgres and queue mechanics**

- **SKIP LOCKED.** PostgreSQL 16 says it "can be used to avoid lock contention with multiple consumers accessing a queue-like table" (not for general use), and the locking clause goes after LIMIT. (https://www.postgresql.org/docs/16/sql-select.html)
- **Raw SQL.** `Database.SqlQuery<T>(FormattableString)` parameterizes values and returns unmapped types (EF 8+), and EF wraps it as a subquery only if LINQ is composed on top. So `UPDATE ... RETURNING` must run via `ToListAsync` with no further operators. (https://learn.microsoft.com/en-us/ef/core/querying/sql-queries)
- **LISTEN/NOTIFY.** Npgsql uses the `NpgsqlConnection.Notification` event and `Wait`/`WaitAsync` on a dedicated connection, with keepalives advised. (https://www.npgsql.org/doc/wait.html)

**ASP.NET Core**

- **Migrations.** Bundles are recommended (`dotnet ef migrations bundle --self-contained --target-runtime linux-x64 --output artifacts/efbundle`, run with `--connection`, no SDK on the server). EF 9+ takes a migration lock, and `Migrate()` throws on pending model changes (CI: `dotnet ef migrations has-pending-model-changes`). Startup `MigrateAsync` is acceptable for single-instance deploys. (https://learn.microsoft.com/en-us/ef/core/managing-schemas/migrations/applying)
- **Antiforgery.** Razor Pages validate automatically. Minimal APIs need `AddAntiforgery` plus `UseAntiforgery`, after `UseAuthentication`/`UseAuthorization`. With it on, `[FromForm]` endpoints require a token unless `.DisableAntiforgery()`. (https://learn.microsoft.com/en-us/aspnet/core/security/anti-request-forgery?view=aspnetcore-10.0)
- **Static assets.** `MapStaticAssets()` plus `MapRazorPages().WithStaticAssets()` (.NET 9+). `UseStaticFiles` is still needed for default documents and runtime-generated files. (https://learn.microsoft.com/en-us/aspnet/core/fundamentals/map-static-files?view=aspnetcore-10.0)
- **SSE.** .NET 10 adds `TypedResults.ServerSentEvents(IAsyncEnumerable<SseItem<T>>)`. (https://learn.microsoft.com/en-us/aspnet/core/fundamentals/minimal-apis/responses?view=aspnetcore-10.0)
- **Microsoft's nginx guide** (2026-10). `proxy_http_version 1.1`, the Upgrade/Connection map, Host, X-Forwarded-For, and X-Forwarded-Proto, with `UseForwardedHeaders` for `XForwardedFor|XForwardedProto`; loopback proxies are trusted by default. Its sample unit: `ExecStart=/usr/bin/dotnet app.dll`, `Restart=always`, `RestartSec=10`, `KillSignal=SIGTERM` (avoid SIGINT), `SyslogIdentifier`, `User`, `Environment=ASPNETCORE_ENVIRONMENT=Production`, and `TimeoutStopSec`. Environment variables use `__` for `:`. (https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/linux-nginx?view=aspnetcore-10.0)
- **KnownNetworks obsolete.** In .NET 10, `ForwardedHeadersOptions.KnownNetworks` and `Microsoft.AspNetCore.HttpOverrides.IPNetwork` are obsolete; use `KnownIPNetworks` with `System.Net.IPNetwork`. (https://learn.microsoft.com/is-is/dotnet/core/compatibility/10)

**systemd**

- **AddSystemd.** `AddSystemd()`/`UseSystemd()` activates only under systemd or with `NOTIFY_SOCKET` (otherwise a no-op). It registers `SystemdLifetime`, `SystemdNotifier` (READY/STOPPING), and journald formatting, needs `Type=notify`, and lives in package `Microsoft.Extensions.Hosting.Systemd`. (https://learn.microsoft.com/en-us/dotnet/api/microsoft.extensions.hosting.systemdhostbuilderextensions.addsystemd?view=net-10.0-pp)
- **Unit semantics.** `Type=notify` waits for `READY=1`. Unset `NotifyAccess` is forced to main. `Restart=always` restarts on any exit but `systemctl stop`. `RestartSec` defaults to 100ms. `EnvironmentFile` beats `Environment=`, a `-` prefix makes it optional, and it is read just before exec. (https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)
- **Secrets.** Environment variables are unsuitable for secrets (D-Bus-visible, inherited); `LoadCredential=` gives `$CREDENTIALS_DIRECTORY`. (https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)
- **Versions.** jammy-updates ships systemd 249.11 and nginx 1.18.0-6ubuntu14.21. (https://packages.ubuntu.com/jammy-updates/systemd)

**nginx and Kestrel**

- **nginx proxy defaults.** `proxy_http_version` defaulted to 1.0 before nginx 1.29.7, so set 1.1 explicitly on 1.18. `proxy_buffering` is on (per-response off via `X-Accel-Buffering: no`). `proxy_read_timeout` and `proxy_send_timeout` are 60s between successive operations. With `proxy_request_buffering` on (the default), the whole body is read first. (https://nginx.org/en/docs/http/ngx_http_proxy_module.html)
- **nginx core defaults.** `client_max_body_size 1m`, `client_body_timeout 60s`, `keepalive_timeout 75s`, `send_timeout 60s`. (https://nginx.org/en/docs/http/ngx_http_core_module.html)
- **Kestrel defaults.** `MaxRequestBodySize` 30,000,000 bytes; `MinRequestBodyDataRate` and `MinResponseDataRate` 240 B/s with a 5 s grace; `RequestHeadersTimeout` 30 s; `MaxConcurrentConnections` unlimited. (https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/kestrel/options?view=aspnetcore-10.0)
- **Keep-alive.** `KeepAliveTimeout` defaults to 130 s. (https://learn.microsoft.com/en-us/dotnet/api/microsoft.aspnetcore.server.kestrel.core.kestrelserverlimits.keepalivetimeout?view=aspnetcore-10.0)
- **Per-endpoint body limits.** ASP.NET Core 10 routing maps `RequestSizeLimitAttribute`/`DisableRequestSizeLimitAttribute` to `IHttpMaxRequestBodySizeFeature`, so `[RequestSizeLimit(n)]` or `.WithMetadata(new RequestSizeLimitAttribute(n))` works per minimal API endpoint. (https://github.com/dotnet/aspnetcore/blob/release/10.0/src/Http/Routing/src/EndpointRoutingMiddleware.cs)

**Host memory, keys, and Postgres access**

- **GC.** With one logical CPU, workstation GC is always used (`DOTNET_gcServer` is moot). `DOTNET_GCHeapHardLimit` (hex) or `DOTNET_GCConserveMemory` (0-9) cap or trim the heap. DATAS is on by default since .NET 9. (https://learn.microsoft.com/en-us/dotnet/standard/garbage-collection/workstation-server-gc)
- **Data Protection keys.** Without a HOME key store, keys live only in memory, so every restart invalidates cookies and antiforgery tokens. Persist them. (https://learn.microsoft.com/en-us/aspnet/core/security/data-protection/configuration/default-settings?view=aspnetcore-10.0)
- **PG15+ public schema.** No CREATE on `public` for PUBLIC, and `public` is owned by `pg_database_owner`, so a database's owner role can create tables there and other roles can't. (https://www.postgresql.org/docs/release/15.0/)
- **Npgsql connections.** A `Host` starting with `/` is a socket directory (`Host=/var/run/postgresql`). Defaults: Maximum Pool Size 100, Minimum 0, Timeout 15 s, Command Timeout 30 s, Keepalive off. (https://www.npgsql.org/doc/connection-string-parameters.html)
- **Peer auth.** It maps the OS user name to the DB user, Unix socket only. (https://www.postgresql.org/docs/16/auth-peer.html)
- **Stale SDK claim.** This topic's "`ModelContextProtocol.AspNetCore` is at 1.4.1" is stale; the critic confirmed 2.2.0 (section 1). (https://api.nuget.org/v3-flatcontainer/modelcontextprotocol.aspnetcore/index.json)

### Recommendations

- **Runtime first.** `apt upgrade aspnetcore-runtime-10.0` (10.0.7 → 10.0.13), then restart the other .NET services, which keep the old runtime until restarted.
- **Publish and run.** Framework-dependent net10.0, started as `/usr/bin/dotnet .../PebbleAudio.dll` (not the apphost).
- **Packages.** Pin `Microsoft.EntityFrameworkCore.Design` 10.0.13, `Npgsql.EntityFrameworkCore.PostgreSQL` 10.0.3, and `Microsoft.Extensions.Hosting.Systemd` 10.0.13, plus the `dotnet-ef` 10.0.13 local tool in `.config/dotnet-tools.json`. No other ORM or queue library.
- **Database.** Its own role and DB (`CREATE DATABASE pebbleaudio OWNER pebbleaudio`) in the existing cluster, over the Unix socket. Check `pg_hba.conf` before choosing peer or scram (the critic prefers peer). Migrations via startup `MigrateAsync` or a CI-built bundle, plus `has-pending-model-changes` in CI, with `CREATE EXTENSION` and SQL functions in `migrationBuilder.Sql`.
- **FTS.** A generated `english` tsvector plus GIN. Query with `Matches(EF.Functions.WebSearchToTsQuery("english", q))` ordered by `.Rank`, and `GetResultHeadline(e.Text, "MaxFragments=2, MinWords=5, MaxWords=20")` only for the returned page.
- **Time and money.** UTC instants everywhere (timestamptz), the recording's IANA zone in a text column, `DateOnly` day keys, money as long cents, `JsonDocument` only for open payloads, and `ComplexProperty(...).ToJson()` for structured JSON.
- **Queue.**
  - Table `jobs`: id bigserial, kind enum, payload jsonb, status enum, run_after, attempts, max_attempts, locked_until, locked_by, last_error, created_at, and finished_at. Add a partial index on run_after `WHERE status IN ('queued','running')`.
  - Claim with a single-statement lease (`UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING`), so no transaction is held during ffmpeg. Expired leases get reclaimed.
  - Backoff to `max_attempts`, then `dead` (shown in /admin); heartbeat long jobs. Optionally NOTIFY on insert, with a 5-10 s poll fallback.
- **Workers.** One `BackgroundService` per job class (transcode, webhook, import) at concurrency 1. Each iteration gets its own scope and DbContext, catches everything inside the loop, and honors `stoppingToken`.
- **Program.cs.**
  - `AddSystemd()`, `AddRazorPages()`, ForwardedHeaders (For and Proto; `KnownIPNetworks` if needed), and persisted Data Protection keys.
  - Pipeline order: `UseForwardedHeaders` → `UseAuthentication` → `UseAuthorization` → `UseAntiforgery` → `MapStaticAssets` → `MapRazorPages().WithStaticAssets()` → API groups.
  - `.DisableAntiforgery()` on `/oauth/token` (this topic also lists `/register` and webhook receivers); keep it on Razor Pages and consent.
- **Uploads.** Kestrel's ~30 MB global limit stays. `/sync` gets `[RequestSizeLimit]` or `[DisableRequestSizeLimit]` and streams to disk, while nginx raises `client_max_body_size`, sets `proxy_request_buffering off`, and raises `client_body_timeout` only in `/sync`.
- **nginx.** A new site file plus `certbot --nginx -d pebbleaudio.okgodoit.com`, `proxy_http_version 1.1`, and `proxy_set_header Connection ""`. `/mcp` and SSE get `proxy_buffering off; proxy_cache off; proxy_read_timeout 3600s; proxy_send_timeout 3600s;`, plus `X-Accel-Buffering: no` from the app.
- **Kestrel.** A loopback-only port, checked for collisions. Don't lower `MinResponseDataRate`, and heartbeat SSE every 15-30 s.
- **Unit.** `Type=notify`, a dedicated user, `Restart=always`, `KillSignal=SIGTERM`, `TimeoutStopSec=30`, `StateDirectory=pebbleaudio`, an EnvironmentFile under `/etc/pebbleaudio`, and hardening (`NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp`). Run ffmpeg one job at a time under `nice`.
- **Caddy vs nginx.** Roger's defaults say Caddy, but the box already runs nginx and certbot, and adding one server block is lower risk. Confirm this deviation with Roger.

### Risks

- Ubuntu 22.04 standard support ends around May 2027, before .NET 10's Nov 2028 end, and backports support ends with Ubuntu's. Plan a move to 24.04 or 26.04 within about 18 months.
- The unpatched 10.0.7 runtime is shared, so an upgrade hits every .NET app on its next restart.
- Antiforgery rejects OAuth form posts without the opt-out.
- nginx 1.18 defaults silently buffer or cut SSE at 60 s.
- nginx's 1m body limit (413) and Kestrel's 30 MB and 240 B/s minimums can fail iPhone uploads.
- Unpersisted Data Protection keys break cookies, antiforgery, and encrypted columns on every deploy.
- Queue traps: LINQ over `UPDATE...RETURNING`, a transaction held across ffmpeg, and no `max_attempts`.
- A non-UTC `DateTime` written to timestamptz throws.
- EF 10 array Contains skips an unmodelled GIN index.
- Pool size 100 can exhaust the shared `max_connections`; use 10-20.
- EnvironmentFile secrets are visible in `/proc/<pid>/environ`.

### Critic flags

- **Settle one set** of port (5110 here vs 5080), root (`/srv/pebbleaudio` vs `/opt/pebbleaudio`), keys (`dp-keys` vs `keys`), connection string (`ConnectionStrings__Db` vs `__Default`), env file (`root:pebbleaudio 0640` vs `root 0600`), and `ProtectSystem` (`strict` vs `full`).
- **Postgres auth.** This topic uses a password; section 6 uses peer, which the critic prefers, after checking `pg_hba.conf`. situ uses 127.0.0.1 with a password, so `local all all peer` probably exists, unconfirmed.
- **Memory caps.** `DOTNET_GCHeapHardLimit=0x30000000` (768 MB) plus `MemoryMax=768M`, which also covers ffmpeg, invites OOM kills. Use `MemoryMax` with default GC cgroup sizing (unverified), or a much smaller heap limit. The box already has 653 MB in swap, with about 1.3 GB available.
- **Runtime check (gap).** Nobody has checked the droplet for `Microsoft.AspNetCore.App 10.0.x`, or whether situ, domainotron, or todo are .NET and would be affected by the upgrade.
- **CI database (gap).** CI needs real Postgres 16 (`services: postgres:16`, Docker in CI only is fine) and `dotnet tool restore` before `has-pending-model-changes`.

### Unverified (verbatim)

- The exact Ubuntu 22.04 standard-support end date: third-party sources say 31 May 2027 and a STIG says April 2027. I could not open Canonical's release-cycle page directly.
- Whether the apphost executable (as opposed to `dotnet App.dll`) finds the Ubuntu-packaged runtime under /usr/lib/dotnet without DOTNET_ROOT. I recommend `/usr/bin/dotnet App.dll` to sidestep this, and did not test it on the droplet.
- The pg_hba.conf, max_connections and current Postgres load on Roger's droplet: not inspected in this research. Check them on the server before choosing peer or scram auth and pool sizes.
- Whether other .NET apps on the droplet pin a specific 10.0.x patch through rollForward settings, which would affect a runtime upgrade. Not inspected.
- The exact ts_headline option string and its performance on long transcripts: the Npgsql docs show only the GetResultHeadline signature, not a full LINQ example. Confirm with a quick test that the translated SQL is as expected.
- Whether ALTER TYPE ... ADD VALUE generated by MapEnum migrations conflicts with EF's per-migration transaction on PG16 (a new value cannot be used in the same transaction). Not checked against EF 10's generated SQL.
- The ModelContextProtocol.AspNetCore 1.4.1 stateless-mode API surface and its compatibility with the 2026-07-28 MCP spec: I verified only the version number; the API belongs to a separate research topic.
- That Kestrel's MinResponseDataRate does not trip on idle SSE streams. My understanding is that it applies only while the response is backpressured, but I did not confirm this in the docs; heartbeats make it moot.
- The Ubuntu package install path (/usr/lib/dotnet vs /usr/share/dotnet) on this droplet: not checked.

### Snippets

These use this topic's port, path, and memory choices, which section 6 contradicts; see the critic flags.

**csproj essentials**

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <InvariantGlobalization>false</InvariantGlobalization>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Npgsql.EntityFrameworkCore.PostgreSQL" Version="10.0.3" />
    <PackageReference Include="Microsoft.EntityFrameworkCore.Design" Version="10.0.13" PrivateAssets="all" />
    <PackageReference Include="Microsoft.Extensions.Hosting.Systemd" Version="10.0.13" />
  </ItemGroup>
</Project>

# publish (CI)
dotnet publish src/PebbleAudio -c Release -r linux-x64 --self-contained false -o out
```

**Program.cs skeleton (Razor Pages + Minimal APIs + systemd + proxy)**

```csharp
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Mvc; // RequestSizeLimitAttribute

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSystemd(); // no-op outside systemd
builder.Services.AddRazorPages();
builder.Services.AddDbContext<AppDb>(o => o.UseNpgsql(
    builder.Configuration.GetConnectionString("Db"),
    npg => { npg.MapEnum<JobStatus>("job_status"); npg.MapEnum<JobKind>("job_kind"); }));
builder.Services.AddDataProtection()
    .PersistKeysToFileSystem(new DirectoryInfo("/var/lib/pebbleaudio/dp-keys"));
builder.Services.Configure<ForwardedHeadersOptions>(o =>
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto);
    // nginx on loopback is trusted by default; use o.KnownIPNetworks (not KnownNetworks) if needed
builder.Services.AddAntiforgery();
builder.Services.AddHostedService<JobWorker>();

var app = builder.Build();
app.UseForwardedHeaders();
app.UseAuthentication();
app.UseAuthorization();
app.UseAntiforgery();
app.MapStaticAssets();
app.MapRazorPages().WithStaticAssets();

app.MapPost("/oauth/token", TokenEndpoint.Handle).DisableAntiforgery();
app.MapPost("/oauth/register", RegisterEndpoint.Handle).DisableAntiforgery();
app.MapPost("/sync/audio", SyncEndpoints.UploadAudio)
   .WithMetadata(new RequestSizeLimitAttribute(200_000_000)); // honored by routing in ASP.NET Core 10
app.MapGet("/healthz", () => Results.Ok("ok"));
app.Run();
```

**FTS model + query**

```csharp
modelBuilder.Entity<Segment>()
    .HasGeneratedTsVectorColumn(s => s.SearchVector, "english", s => new { s.Text })
    .HasIndex(s => s.SearchVector).HasMethod("GIN");

// query
var tsq = EF.Functions.WebSearchToTsQuery("english", q);
var hits = await db.Segments
    .Where(s => s.SearchVector.Matches(tsq))
    .OrderByDescending(s => s.SearchVector.Rank(tsq))
    .Take(20)
    .Select(s => new { s.Id, s.ConversationId, s.StartedAt,
        Snippet = tsq.GetResultHeadline(s.Text, "MaxFragments=2, MinWords=5, MaxWords=20") })
    .ToListAsync(ct);
```

**Queue claim/complete/fail SQL (lease + SKIP LOCKED, crash-safe)**

```sql
-- claim (single autocommit statement; no transaction held during work)
UPDATE jobs SET status = 'running', attempts = attempts + 1,
       locked_by = {worker}, locked_until = now() + interval '10 minutes'
WHERE id = (
  SELECT id FROM jobs
  WHERE kind = {kind}::job_kind
    AND ((status = 'queued' AND run_after <= now())
      OR (status = 'running' AND locked_until < now()))   -- crashed worker's lease expired
  ORDER BY run_after, id
  LIMIT 1
  FOR UPDATE SKIP LOCKED)
RETURNING id AS "Id", payload AS "Payload", attempts AS "Attempts", max_attempts AS "MaxAttempts";

-- heartbeat for long ffmpeg runs
UPDATE jobs SET locked_until = now() + interval '10 minutes' WHERE id = {id} AND locked_by = {worker};
-- success
UPDATE jobs SET status = 'done', finished_at = now(), locked_until = NULL WHERE id = {id} AND locked_by = {worker};
-- failure
UPDATE jobs SET status = CASE WHEN attempts >= max_attempts THEN 'dead' ELSE 'queued' END::job_status,
       run_after = now() + make_interval(secs => least(3600, 30 * power(2, attempts))),
       last_error = {error}, locked_by = NULL, locked_until = NULL
WHERE id = {id} AND locked_by = {worker};

-- C#: var job = (await db.Database.SqlQuery<ClaimedJob>($"...").ToListAsync(ct)).SingleOrDefault();
-- (never .FirstOrDefaultAsync() on it: EF would wrap the UPDATE in a subquery)
```

**BackgroundService worker loop**

```csharp
public sealed class JobWorker(IServiceScopeFactory scopes, ILogger<JobWorker> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        var worker = $"{Environment.MachineName}:{Environment.ProcessId}";
        while (!stop.IsCancellationRequested)
        {
            var didWork = false;
            try
            {
                await using var scope = scopes.CreateAsyncScope();
                var db = scope.ServiceProvider.GetRequiredService<AppDb>();
                var job = await JobQueue.ClaimAsync(db, JobKind.Transcode, worker, stop);
                if (job is not null)
                {
                    didWork = true;
                    try { await Handlers.RunAsync(scope.ServiceProvider, job, stop);
                          await JobQueue.CompleteAsync(db, job.Id, worker, stop); }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    { log.LogError(ex, "job {Id} failed", job.Id);
                      await JobQueue.FailAsync(db, job.Id, worker, ex.Message, CancellationToken.None); }
                }
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
            catch (Exception ex) { log.LogError(ex, "queue loop error"); }
            if (!didWork) await Task.Delay(TimeSpan.FromSeconds(5), stop).ContinueWith(_ => { });
        }
    }
}
```

**systemd unit /etc/systemd/system/pebbleaudio.service**

```ini
[Unit]
Description=Pebble audio archive (ASP.NET Core)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=notify
User=pebbleaudio
Group=pebbleaudio
WorkingDirectory=/srv/pebbleaudio/current
ExecStart=/usr/bin/dotnet /srv/pebbleaudio/current/PebbleAudio.dll
EnvironmentFile=/etc/pebbleaudio/pebbleaudio.env
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=ASPNETCORE_URLS=http://127.0.0.1:5110
Environment=DOTNET_GCHeapHardLimit=0x30000000
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=30
SyslogIdentifier=pebbleaudio
StateDirectory=pebbleaudio
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target

# /etc/pebbleaudio/pebbleaudio.env  (root:pebbleaudio 0640)
# ConnectionStrings__Db=Host=/var/run/postgresql;Port=5432;Database=pebbleaudio;Username=pebbleaudio;Password=...;Maximum Pool Size=15
```

**nginx server block (new file; certbot adds the 443 parts)**

```nginx
server {
  server_name pebbleaudio.okgodoit.com;
  client_max_body_size 2m;

  location / {
    proxy_pass http://127.0.0.1:5110;
    proxy_http_version 1.1;              # nginx 1.18 defaults to 1.0
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
  location /mcp {                        # Streamable HTTP / SSE
    proxy_pass http://127.0.0.1:5110;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  }
  location /sync/ {                      # iPhone background uploads
    proxy_pass http://127.0.0.1:5110;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 200m;
    client_body_timeout 300s;
    proxy_request_buffering off;
    proxy_read_timeout 300s;
  }
}
# then: nginx -t && systemctl reload nginx && certbot --nginx -d pebbleaudio.okgodoit.com
```

**Postgres database + role inside the existing cluster**

```bash
sudo -u postgres psql <<'SQL'
CREATE ROLE pebbleaudio LOGIN PASSWORD :'pw';   -- or generate and paste
CREATE DATABASE pebbleaudio OWNER pebbleaudio;
REVOKE CONNECT ON DATABASE pebbleaudio FROM PUBLIC;
SQL
# PG15+: public schema owned by pg_database_owner -> owner role can run migrations; other roles can't create there.
# Extensions needing superuser (if any) go in a migration only if the role is allowed, else pre-create once via the repo's setup script.
```

## 6. Deploy and CI

### Verified facts

**GitHub Actions**

- **actions/checkout.** v7 (v7.0.1 latest; v7.0.0 on 18 Jun 2026) moved to ESM and stopped checking out fork PRs on `pull_request_target`/`workflow_run`. `runs.using: node24`, `fetch-depth` 1, `persist-credentials` true. (https://github.com/actions/checkout/releases)
- **checkout's runtime.** Its `action.yml` declares `runs.using: node24`. (https://raw.githubusercontent.com/actions/checkout/main/action.yml)
- **setup-dotnet.** v6.0.0 (16 Jul 2026) is ESM with no breaking changes and node24. The README pairs `checkout@v7` with `setup-dotnet@v6`, and `'10.0.x'` gets the latest patch. (https://github.com/actions/setup-dotnet/blob/main/README.md)
- **setup-dotnet 5.4.0+.** A `global.json` with `rollForward` needs a fully qualified `sdk.version` (for example `10.0.100`), since `10.0.*` fails, and `cache: true` needs `packages.lock.json`. (https://github.com/actions/setup-dotnet/releases)
- **ssh-agent.** `webfactory/ssh-agent` v0.10.0 exists but is unnecessary: write the key to a file and use `ssh -i`. (https://github.com/webfactory/ssh-agent/releases)
- **Runner image.** Ubuntu 24.04 image 20261012.334.1 has rsync 3.2.7-1ubuntu1.5, openssh-client 9.6p1, and .NET SDKs to 10.0.401. (https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)
- **ubuntu-latest moves.** It goes to 26.04 between Oct 19 and Nov 19, 2026; pin `ubuntu-24.04`. (https://github.blog/changelog/2026-09-17-ubuntu-26-generally-available-and-latest-migration)
- **Concurrency.** One pending run per group by default, and a new one cancels the pending one. `queue: max` (up to 100) can't combine with `cancel-in-progress: true`. Naming any permission sets the rest to none. (https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)

**Hosting**

- **Microsoft's nginx hosting doc.** `KillSignal=SIGTERM` (avoid SIGINT; older doc versions still show it) and `TimeoutStopSec` (default 90 s on most distros). Loopback proxies are trusted. Data Protection keys must be persisted. The rest is in section 5. (https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/linux-nginx?view=aspnetcore-10.0)
- **Shutdown.** `IServer.StopAsync` with a default 30 s timeout: Kestrel closes its bindings and drains in-flight requests. Microsoft's only drain recipe is a load balancer plus a second instance, with no single-instance zero-downtime guidance. (https://learn.microsoft.com/en-us/dotnet/core/extensions/generic-host)
- **Kestrel socket activation.** `KestrelServerOptions.UseSystemd()` (in `Microsoft.AspNetCore.App` 10.0) opens fds from `SD_LISTEN_FDS_START`, only when `LISTEN_PID` matches and `LISTEN_FDS` is valid; it is a no-op under `dotnet run`. (https://raw.githubusercontent.com/dotnet/aspnetcore/main/src/Servers/Kestrel/Core/src/Systemd/KestrelServerOptionsSystemdExtensions.cs)
- **systemd.socket.** `Accept=no` passes the listening socket, and the service name defaults to the socket's. `FlushPending=no` (the default) keeps pending connections for the restarted service. The backlog is capped by `net.core.somaxconn` (typically 4096). (https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html)
- **AddSystemd package.** `services.AddSystemd()` comes from `Microsoft.Extensions.Hosting.Systemd`, latest stable 10.0.13 (2026-10-13), MIT. (https://www.nuget.org/packages/Microsoft.Extensions.Hosting.Systemd)
- **AddSystemd behavior.** It sets `SystemdLifetime`, sends started/stopping, uses the systemd log format, is a no-op elsewhere, and needs `Type=notify`. (https://learn.microsoft.com/en-us/dotnet/api/microsoft.extensions.hosting.systemdhostbuilderextensions.addsystemd)

**Migrations and extensions**

- **Startup migration.** It "can be acceptable for applications that prefer simple deployment" (EF 9+ lock), at the cost of schema rights and no SQL review. `EnsureCreated` before `Migrate` breaks it. (https://learn.microsoft.com/en-us/ef/core/managing-schemas/migrations/applying)
- **Transactions.** EF Core 10 runs one transaction per migration (EF 9 used one for all). Wrapping `MigrateAsync` in a transaction throws `MigrationsUserTransactionWarning`. (https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-9.0/breaking-changes)
- **Trusted extensions (PG16).** `pg_trgm`, `unaccent`, `fuzzystrmatch`, `btree_gin`, `pgcrypto`, and `citext` are trusted, so the DB owner can `CREATE EXTENSION` without superuser. (https://www.postgresql.org/docs/16/contrib.html)

**Host tooling**

- **journald.** `SystemMaxUse` defaults to 10% of the filesystem and `SystemKeepFree` to 15% (each capped at 4G). `SystemMaxFileSize` is 1/8 of MaxUse (capped at 128M). `MaxRetentionSec` is 0 (off). Use drop-ins in `/etc/systemd/journald.conf.d/*.conf`. (https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html)
- **sudoers.** Listed arguments must match exactly, no arguments means any arguments, and `""` means none. Avoid wildcards (they match spaces and slashes). `@includedir` skips names ending in `~` or containing `.`, so name the file `pebbleaudio-deploy`. (https://www.sudo.ws/docs/man/sudoers.man/)
- **authorized_keys `restrict`.** Disables port, agent, and X11 forwarding and PTY, plus future restrictions; rsync and `ssh host bash -s` still work. (https://man.openbsd.org/sshd.8)

**Monitoring and environment**

- **UptimeRobot Free.** 50 monitors, 5-min interval, keyword monitoring, "Good for hobby and non-profit projects". (https://uptimerobot.com/pricing/)
- **Healthchecks.io Hobbyist.** $0, 20 checks, 100 log entries each. Pings go to `https://hc-ping.com/<uuid>` (plus `/start`, `/fail`, `/<exit-status>`), at most 5 per minute per check. (https://healthchecks.io/docs/http_api/)
- **Better Stack free.** 10 monitors and heartbeats combined, 1 status page, Slack and e-mail alerts; the frequency is not stated. (https://betterstack.com/pricing)
- **DNS.** `pebbleaudio.okgodoit.com` → 134.209.0.150 via iwantmyname DNS (not proxied through Cloudflare). HTTPS did not answer on 2026-10-20. (https://pebbleaudio.okgodoit.com)
- **Roger's Mac.** `/usr/bin/rsync` is openrsync, protocol 29 ("2.6.9 compatible"): it has `--link-dest`, `--delete`, `--chmod`, `--compress`, and `--rsync-path`, but no `--mkpath` or `--info=progress2`. Homebrew dotnet has SDK 10.0.302. (https://github.com/apple-oss-distributions/rsync)

### Recommendations

- **Pipeline.** On push to main, on `ubuntu-24.04`: `checkout@v7` → `setup-dotnet@v6` (`10.0.x`) → `dotnet test` → `./deploy/deploy.sh`, the same script run by hand from the Mac. Concurrency `deploy-production` with `cancel-in-progress: false`.
- **Releases.**
  - Layout: `/opt/pebbleaudio/releases/<UTC-timestamp>-<sha12>` plus a relative `current` symlink.
  - Upload: `rsync -az --delete --chmod=D755,F644`, with `--link-dest` to `current`.
  - Swap: `ln -sfn` + `mv -T`. Keep 5 releases and never delete the live one.
  - Publish: `-p:UseAppHost=false`, with `release.txt` reported by `/healthz`.
- **Health gate.** `sudo systemctl restart ... || true` (Type=notify fails a restart when startup fails), then poll `127.0.0.1:5080/healthz` for 30 s for the release name. On failure: dump 80 journal lines, re-point `current`, and restart. Then curl the public URL from the runner.
- **Migrations.** Run them at startup before `app.Run()`; Postgres DDL is transactional, so a failure rolls back cleanly. The app role owns the DB (`createdb -O pebbleaudio`, which also allows `CREATE EXTENSION pg_trgm/unaccent`). Keep migrations additive so a code rollback still runs.
- **DB auth.** Peer auth over the socket (`Host=/var/run/postgresql;Database=pebbleaudio;Username=pebbleaudio`), with no password anywhere, after confirming `local all all peer`.
- **Restarts.** `pebbleaudio.socket` (`ListenStream=127.0.0.1:5080`) plus `ConfigureKestrel(k => k.UseSystemd())` keeps connections in the kernel backlog during restarts. `ShutdownTimeout` 15 s, `TimeoutStopSec=30`, and SSE ending on `ApplicationStopping`. Fallback: `ASPNETCORE_URLS`, with a 1-3 s 502 window.
- **Isolation.** Users `pebbleaudio` (nologin) and `deploy` (`restrict` keys), its own nginx site (`nginx -t`), DB, and role, a free port (`ss -ltnp`), and `MemoryMax=768M`.
- **Secrets.** `/etc/pebbleaudio/pebbleaudio.env` (root 0600) holds only bootstrap values; business settings and tokens live in the DB and /admin. Keys go in `/var/lib/pebbleaudio/keys`.
- **GitHub secrets.** `DEPLOY_SSH_KEY` (a dedicated ed25519 key) and `DEPLOY_KNOWN_HOSTS`, captured once with `ssh-keyscan -t ed25519 pebbleaudio.okgodoit.com` and checked against `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. Never keyscan in the workflow, and pass secrets via `env:`.
- **Sudoers.** `/etc/sudoers.d/pebbleaudio-deploy`, after `visudo -cf`, with literal `systemctl restart pebbleaudio.service` and `journalctl -u pebbleaudio.service -n 80 --no-pager`.
- **Logs.** journald via `SyslogIdentifier=pebbleaudio`. Check `journalctl --disk-usage` and existing drop-ins before adding `SystemMaxUse=1G`, `SystemKeepFree=2G`, `MaxRetentionSec=3month`.
- **$0 monitoring.**
  1. `Restart=always`.
  2. A once-a-minute local check of `/healthz` that restarts after 3 consecutive connect or timeout failures (a 503 from the DB is logged, not restarted) and pings Healthchecks.io when healthy, with a second check for backups.
  3. An UptimeRobot keyword monitor on `https://pebbleaudio.okgodoit.com/healthz` for `"db":"ok"`.
- **Manual deploys.** From the Mac: openrsync-safe flags and `${a[@]+"${a[@]}"}` for bash 3.2.

### Risks

- Socket activation on .NET 10 is untested. Before relying on it, verify with `while true; do curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:5080/healthz; sleep 0.1; done` during a restart (expect no 000 or 502).
- Without it, each deploy has a 1-3 s 502 window plus the drain.
- Streams that ignore `ApplicationStopping` hold shutdown open.
- Startup migrations mean DDL rights, and a code rollback doesn't undo a migration (expand, then contract).
- journald limits are system-wide.
- `MemoryMax` includes ffmpeg, so set too low it OOM-kills.
- Runtime patches come only via apt.
- Pushing to main deploys code, so protect main.
- Port 5080, the `deploy` user, and `/usr/bin/dotnet` are assumptions.
- UptimeRobot's free tier is for hobby and non-profit use.

### Critic flags

- **Timers, not cron.** The watchdog should be a systemd timer, since the box uses timers (`situ-backup.timer`, `situ-healthcheck.timer`) and has no crontabs.
- **Start without socket activation.** It's untested, and Roger's defaults reject extra machinery that doesn't protect money or data, so begin with a plain loopback bind.
- **CI database (gap).** `dotnet test` has no database: add `services: postgres:16`, `dotnet tool restore`, and `has-pending-model-changes`.
- **No repo yet (gap).** The workspace root isn't a git repo. A repo (name, visibility, branch protection) must exist before the key, secrets, or workflow.
- **No neighbour inventory (gap).** Nobody has listed the nginx sites and `default_server`, the ports in use, or existing users. The name serves `todo.okgodoit.com`'s certificate, so certbot first.

### Unverified (verbatim)

- Kestrel 10 behaves correctly with a socket-activated fd across 'systemctl restart': connections are queued and not reset when the old process closes its copy. The systemd and Kestrel APIs support it, but no primary source shows the full behaviour, and I did not test it.
- Ubuntu 22.04's systemd (249) Storage= default. The current journald.conf man page says persistent; older systemd defaulted to auto, which is persistent when /var/log/journal exists, as it does on stock Ubuntu. Check with 'journalctl --disk-usage' and 'ls /var/log/journal' on the box.
- That .NET's GC sizes its heap to the systemd MemoryMax cgroup limit on cgroup v2. This is reasoned from .NET's container support, not verified for systemd-created cgroups.
- ProtectSystem=full / ProtectHome / PrivateTmp hardening with the .NET 10 runtime and ffmpeg on this box is untested. Fall back by deleting those lines if startup fails.
- The exact on-disk path of dotnet from the Ubuntu backports PPA (assumed /usr/bin/dotnet) and of systemctl/journalctl (assumed /usr/bin/, true on merged-usr 22.04). The sudoers paths must match 'command -v systemctl journalctl' on the droplet.
- Whether the droplet's pg_hba.conf still has the default 'local all all peer', which the passwordless Unix-socket connection needs.
- Whether rsync and curl are installed on the droplet (they are on stock Ubuntu server images, but not checked).
- The UptimeRobot Free notification channels: the pricing page's free-column checkmarks were not readable. Email alerts on free are believed but not confirmed.
- Better Stack's free-tier check frequency is not stated on the pricing page.
- Whether 'dotnet-version: 10.0.x' in setup-dotnet v6 behaves identically to v5. The v6 notes list only an ESM migration and dependency bumps, and the README still documents A.B.x.

### Snippets

These use port 5080, `/opt/pebbleaudio`, `MemoryMax`, peer auth, socket activation, and cron. Per the critic, replace cron with a systemd timer and start without the `.socket` file.

**.github/workflows/deploy.yml**

```yaml
name: deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

# One deploy at a time. A newer push replaces a queued one; a running deploy is never killed.
concurrency:
  group: deploy-production
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-24.04   # ubuntu-latest moves to 26.04 between 2026-10-19 and 2026-11-19
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-dotnet@v6
        with:
          dotnet-version: '10.0.x'

      - name: Test
        run: dotnet test --configuration Release

      - name: Install deploy key and pinned host key
        env:
          DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          DEPLOY_KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
        run: |
          install -d -m 700 ~/.ssh
          printf '%s\n' "$DEPLOY_SSH_KEY" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > ~/.ssh/known_hosts
          echo "DEPLOY_SSH_KEY_FILE=$HOME/.ssh/deploy_key" >> "$GITHUB_ENV"

      - name: Deploy
        run: ./deploy/deploy.sh
```

**deploy/deploy.sh (same script from CI and from the Mac)**

```bash
#!/usr/bin/env bash
# Build, upload and activate one release of pebbleaudio.
#   ./deploy/deploy.sh                       # deploy HEAD
#   DEPLOY_HOST=134.209.0.150 ./deploy/deploy.sh
set -euo pipefail

PROJECT=src/PebbleAudio/PebbleAudio.csproj
HOST=${DEPLOY_HOST:-pebbleaudio.okgodoit.com}
DEPLOY_USER=${DEPLOY_USER:-deploy}
PUBLIC_URL=${PUBLIC_URL:-https://pebbleaudio.okgodoit.com}
KEEP=${KEEP:-5}
ROOT=/opt/pebbleaudio

cd "$(dirname "$0")/.."

sha=$(git rev-parse --short=12 HEAD)
[[ -z $(git status --porcelain) ]] || sha="$sha-dirty"
release="$(date -u +%Y%m%dT%H%M%SZ)-$sha"

ssh_cmd=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes)
if [[ -n ${DEPLOY_SSH_KEY_FILE:-} ]]; then
  ssh_cmd+=(-i "$DEPLOY_SSH_KEY_FILE" -o IdentitiesOnly=yes)
fi
remote="$DEPLOY_USER@$HOST"

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

echo "==> publish $release"
dotnet publish "$PROJECT" -c Release -r linux-x64 --self-contained false \
  -p:UseAppHost=false -o "$out" --nologo
printf '%s\n' "$release" > "$out/release.txt"

echo "==> upload"
link=()
if "${ssh_cmd[@]}" "$remote" test -d "$ROOT/current/"; then
  link=(--link-dest="$ROOT/current/")   # unchanged files are hard-linked, not re-sent
fi
# Flags limited to what macOS openrsync supports.
rsync -az --delete --chmod=D755,F644 -e "${ssh_cmd[*]}" ${link[@]+"${link[@]}"} \
  "$out/" "$remote:$ROOT/releases/$release/"

echo "==> activate"
"${ssh_cmd[@]}" "$remote" bash -s -- "$release" "$KEEP" <<'REMOTE'
set -euo pipefail
release=$1 keep=$2
cd /opt/pebbleaudio
previous=$(readlink current || true)

swap() { ln -sfn "$1" current.next && mv -T current.next current; }
healthy() {
  for _ in $(seq 1 30); do
    if body=$(curl -fsS --max-time 2 http://127.0.0.1:5080/healthz 2>/dev/null) \
       && [[ $body == *"$1"* ]]; then return 0; fi
    sleep 1
  done
  return 1
}

swap "releases/$release"
sudo /usr/bin/systemctl restart pebbleaudio.service || true   # Type=notify: fails if startup fails
if ! healthy "$release"; then
  echo "!! $release failed its health check; last log lines:" >&2
  sudo /usr/bin/journalctl -u pebbleaudio.service -n 80 --no-pager >&2 || true
  if [[ -n $previous ]]; then
    swap "$previous"
    sudo /usr/bin/systemctl restart pebbleaudio.service || true
    echo "!! rolled back to ${previous#releases/}" >&2
  fi
  exit 1
fi

# Keep the newest $keep releases, never the live one.
live=$(readlink current)
ls -1d releases/*/ | sed 's:/$::' | sort -r | tail -n +"$((keep + 1))" |
  while read -r dir; do [[ $dir == "$live" ]] || rm -rf -- "$dir"; done
echo "==> live on the box: $release"
REMOTE

echo "==> public check"
curl -fsS --max-time 10 "$PUBLIC_URL/healthz" | grep -q "$release"
echo "deployed $release"
```

**/etc/systemd/system/pebbleaudio.service**

```ini
[Unit]
Description=Pebble Audio conversation archive
Requires=pebbleaudio.socket
After=pebbleaudio.socket network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=notify
User=pebbleaudio
Group=pebbleaudio
WorkingDirectory=/opt/pebbleaudio/current
ExecStart=/usr/bin/dotnet /opt/pebbleaudio/current/PebbleAudio.dll
EnvironmentFile=/etc/pebbleaudio/pebbleaudio.env
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_NOLOGO=true
# /var/lib/pebbleaudio, owned by the service user: Data Protection keys, audio, clip cache
StateDirectory=pebbleaudio
Restart=always
RestartSec=5
# SIGTERM is what .NET's lifetime listens for (Microsoft: avoid SIGINT)
KillSignal=SIGTERM
# Startup includes MigrateAsync; READY=1 is sent once Kestrel is listening
TimeoutStartSec=120
# App ShutdownTimeout is 15 s; give it headroom before SIGKILL
TimeoutStopSec=30
SyslogIdentifier=pebbleaudio
# Protect Postgres and the other apps on the 2 GB box (includes ffmpeg children)
MemoryMax=768M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

**/etc/systemd/system/pebbleaudio.socket (systemd holds the port across restarts)**

```ini
[Unit]
Description=Pebble Audio listening socket

[Socket]
ListenStream=127.0.0.1:5080
NoDelay=true

[Install]
WantedBy=sockets.target

# Fallback if socket activation misbehaves: delete this file, remove Requires=/After= on it
# from the service, and add Environment=ASPNETCORE_URLS=http://127.0.0.1:5080 to the service.
```

**Program.cs pieces the deploy depends on**

```csharp
// dotnet add package Microsoft.Extensions.Hosting.Systemd   (10.0.13)
builder.Services.AddSystemd();                           // Type=notify + journald format; no-op off systemd
builder.WebHost.ConfigureKestrel(k => k.UseSystemd());    // listen on systemd's socket; no-op under dotnet run
builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(15));
builder.Services.AddDataProtection()
    .PersistKeysToFileSystem(new DirectoryInfo("/var/lib/pebbleaudio/keys"));

var app = builder.Build();

await using (var scope = app.Services.CreateAsyncScope())
    await scope.ServiceProvider.GetRequiredService<ArchiveDb>().Database.MigrateAsync();

var releaseFile = Path.Combine(AppContext.BaseDirectory, "release.txt");
var release = File.Exists(releaseFile) ? File.ReadAllText(releaseFile).Trim() : "dev";

app.MapGet("/healthz", async (ArchiveDb db, CancellationToken ct) =>
{
    bool dbOk;
    try
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(2));
        dbOk = await db.Database.CanConnectAsync(cts.Token);
    }
    catch { dbOk = false; }
    return Results.Json(new { status = dbOk ? "ok" : "degraded", release, db = dbOk ? "ok" : "down" },
                        statusCode: dbOk ? 200 : 503);
});

// Streaming endpoints (SSE, MCP streams) should link their token to
// IHostApplicationLifetime.ApplicationStopping so a restart drains in seconds.
```

**/etc/sudoers.d/pebbleaudio-deploy (no '.' in the filename; install after visudo -cf)**

```text
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart pebbleaudio.service, /usr/bin/journalctl -u pebbleaudio.service -n 80 --no-pager
```

**~deploy/.ssh/authorized_keys**

```text
restrict ssh-ed25519 AAAA...ci-key... github-actions-pebbleaudio-deploy
restrict ssh-ed25519 AAAA...mac-key... roger-mac
```

**/etc/systemd/journald.conf.d/50-size.conf (system-wide: check journalctl --disk-usage and existing drop-ins first)**

```ini
[Journal]
SystemMaxUse=1G
SystemKeepFree=2G
MaxRetentionSec=3month
# apply: systemctl restart systemd-journald
```

**/usr/local/sbin/pebbleaudio-watchdog + /etc/cron.d/pebbleaudio**

```bash
#!/usr/bin/env bash
# Restart pebbleaudio when it stops answering; tell Healthchecks.io when it is fine.
set -u
[[ -r /etc/pebbleaudio/watchdog.env ]] && . /etc/pebbleaudio/watchdog.env   # HC_PING_URL=https://hc-ping.com/<uuid>
state=/run/pebbleaudio-watchdog.failures

curl -sS -o /dev/null --max-time 5 http://127.0.0.1:5080/healthz
rc=$?
if (( rc == 0 )); then
  echo 0 > "$state"
  # healthz answered (200 or 503); ping with the HTTP outcome via a second, cheap request
  if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:5080/healthz; then
    [[ -n ${HC_PING_URL:-} ]] && curl -fsS -o /dev/null -m 10 "$HC_PING_URL" || true
  else
    logger -t pebbleaudio-watchdog "healthz degraded (database?) - not restarting"
    [[ -n ${HC_PING_URL:-} ]] && curl -fsS -o /dev/null -m 10 "$HC_PING_URL/fail" || true
  fi
  exit 0
fi

# rc 7 = refused, 28 = timeout, etc.: the process is not answering
n=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$state"
logger -t pebbleaudio-watchdog "healthz unreachable (curl rc=$rc, $n in a row)"
if (( n >= 3 )); then
  logger -t pebbleaudio-watchdog "restarting pebbleaudio"
  systemctl restart pebbleaudio.service
  echo 0 > "$state"
fi

# ---- /etc/cron.d/pebbleaudio ----
# * * * * * root /usr/local/sbin/pebbleaudio-watchdog
```

**deploy/server/setup.sh (run as root on the droplet; idempotent; files live in the repo)**

```bash
#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

id pebbleaudio &>/dev/null || useradd --system --home-dir /var/lib/pebbleaudio --shell /usr/sbin/nologin pebbleaudio
id deploy &>/dev/null || useradd --create-home --shell /bin/bash deploy

install -d -o deploy -g deploy -m 755 /opt/pebbleaudio /opt/pebbleaudio/releases
install -d -o deploy -g deploy -m 700 ~deploy/.ssh
install -o deploy -g deploy -m 600 "$here/deploy_authorized_keys" ~deploy/.ssh/authorized_keys

install -d -m 750 /etc/pebbleaudio
[[ -f /etc/pebbleaudio/pebbleaudio.env ]] || install -m 600 /dev/null /etc/pebbleaudio/pebbleaudio.env
# pebbleaudio.env: ConnectionStrings__Default=Host=/var/run/postgresql;Database=pebbleaudio;Username=pebbleaudio

install -m 644 "$here/pebbleaudio.service" "$here/pebbleaudio.socket" /etc/systemd/system/
install -d /etc/systemd/journald.conf.d
install -m 644 "$here/journald-size.conf" /etc/systemd/journald.conf.d/50-size.conf
visudo -cf "$here/sudoers-pebbleaudio-deploy"
install -m 440 "$here/sudoers-pebbleaudio-deploy" /etc/sudoers.d/pebbleaudio-deploy
install -m 755 "$here/watchdog.sh" /usr/local/sbin/pebbleaudio-watchdog
install -m 644 "$here/cron" /etc/cron.d/pebbleaudio

# Own role + database in the existing PostgreSQL 16; peer auth over the Unix socket, no password.
sudo -u postgres psql -tAc "select 1 from pg_roles where rolname='pebbleaudio'" | grep -q 1 \
  || sudo -u postgres createuser pebbleaudio
sudo -u postgres psql -tAc "select 1 from pg_database where datname='pebbleaudio'" | grep -q 1 \
  || sudo -u postgres createdb -O pebbleaudio pebbleaudio

systemctl daemon-reload
systemctl enable --now pebbleaudio.socket
systemctl enable pebbleaudio.service      # first deploy starts it
systemctl restart systemd-journald
```

## 7. Postgres backups (deferred by Roger)

Kept short; the facts and configs are preserved for later.

### Verified facts

- **Cluster state** (read-only, 2026-10-20). 16/main runs PostgreSQL 16.13-1.pgdg22.04+1. `wal_level=replica`; `archive_mode=off`, `archive_command` disabled, `archive_timeout=0`; `data_checksums=off`, `shared_buffers=128MB`, `max_wal_senders=10`. `pg_wal` is 32 MB, and nothing has ever been archived. (ssh root@pebbleaudio.okgodoit.com: psql pg_settings / pg_stat_archiver / pg_ls_waldir)
- **Neighbours.** The only other DB is `situ` (11 MB; user situ, via 127.0.0.1). `situ-backup.timer` (03:20 UTC) runs a local `pg_dump -Fc` to `/var/backups/situ`, never pruned (176 files, 147 MB), plus an uploads rsync, with nothing offsite. `situ-healthcheck.timer` runs every 5 min. domainotron.service (gunicorn) and nginx also run. The box uses systemd timers, with no crontabs. (ssh root@pebbleaudio.okgodoit.com: systemctl list-units/list-timers, /etc/systemd/system/situ-backup.{service,timer}, /opt/situ/backup-situ-db.sh)
- **Resources.** `include_dir = 'conf.d'` is at `postgresql.conf` line 817, and the directory is empty. 34 GB free of 49 GB; RAM 1963 MB (about 1326 MB available, 653 MB of 2 GB swap used); 1 vCPU; the pgdg source is configured. (ssh root@pebbleaudio.okgodoit.com: grep include_dir, df -h, free -m, nproc, ls /etc/apt/sources.list.d)
- **Restart vs reload.** `wal_level` and `archive_mode` need a restart; `archive_command` and `archive_timeout` reload. With archive on and an empty command, archiving pauses while WAL accumulates. (https://www.postgresql.org/docs/16/runtime-config-wal.html)
- **Failure mode.** Failing archiving fills `pg_wal`, and a full filesystem PANICs PostgreSQL. `archive_timeout` switches still write full 16 MB segments ("a minute or so" is reasonable). Recovery must stop after the base backup's end. (https://www.postgresql.org/docs/16/continuous-archiving.html)
- **pgBackRest status.** Declared unmaintained 2026-04-27, then continued from 2026-05-18, sponsor-funded (AWS, Supabase, pgEdge, Percona, Tiger Data, and others). Releases: 2.59.0 (07-20), 2.59.1 (08-17), 2.59.2 (09-27), 2.59.3 (10-04), 2.60.0 (10-18). The repo is not archived. (https://pgbackrest.org/news.html)
- **pgdg package.** `pgbackrest 2.59.3-1.pgdg22.04+1` for jammy (2026-10-05; no 2.60.0 yet). Depends on libzstd1, lz4, and libssh2. Ships `/etc/pgbackrest.conf`, logrotate config, the postgres-owned 0750 `/var/lib/pgbackrest`, `/var/spool/pgbackrest`, and `/var/log/pgbackrest`, and a not-enabled `pgbackrest.service` (TLS server). (https://apt.postgresql.org/pub/repos/apt/pool/main/p/pgbackrest/)
- **Recent changes.** 2.59.3 fixes weak encryption subkeys and salts. Since 2.59.0 only `restore` may run as root. 2.60.0 adds `checksum-page-error` (moot with checksums off). (https://pgbackrest.org/news.html)
- **Config.** `/etc/pgbackrest/pgbackrest.conf`, falling back to `/etc/pgbackrest.conf`. Defaults: `compress-type gz` (zst level 3), `process-max 1`, `archive-async off`, `spool-path /var/spool/pgbackrest`. `repo-s3-uri-style` is host or path, and `repo-retention-full-type` is count or time (days). WAL beyond `archive-push-queue-max` is dropped and reported as success (PITR breaks, PostgreSQL stays up). (https://pgbackrest.org/configuration.html)
- **Commands.** Any option works as `PGBACKREST_<UPPER_SNAKE>`. Restore takes `--type=time --target`, `--target-action` (pause/promote/shutdown), `--set`, `--repo`, `--delta`, `--db-include` (other DBs come back zeroed and sparse), and `--archive-mode`. `verify` checks backups and WAL; `check` forces a WAL switch. (https://pgbackrest.org/command.html)
- **User guide.** `archive_command='pgbackrest --stanza=<name> archive-push %p'`, `archive_mode=on`, restart, then `stanza-create` and `check` as postgres. Multi-repo archive-push writes to all repos (an unreachable repo works well only with `archive-async=y`). PITR is `restore --delta --type=time "--target=<ts with tz>" --target-action=promote`. Encryption is aes-256-cbc, with the passphrase from `openssl rand -base64 48` and fixed after `stanza-create`. (https://pgbackrest.org/user-guide.html)
- **R2.** 2.57.0 added 408 and 429 retries: "429 errors are common on Cloudflare R2". (https://pgbackrest.org/release.html)
- **B2.** Works via S3 since a 2020 fix (for example `s3.eu-central-003.backblazeb2.com`, uri-style path). (https://github.com/pgbackrest/pgbackrest/issues/1039)
- **Backblaze B2 pricing.** $6.95/TB/month, the first 10 GB free, egress free to 3x storage (then $0.01/GB), Class A/B/C calls free, Class D free to 2,500 a day (then $0.004 per 10,000), and no minimums. (https://www.backblaze.com/cloud-storage/pricing)
- **Cloudflare R2 pricing.** $0.015/GB-month, Class A $4.50/M, Class B $0.36/M, free egress. Free tier: 10 GB-month, 1M A, 10M B. IA has no free tier and a 30-day minimum. (https://developers.cloudflare.com/r2/pricing/)
- **DO Spaces.** $5/month for 250 GiB and 1 TiB out, then $0.02/GiB stored and $0.01/GiB transferred; cold storage $0.007/GiB; no free tier. (https://www.digitalocean.com/pricing/spaces-object-storage)
- **WAL-G.** v3.0.9 (2026-08-20) ships GitHub binaries only (`wal-g-pg-22.04-amd64`), not pgdg, so no apt updates. (https://github.com/wal-g/wal-g/releases/tag/v3.0.9)
- **pg_dump.** `pg_dump -Fc` is consistent while in use and omits roles and tablespaces (`pg_dumpall` covers those). `--no-owner` is ignored for archive formats; pass it to `pg_restore`. (https://www.postgresql.org/docs/16/app-pgdump.html)

### Recommendations

- **Tool and repos.** pgBackRest 2.59.3 from pgdg, with one cluster-wide stanza `main`. repo1 is local posix (fast restores, and archiving survives offsite outages); repo2 is Backblaze B2, encrypted. That is $0 at about 40 MB, and a different vendor than DO. R2 is second (429 history); Spaces is the weakest (same account, $5/month).
- **Enable.** The drop-in `conf.d/50-archiving.conf`, then one restart of `postgresql@16-main` (situ bounces). Order: install → conf plus a 0600 `conf.d/secrets.conf` → `stanza-create` → restart → `check` → full backups to repo1, then repo2 → `info`. Don't enable `pgbackrest.service`.
- **Secrets.** `repo2-cipher-pass` and the bucket-scoped B2 key go in Roger's password manager, not the app's token store.
- **Schedule (systemd timers).** Daily fulls to both repos at 03:40 UTC, `Persistent=true`. A weekly `--repo=2 verify`. A nightly 03:30 `pg_dump -Fc` plus `pg_dumpall --globals-only` for our DB, kept 14 days. Move to weekly full plus daily diff past about 1 GB.
- **Alerts.** Last WAL archived more than 15 min ago, a rising `failed_count`, or the last repo2 backup older than 26 h.
- **Drills and recovery.** A side restore from repo2 to port 5433 with `--archive-mode=off`, after setup and then quarterly. Single-app recovery uses `--db-include=pebbleaudio` on a side restore, then dump and restore; never PITR in place (that rewinds situ). Disaster recovery: a new VM plus `--repo=2 --delta restore`.
- **Tell Roger.** situ gets PITR and offsite for free. situ's dumps are never pruned. Audio files and situ uploads need their own offsite sync (for example rclone to B2 under another prefix).

### Risks

- PITR is cluster-wide.
- Enabling archive mode restarts the shared cluster.
- Failing archive-push fills `pg_wal` and PANICs, so `archive-push-queue-max=4GiB` trades PITR for uptime and must be alerted on.
- B2 outages can gap the offsite WAL chain until the next repo2 full.
- A lost cipher passphrase means lost offsite backups.
- Memory is tight, so keep the drill instance small.
- pgBackRest's governance wobbled in 2026; WAL-G is the fallback.
- `checksum-page-error` arrives with 2.60.0.
- Timers must run as `User=postgres`.
- R2 has a 429 history.
- Spaces shares the DO account.
- Files on disk aren't covered.

### Critic flags

- **Prerequisites (gap).** The B2 account, bucket, and key, the passphrase custody, and the restart OK are all on Roger, and nobody designed offsite backup for the audio files.
- **Backup status in health (gap).** `pgbackrest info` must run as postgres, and `pg_stat_archiver` needs `pg_monitor`, so use a status-file timer or `GRANT pg_monitor`.

### Unverified (verbatim)

- Exact pgBackRest CPU and RAM use for archive-push and backup on 1 vCPU / 2 GB: no authoritative numbers found. Expected small at this data size (about 40 MB), but measure the first backup with /usr/bin/time -v.
- Whether stanza-create succeeds before archive_mode is turned on. I believe it does (check is the step that needs archiving), but I did not confirm it in the fetched docs. If it fails, enable archiving first, accept a few minutes of failed archive-push, then run stanza-create.
- The default config-include-path of /etc/pgbackrest/conf.d was not confirmed on the fetched configuration page. If it is wrong, set config-include-path explicitly or put the secrets in the main file at 0640 root:postgres.
- The exact B2 S3 endpoint and region string for the bucket Roger creates (format s3.<region>.backblazeb2.com, region e.g. us-west-004). The format comes from a pgBackRest issue, not current Backblaze docs.
- Whether an idle PG16 server skips the forced switch at archive_timeout when no WAL was written, and how small a mostly empty 16 MB segment gets with zst. Both affect archive volume only slightly at this scale.
- How pgBackRest async archive-push accounts for a repo that is down while the other succeeds (whether it holds WAL for the failed repo or leaves a gap). The user guide only says it works well with archive-async=y.
- Whether DigitalOcean droplet backups or snapshots are enabled on this droplet: not visible from inside the VM.
- Whether pg_stat_archiver is readable by the app's non-superuser role without pg_monitor. Grant pg_monitor if the health endpoint needs it.
- The 2.60.0 release notes were read, but the configuration and command pages fetched did not yet list checksum-page-error or archive-expire-before. The docs pages may lag behind the release notes.

### Snippets

**/etc/postgresql/16/main/conf.d/50-archiving.conf**

```ini
# Cluster-wide WAL archiving via pgBackRest (covers every database on 16/main).
# archive_mode needs a restart: systemctl restart postgresql@16-main
archive_mode = on
archive_command = 'pgbackrest --stanza=main archive-push %p'
archive_timeout = 300
# wal_level is already 'replica' (default); leave it.
```

**/etc/pgbackrest/pgbackrest.conf**

```ini
[global]
# repo1: local, fast restores; keeps archiving alive if offsite is down
repo1-type=posix
repo1-path=/var/lib/pgbackrest
repo1-retention-full=7
repo1-bundle=y

# repo2: Backblaze B2 (S3 API), encrypted client-side
repo2-type=s3
repo2-s3-endpoint=s3.<b2-region>.backblazeb2.com
repo2-s3-region=<b2-region>
repo2-s3-bucket=<bucket>
repo2-s3-uri-style=path
repo2-path=/do-droplet-pg16-main
repo2-retention-full-type=time
repo2-retention-full=30
repo2-bundle=y
repo2-cipher-type=aes-256-cbc

compress-type=zst
process-max=1
start-fast=y
archive-async=y
spool-path=/var/spool/pgbackrest
archive-push-queue-max=4GiB
log-level-console=info
log-level-file=info

[main]
pg1-path=/var/lib/postgresql/16/main

# /etc/pgbackrest/conf.d/secrets.conf  (chown postgres:postgres; chmod 600)
# [global]
# repo2-s3-key=<B2 keyID scoped to bucket>
# repo2-s3-key-secret=<B2 applicationKey>
# repo2-cipher-pass=<openssl rand -base64 48>
```

**systemd units (ops/systemd/)**

```ini
# pgbackrest-backup.service
[Unit]
Description=pgBackRest full backup of cluster 16/main (local + B2)
After=postgresql@16-main.service
[Service]
Type=oneshot
User=postgres
ExecStart=/usr/bin/pgbackrest --stanza=main --repo=1 --type=full backup
ExecStart=/usr/bin/pgbackrest --stanza=main --repo=2 --type=full backup

# pgbackrest-backup.timer
[Timer]
OnCalendar=*-*-* 03:40:00 UTC
Persistent=true
[Install]
WantedBy=timers.target

# pgbackrest-verify.service / .timer (weekly)
# ExecStart=/usr/bin/pgbackrest --stanza=main --repo=2 verify   OnCalendar=Sun *-*-* 05:00:00 UTC

# pebbleaudio-dump.service (User=postgres) ExecStart=/opt/pebbleaudio/ops/pg-dump.sh ; timer 03:30 UTC
#!/usr/bin/env bash
set -euo pipefail
d=/var/backups/pebbleaudio; ts=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$d"
pg_dump -Fc -f "$d/pebbleaudio-$ts.dump" pebbleaudio
pg_dumpall --globals-only > "$d/globals-$ts.sql"
find "$d" -type f -mtime +14 -delete
```

**First-time enable sequence**

```bash
apt-get install -y pgbackrest            # 2.59.3 from pgdg (jammy)
install -d -o postgres -g postgres -m 750 /etc/pgbackrest /etc/pgbackrest/conf.d
# write pgbackrest.conf + conf.d/secrets.conf (0600)
sudo -u postgres pgbackrest --stanza=main --log-level-console=info stanza-create
install -o postgres -g postgres -m 644 50-archiving.conf /etc/postgresql/16/main/conf.d/
systemctl restart postgresql@16-main     # bounces situ for a few seconds
sudo -u postgres pgbackrest --stanza=main --log-level-console=info check
sudo -u postgres pgbackrest --stanza=main --repo=1 --type=full backup
sudo -u postgres pgbackrest --stanza=main --repo=2 --type=full backup
sudo -u postgres pgbackrest info
systemctl enable --now pgbackrest-backup.timer pgbackrest-verify.timer pebbleaudio-dump.timer
```

**Restore drill (side restore from offsite, live cluster untouched)**

```bash
D=/var/lib/postgresql/drill
sudo -u postgres install -d -m 700 $D
sudo -u postgres pgbackrest --stanza=main --repo=2 --pg1-path=$D \
  --type=time "--target=2026-10-20 12:00:00+00" --target-action=promote \
  --archive-mode=off restore            # add --db-include=pebbleaudio for a single-app recovery
sudo -u postgres cp /etc/postgresql/16/main/pg_hba.conf /etc/postgresql/16/main/pg_ident.conf $D/
sudo -u postgres tee $D/postgresql.conf >/dev/null <<EOF
port = 5433
listen_addresses = ''
unix_socket_directories = '/tmp'
shared_buffers = 32MB
max_connections = 10
archive_mode = off
hba_file = '$D/pg_hba.conf'
ident_file = '$D/pg_ident.conf'
EOF
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D $D -l /tmp/drill.log start
sudo -u postgres psql -h /tmp -p 5433 -XAtc 'select pg_is_in_recovery()'   # wait for f
sudo -u postgres psql -h /tmp -p 5433 -d pebbleaudio -c 'select max(updated_at) from <table>'  # <= target
# single-app recovery: pg_dump -h /tmp -p 5433 -Fc pebbleaudio > /tmp/pa.dump ; pg_restore -O --clean -d pebbleaudio /tmp/pa.dump
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D $D stop -m fast
rm -rf $D
```

## 8. Apple universal links and iOS 27 App Intents

### Verified facts

**Universal links: setup**

- **Two halves.** An apple-app-site-association (AASA) file on the site, and the Associated Domains entitlement in every app it lists. (https://developer.apple.com/documentation/xcode/supporting-associated-domains)
- **Entitlement.** `com.apple.developer.associated-domains` is an array of `<service>:<fully qualified domain>` (`applinks` for universal links): no path, query, or trailing slash. `*.` matches subdomains, and each specific subdomain needs its own entry and AASA. (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.associated-domains)
- **No ports.** `applinks:example.com:8080` will not open the app. (https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links)
- **Serving.** The file `apple-app-site-association` (no extension) at `https://<fully qualified domain>/.well-known/apple-app-site-association`, over https with a valid certificate and no redirects (301 and 302 are unsupported). (https://developer.apple.com/documentation/xcode/supporting-associated-domains)
- **Access.** Reachable from all IPs and geographies, accepting any User-Agent (that policy was added 2025-05-15). A 403 or 404 means access denied, and Apple publishes no CDN IP ranges. (https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links)

**Universal links: format**

- **AASA format.** `{"applinks":{"details":[{"appIDs":["<AppIDPrefix>.<BundleID>",...],"components":[...]}]}}`. `appID` (string) and `appIDs` (array) are both accepted, but don't mix appIDs/components with the legacy appID/paths format. (https://developer.apple.com/documentation/bundleresources/applinks/details-swift.dictionary)
- **Components.** `/` (path), `?` (query: a string pattern or a dictionary of name → pattern), and `#` (fragment), each defaulting to `*`. Options: `exclude` (false), `comment`, `caseSensitive` (true), and `percentEncoded` (true). Wildcards: `*` is zero or more, `?` exactly one, `?*` one or more. The first match wins, all specified components must match, and iOS 13+ is required. (https://developer.apple.com/documentation/bundleresources/applinks/details-swift.dictionary/components-swift.dictionary)
- **Query dictionaries.** Keys are NSURLQueryItem names; for example `"?": { "productID": "12345" }`, and Apple's `"?": { "articleNumber": "????" }` requires exactly four characters. (https://developer.apple.com/documentation/bundleresources/applinks/details-swift.dictionary/components-swift.dictionary/query)

**Universal links: CDN, modes, and debugging**

- **Apple's CDN.** Since iOS 14 and macOS 11, devices get the AASA from Apple's CDN, which fetches within 24 h. Devices download at install and check about weekly, a reinstall refreshes, and there is no invalidation. (https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links)
- **CDN endpoint.** `https://app-site-association.cdn-apple.com/a/v1/<domain>`. On 2026-10-20 www.apple.com returned 200, `application/json`, `Cache-Control max-age=21600`, and `Apple-From`; pebbleaudio.okgodoit.com returns 404. (https://app-site-association.cdn-apple.com/a/v1/www.apple.com)
- **Developer mode.** `?mode=developer` (or `managed`, `developer+managed`), for example `applinks:host?mode=developer`, skips the CDN and accepts any SSL certificate. It works for development-signed apps only, on opted-in devices. (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.associated-domains)
- **Mode restrictions.** Not for App Store or TestFlight builds, and the AASA must be in `/.well-known`. The opt-in is Settings > Developer > Associated Domains Development (Mac: `swcutil developer-mode -e true`). WWDC20 adds the developer entry alongside the normal one. (https://developer.apple.com/videos/play/wwdc2020/10098/)
- **Paid program.** Associated Domains needs ADP or ADEP membership; the free tier lacks it (and iCloud, Push, and Siri), while App Groups works on all tiers. (https://developer.apple.com/help/account/reference/supported-capabilities-ios)
- **This project.** It uses `DEVELOPMENT_TEAM R73F7TNT65` with automatic signing and has iCloud container entitlements (paid-only), so the team is likely paid. Both deploy modes are development-signed (`xcodebuild build -allowProvisioningUpdates`; Debug `dev.audiocompanion.app.dev`, Release `dev.audiocompanion.app`), so both qualify for `?mode=developer`. (file:///Users/roger/Repos/pebble/pebble-audio-companion/ios/project.yml)
- **Debugging.** Settings > Developer > Universal Links > Diagnostics. `sudo swcutil dl -d <domain>`, and `sudo swcutil verify -d <domain> -j <file> -u <URL>` ("Pattern ... matched" or "blocked match"). A sysdiagnose's `swcutil_show.txt` shows "Site/Fmwk Approval" (approved, unspecified, denied) and check times. A long-press on a link in Notes shows whether the app is offered. (https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links)

**Universal links: in the app**

- **Delivery.** An `NSUserActivity` of type `NSUserActivityTypeBrowsingWeb` with `webpageURL`, via `scene(_:willConnectTo:)`, `scene(_:continue:)`, or SwiftUI `onContinueUserActivity`. Apple calls universal links an attack vector: validate every parameter, and never let a link delete content or reach sensitive data directly. (https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app)
- **When they don't fire.** URLs typed into Safari, and same-domain links tapped inside Safari. Links from other apps and cross-domain links do fire. (https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content)
- **Size limit.** A 128 KB AASA limit appears only in an archived 2016 revision note. (https://developer.apple.com/library/archive/documentation/General/Conceptual/AppSearch/RevisionHistory.html)
- **Wrong certificate.** On 2026-10-20 the name presented `CN=todo.okgodoit.com`, with a non-matching subjectAltName. A Let's Encrypt cert for the name is a prerequisite. (https://pebbleaudio.okgodoit.com/.well-known/apple-app-site-association)

**App Intents, Spotlight, and Siri**

- **IndexedEntity** (iOS 18.0+) refines `AppEntity` into the Spotlight index, making it discoverable by Apple Intelligence. Its properties have defaults (`attributeSet`, `defaultAttributeSet`, `hideInSpotlight`). (https://developer.apple.com/documentation/appintents/indexedentity)
- **Indexing keys.** `@Property`, `@ComputedProperty`, and `@DeferredProperty` take `indexingKey:` (for example `\.contentDescription`) or `customIndexingKey:`. `EntityProperty.init(indexingKey:)` is iOS 18.4+. A wrapped value beats `attributeSet`, and `displayRepresentation`'s title, subtitle, and image beat `attributeSet`. Deferred values resolve during indexing. (https://developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight)
- **indexAppEntities.** `CSSearchableIndex.indexAppEntities(_:priority:)` (iOS 18.0+, async throws, priority 0) is not recursive, and re-indexing an id updates it. Indexing both a `CSSearchableItem` and an entity duplicates; use `associateAppEntity(_:priority:)`. Use a named index (the default is for prototyping). (https://developer.apple.com/documentation/corespotlight/cssearchableindex/indexappentities(_:priority:))
- **IndexedEntityQuery.** `reindexEntities(for:indexDescription:)` and `reindexAllEntities(indexDescription:)` are iOS 27.0+, and unneeded if a `CSSearchableIndexDelegate` already reindexes. (https://developer.apple.com/documentation/appintents/indexedentityquery)
- **WWDC26 session 344.** Removal is `deleteAppEntities` with the id and type. An `OpenIntent` adopting `.system.open` is called when someone taps an entity result in Spotlight or Siri, or asks Siri to open it. (https://developer.apple.com/videos/play/wwdc2026/344/)
- **`.system` schemas** (iOS 27.0+, Siri and Shortcuts). `.system.open` uses `OpenIntent` with `var target: any AppEntity`. `.system.searchInApp` uses `ShowInAppSearchResultsIntent` with `searchScopes` and `criteria: StringSearchCriteria`. The `.system` domain "applies broadly". (https://developer.apple.com/documentation/appintents/app-schema-domain-system-and-in-app-search)
- **Deprecation.** `.system.search` (iOS 18.0) is deprecated in 27.0: "Use .system.searchInApp instead". (https://developer.apple.com/documentation/appintents/appschema/systemintent/search)
- **IntentDialog.** `IntentDialog(full:supporting:)` (iOS 16+): `full` is "a standalone message that fully describes the output", and `supporting` is "a message that may be used in conjunction with visual output". Session 343: Siri shows `supporting` with UI and reads `full` on AirPods. (https://developer.apple.com/videos/play/wwdc2026/343/)
- **Siri AI may hide output.** When Siri AI runs an intent, "the system might not display" the dialog or snippet. The default card comes from `displayRepresentation`, and `ShowsSnippetView` (iOS 16+) replaces it. (https://developer.apple.com/documentation/appintents/showssnippetview)
- **Notification entities.** `UNMutableNotificationContent.appEntityIdentifiers` (`[EntityIdentifier]`) is iOS 27.0+ and gives Siri entity context on AirPods announcements. `TransientAppEntity` is excluded. (https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent/appentityidentifiers)
- **Schemas required (session 240).** An entity alone is "not enough for Siri to be able to find it or talk about it… your entity needs to conform to an AppSchema". Q&A comes from "conforming your schematized entity to the IndexedEntity protocol", after which "Siri can search your content, reason over it, and use it to answer questions". `EntityStringQuery` is the non-semantic fallback. (https://developer.apple.com/videos/play/wwdc2026/240/)
- **Schema properties only.** Apple Intelligence uses only schema-defined properties; extras must be optional and are seen only by Shortcuts. Adopt schemas only where content genuinely matches. Journaling, Files, and Reader "don't make your conforming types discoverable by Apple Intelligence and Siri". (https://developer.apple.com/documentation/appintents/making-actions-and-content-discoverable-by-apple-intelligence)
- **`.notes.note`** (iOS 27.0+): `name: AttributedString`, `content: AttributedString?`, `attachments: [IntentFile]`, `isPinned`, `creationDate`, `modificationDate`, and `folder`. (https://developer.apple.com/documentation/appintents/appschema/notesentity/note)
- **Use Model (WWDC25).** It passes "a JSON representation of your entity to the model", with all Shortcuts-exposed properties as strings, so expose reasoning data as `@Property`. Models: on-device, PCC, or ChatGPT. Rich-text output, plus Follow Up. (https://developer.apple.com/videos/play/wwdc2025/260/)
- **Use Model (WWDC26 session 310).** Stronger models with web access. A transcript inspector (Show Content on Transcript) shows the entities and properties the model saw. The demo pipes an EntityPropertyQuery "Find" into Use Model. (https://developer.apple.com/videos/play/wwdc2026/310/)
- **Apple Intelligence devices (iOS 27).** "available on iPhone 16 models or later, iPhone 15 Pro, iPhone 15 Pro Max, iPhone Air". Supported matching device and Siri languages are required, mainland-China devices are excluded, and 8-14 GB must be free. (https://support.apple.com/en-us/121115)

### Recommendations

- **AASA.** appIDs `R73F7TNT65.dev.audiocompanion.app` and `R73F7TNT65.dev.audiocompanion.app.dev` (the side-by-side build is a separate App ID), with one component `{"/":"/c/*","?":{"t":"?*"}}` (`?*` so the token is non-empty). Confirm the App ID prefix in the portal.
- **Serving it.** From a Minimal API built from config, or `location = /.well-known/apple-app-site-association` with `default_type application/json`. A direct 200: no redirect, auth, UA filtering, or IP allowlist. certbot first.
- **Entitlements.** Both `applinks:pebbleaudio.okgodoit.com` and `applinks:pebbleaudio.okgodoit.com?mode=developer`, with the device toggle on.
- **Verify.** `swcutil dl`, then `swcutil verify` for `https://pebbleaudio.okgodoit.com/c/abc?t=xyz`, the on-device Diagnostics, and the CDN URL. Tap from Notes or Messages; never type into Safari.
- **Security.** `/c/*` links are hostile input: validate the id and token, never allow deletes or auth bypass, and keep tokens out of logs.
- **iOS 27 paths.** An `IndexedEntity` conversation with `@Property(indexingKey: \.contentDescription)` keys in a named index, plus `deleteAppEntities` on tombstones. An `OpenIntent` (`.system.open`), a `ShowInAppSearchResultsIntent` (`.system.searchInApp`), and `appEntityIdentifiers` on notifications.
- **Siri Q&A.** It needs a schema, and the only fit is `.notes.note`. Use it only if a conversation honestly is a note; otherwise expect Spotlight plus open and search.
- **Use Model.** A Find Conversations action (EntityPropertyQuery, or `ReturnsValue<[ConversationEntity]>`) with transcript and summary in `@Property` fields.
- **Dialog.** `full` must stand alone for AirPods; don't rely on dialogs or snippets under Siri AI, and keep `displayRepresentation` meaningful.
- **Availability gating.** The target is iOS 26.0, so put every iOS 27 symbol behind `if #available(iOS 27, *)`, and never in stored properties of types that load on 26.

### Risks

- The paid team is inferred, not checked in the portal.
- CDN caching and no invalidation make edits look broken for days without developer mode.
- Any redirect, auth wall, bot challenge, filter, or wrong certificate silently disables links, and the name serves the wrong certificate today.
- No firing from Safari, so the `/c/*` viewer must work in a browser.
- Apple Intelligence needs an iPhone 15 Pro, 16 or later, or Air on iOS 27 with matching languages, and no mainland-China device.
- Siri AI may hide dialogs and snippets.
- Without a fitting schema there is no Siri reasoning, and forcing `.notes.note` contradicts Apple's guidance and brings Notes expectations.

### Critic flags

- **Token-free citations.** Citation URLs are token-free, login-required `/c/{id}`; share-token `/c/{id}?t=` links are a separate, explicit feature, so tokens never reach ChatGPT or Claude transcripts.
- **iOS 27 stays client-side (gap).** iOS 27 items stay behind `#available`, and nothing server-side depends on them. Universal links and the AASA work on iOS 26.

### Unverified (verbatim)

- The Content-Type requirement (application/json) is not stated in current Apple docs, TN3155, or WWDC20 10098. It is a long-standing convention, and Apple's CDN serves its own copy as application/json. Recommended, but not confirmed as mandatory.
- The 128 KB size limit appears only in a 2016 archived Apple revision note and in third-party sources; current docs do not mention a size limit.
- Whether a query-dictionary pattern '*' (zero or more characters) also matches a URL with the t query item absent. Apple docs do not say. Using '?*' sidesteps the question but was not tested with swcutil against a live file.
- Console.app filtering for universal links (the swcd process / com.apple.swc subsystem) is not documented in the Apple sources fetched. Only swcutil, sysdiagnose swcutil_show.txt, and the on-device Diagnostics screen are Apple-documented.
- Whether Siri AI can answer free-form questions over IndexedEntity entities that have no schema. Session 240 implies no (a schema is required for Siri to find or talk about an entity), but no Apple page states the non-schema case outright.
- Use Model's device and model requirements on iOS 27 (which models need Apple Intelligence hardware, and ChatGPT availability in 2026) were not stated in WWDC26 session 310.
- Whether the developer portal App ID prefix for dev.audiocompanion.app equals Team ID R73F7TNT65, and whether both App IDs will get the Associated Domains capability automatically via -allowProvisioningUpdates. This is expected but not run.
- WWDC26 session 343 says '.system search schema introduced in iOS 17', but the docs list .system.search as iOS 18.0, so the session statement may be a misstatement.

### Snippets

**apple-app-site-association for pebbleaudio.okgodoit.com**

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": [
          "R73F7TNT65.dev.audiocompanion.app",
          "R73F7TNT65.dev.audiocompanion.app.dev"
        ],
        "components": [
          { "/": "/c/*", "?": { "t": "?*" }, "comment": "Conversation share links with a non-empty token" }
        ]
      }
    ]
  }
}
```

**App.entitlements addition**

```xml
<key>com.apple.developer.associated-domains</key>
<array>
  <string>applinks:pebbleaudio.okgodoit.com</string>
  <string>applinks:pebbleaudio.okgodoit.com?mode=developer</string>
</array>
```

**nginx location (if not served by the app)**

```nginx
location = /.well-known/apple-app-site-association {
    default_type application/json;
    alias /srv/pebbleaudio/current/wwwroot/.well-known/apple-app-site-association;
    # no auth, no redirect, no UA/IP filtering
}
```

**Verification commands**

```bash
curl -sv -A 'RandomAgent/1' https://pebbleaudio.okgodoit.com/.well-known/apple-app-site-association
sudo swcutil dl -d pebbleaudio.okgodoit.com
sudo swcutil verify -d pebbleaudio.okgodoit.com -j ./aasa.json -u 'https://pebbleaudio.okgodoit.com/c/abc?t=xyz'
curl -s https://app-site-association.cdn-apple.com/a/v1/pebbleaudio.okgodoit.com
```

**iOS 27 entity + intents sketch**

```swift
struct ConversationEntity: IndexedEntity {
  static let defaultQuery = ConversationQuery()
  var id: String
  @Property(indexingKey: \.title) var title: String
  @Property(indexingKey: \.contentDescription) var summary: String
  @Property(title: "Transcript") var transcript: String   // what Use Model sees
  var displayRepresentation: DisplayRepresentation { .init(title: "\(title)", subtitle: "\(summary)") }
}

@available(iOS 27, *)
@AppIntent(schema: .system.open)
struct OpenConversationIntent: OpenIntent {
  var target: ConversationEntity
  func perform() async throws -> some IntentResult { /* navigate */ .result() }
}

try await CSSearchableIndex(name: "Conversations").indexAppEntities(entities)

if #available(iOS 27, *) {
  content.appEntityIdentifiers = [EntityIdentifier(for: ConversationEntity.self, identifier: id)]
}

return .result(dialog: IntentDialog(full: "You talked with Sam about the lease on Tuesday.", supporting: "Tuesday with Sam"))
```

## 9. ffmpeg and Speex

### Verified facts

**What jammy ships**

- **Packages.** ffmpeg `7:4.4.1-3ubuntu5` (release) and `7:4.4.2-0ubuntu0.22.04.1` (updates/security, universe). The droplet's candidate is `7:4.4.2-0ubuntu0.22.04.1` (DO mirror), not installed. (https://launchpad.net/ubuntu/+source/ffmpeg)
- **The brief was wrong.** The native `speex` decoder first shipped in FFmpeg 5.0 (the Changelog's 5.0 section has "- speex decoder"; 4.4 has none), so jammy's 4.4.2 has NO native Speex decoder. (https://raw.githubusercontent.com/FFmpeg/FFmpeg/release/5.0/Changelog)
- **libspeex.** Jammy builds with `--enable-libspeex` (base CONFIG in debian/rules), and `libavcodec58 7:4.4.2-0ubuntu0.22.04.1` depends on `libspeex1` (confirmed with `apt-cache depends libavcodec58` on the droplet). Decoding is the `libspeex` wrapper (`AV_CODEC_ID_SPEEX`). (https://packages.ubuntu.com/jammy-updates/libavcodec58)

**How 4.4.2 reads it**

- **Demuxer.** 4.4.2 `oggparsespeex.c`: `nb_header = 2`. Packet 0 is ≥68 bytes, with rate at 36 (>0), channels at 48 (1 or 2, setting a mono/stereo layout), frame_size at 56, and frames_per_packet at 64, copied whole into extradata. Packet 1 goes through the Vorbis-comment parser. Duration is frame_size*frames_per_packet, and the last packet is trimmed by the EOS granule. (https://raw.githubusercontent.com/FFmpeg/FFmpeg/n4.4.2/libavformat/oggparsespeex.c)
- **Decoder.** 4.4.2 `libspeexdec` needs extradata ≥80 bytes, parsed by `speex_packet_to_header()` for rate, channels, and mode. It ignores frames_per_packet, decoding until fewer than 5 bits remain or a terminator. (https://raw.githubusercontent.com/FFmpeg/FFmpeg/n4.4.2/libavcodec/libspeexdec.c)

**The phone's files**

- **Speex Ogg mapping.** Packet 0 is the 80-byte LE header alone on the BOS page, granulepos 0: `'Speex   '` (8 bytes), version (char[20]), then 13 int32 fields (version_id, header_size, rate, mode, mode_bitstream_version, nb_channels, bitrate, frame_size, vbr, frames_per_packet, extra_headers, reserved1, reserved2). Packet 1 is the comment (granulepos 0). Audio starts at packet 2, granulepos is the last sample, and the last page sets EOS. (https://www.speex.org/docs/manual/speex-manual/node8.html)
- **The remuxer already matches.** `pebble-audio-companion/ios/PebbleAudioKit/Sources/AudioCodec/OggSpeex.swift` writes exactly this:
  - The header: rate 16000, mode 1, mode_bitstream_version 4, 1 channel, bitrate 9800, frame_size 320, vbr 0, frames_per_packet 1, extra_headers 0.
  - A comment page ("PebbleAudioKit", 0 comments).
  - Data pages of 254 × 25-byte packets, granule = frames × 320, EOS last, and CRC unreflected 0x04C11DB7.

  FFmpeg 4.4 and current FFmpeg (bitstream_version == 4, fpp 1..64, channels 1..2) both accept it. (https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/speexdec.c)
- **Tested.** A Python port on two real 15-min `.spxlog` segments (90,472 frames of 25 bytes) gave a 2.36 MB Ogg. FFmpeg 9.0.1 probes it as "speex, 16000 Hz, 1 channels, flt", 00:30:09.44 (exactly frames × 20 ms). (https://www.speex.org/docs/manual/speex-manual/node8.html)
- **Channel-layout gotcha (tested).** The native decoder (5.0+) leaves the layout UNSPEC, and the aac encoder fails with `Unsupported channel layout "1 channels"` unless given `-ac 1` (or `-af aformat=channel_layouts=mono`). 4.4 sets mono, but `-ac 1` is portable. (https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/speexdec.c)

**Cutting and output**

- **Input-side seek.** `-ss` before the input seeks to the previous seek point and, with `-accurate_seek` (default) while transcoding, discards up to the position. `-t` limits duration and overrides `-to`. (https://ffmpeg.org/ffmpeg.html)
- **Measured on 9.0.1.** `-ss 600.37 -i clip.ogg -t 30` and `-ss 1000.123 ... -t 10` are bit-identical from the first sample to a full decode (lag 0, 0 differing samples, 480,000 samples for 30 s), with no warm-up transient. (https://ffmpeg.org/ffmpeg.html)
- **faststart.** `-movflags +faststart` is a second pass moving moov to the front and doesn't work for fragmented output. An ffmpeg ipod-muxer `.m4a` has atoms ftyp, moov, free, mdat, brand `M4A `, AAC LC, 16000 Hz mono. (https://ffmpeg.org/ffmpeg-formats.html)
- **The aac encoder.** The native `aac` encoder is the default, `-b:a` is CBR, `aac_low` (LC) is the most compatible default, and `twoloop` is the coder. No HE-AAC (needs libfdk_aac, absent from jammy). (https://ffmpeg.org/ffmpeg-codecs.html)
- **Browsers.** AAC covers 8-96 kHz, and AAC in MP4 plays in all major browsers, so 16 kHz needs no resample. Browsers can't play Speex. (https://developer.mozilla.org/en-US/docs/Web/Media/Guides/Formats/Audio_codecs)
- **iOS media servers** must answer byte ranges (`curl --range 0-99`) and send correct MIME types. (https://developer.apple.com/library/mac/documentation/AppleApplications/Reference/SafariWebContent/CreatingVideoforSafarioniPhone/CreatingVideoforSafarioniPhone.html)

**Cost and peaks**

- **Mac cost (Apple Silicon, 9.0.1, `-threads 1`, 20-min clip, mono AAC).** 48k: 1.43 s wall / 2.1 s CPU / 7.30 MB. 32k: 1.18 s / 1.9 s / 4.90 MB. 24k: 1.59 s / 2.3 s / 3.69 MB. RSS about 20 MB. s16le decode: 0.65 s, 17 MB. Source Ogg: about 1.57 MB. (https://ffmpeg.org/ffmpeg-codecs.html)
- **Droplet.** 1 vCPU (DO-Regular), 1963 MB with about 1.3 GB available, 34 GB free, load 0.15. Simulated install: 142 packages, 113 MB download, 312 MB on disk; with `--no-install-recommends`, 70.2 MB and 217 MB. (https://launchpad.net/ubuntu/+source/ffmpeg)
- **Peaks via filters.** `asetnsamples=n=800:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.Peak_level:file=peaks.txt` gives one dBFS value per 50 ms (24,001 lines per 20 min) in 0.58 s. Piping `-f s16le -ac 1 -` to a max-abs reducer takes 0.65 s. (https://ffmpeg.org/ffmpeg-filters.html)
- **audiowaveform.** BBC's tool is not in jammy (only `ppa:chris-needham/ppa`, 1.10.2) and reads MP3, WAV, FLAC, Ogg Vorbis, and Opus, not Speex. (https://github.com/bbc/audiowaveform)
- **Native-decoder bugs.** Post-7.0 reports (trac #11495, 32 kHz UWB, later fixed) don't affect libspeex or 16 kHz. (https://ffmpeg.org/pipermail/ffmpeg-trac/2025-March/072913.html)

### Recommendations

- **Install.** `apt-get install --no-install-recommends ffmpeg` in the setup script. Smoke-test: `-decoders` lists `libspeex`, and one real clip's duration equals frameCount × 20 ms.
- **Canonical command.** File input (Ogg seeking needs it): `nice -n 10 ffmpeg -nostdin -hide_banner -v error -y [-ss START] -i in.ogg [-t DUR] -map 0:a:0 -map_metadata -1 -vn -ac 1 -c:a aac -b:a 32k -movflags +faststart -f ipod out.tmp && mv out.tmp out.m4a`. Keep 16 kHz (no `-ar`) and 32k (an admin setting; 48k only adds bytes over 9.8 kbps Speex).
- **Clips and timeline.** `-ss` before `-i`, `-t` after, so bounds come straight from transcript timestamps. Every server time uses the remux's concatenated timeline, which has no granule jumps at gaps.
- **Output.** A temp file in the destination directory, an atomic rename, and `PhysicalFile(..., enableRangeProcessing: true)` with `audio/mp4`. Behind nginx, `curl --range 0-99` must give a 206 with 100 bytes.
- **Peaks.** In the same job: a second s16le pass (or a single decode feeding both), max-abs per 800 samples → 24,000 bytes per 20 min, stored as `{sampleRate, samplesPerPeak, peaks}`. No audiowaveform.
- **Scheduling.** Concurrency 1 under `nice` (optionally `CPUWeight` or `CPUQuota`), lazily or at ingest, cached by clip id and range. Don't change the iPhone remuxer.

### Risks

- The libspeex path was verified from source, not run.
- 5.0+ needs `-ac 1`.
- The timeline ignores the watch's gaps (0.042% of frames), so it doesn't map 1:1 to the wall-clock sampleIndex.
- Droplet cost is an estimate (about 5-15 CPU-s per 20 min).
- AAC priming (1024 samples, about 64 ms) depends on edit-list support.
- Widget playback depends on the MCP Apps CSP.
- Installing recommends pulls 142 packages.

### Critic flags

- **Run it on the droplet first (gap).** Nobody has run 4.4.2 plus libspeex there against a real iPhone file, and the droplet CPU cost is unmeasured. Smoke-test before building the worker.
- **Clip serving.** Kestrel range serving (this section) beats the nginx X-Accel route (section 3).

### Unverified (verbatim)

- I did not run ffmpeg 4.4.2 + libspeex on Ubuntu 22.04 against an iPhone Ogg Speex file. Decode, -ss accuracy and the -ac 1 behaviour on 4.4 come from source reading. Every empirical result above is from FFmpeg 9.0.1 with the native decoder.
- Exact CPU time and RSS on the 1 vCPU DO-Regular droplet are unknown. My Mac numbers were 1.2-1.6 s wall, about 2 s CPU and 20 MB RSS per 20 minutes.
- Whether iOS Safari, ChatGPT's widget iframe and Claude's widget iframe all play 16 kHz mono AAC-LC m4a without problems. MDN covers 8-96 kHz AAC in general, but nobody has run an on-device test.
- Whether Safari honours the AAC priming edit list (start-offset accuracy of about 64 ms).
- The status of trac ticket #11078 (native decoder reportedly broken around 7.0). The page was blocked by bot protection, but it does not affect the libspeex path on 22.04.

### Snippets

**Post-install smoke test on the droplet**

```bash
apt-get install -y --no-install-recommends ffmpeg
ffmpeg -hide_banner -decoders | grep -i speex     # expect: A..... libspeex  libspeex Speex
ffprobe -v error -show_entries stream=codec_name,sample_rate,channels:format=duration sample.ogg
# expect codec_name=speex sample_rate=16000 channels=1, duration == frameCount * 0.02
```

**Full transcode Ogg Speex -> m4a (AAC-LC, 16 kHz mono, faststart)**

```bash
nice -n 10 ffmpeg -nostdin -hide_banner -v error -y -i in.ogg \
  -map 0:a:0 -map_metadata -1 -vn -ac 1 -c:a aac -b:a 32k \
  -movflags +faststart -f ipod out.m4a.tmp && mv out.m4a.tmp out.m4a
```

**Sample-accurate clip cut (input-side -ss, transcoding)**

```bash
ffmpeg -nostdin -v error -y -ss 600.37 -i in.ogg -t 30 \
  -map 0:a:0 -map_metadata -1 -vn -ac 1 -c:a aac -b:a 32k -movflags +faststart -f ipod clip.m4a.tmp
# Measured on 9.0.1: the decoded range is bit-identical to the same range of a full decode.
```

**Peaks from PCM (C# sketch, ffmpeg writes s16le to stdout)**

```csharp
// ffmpeg -nostdin -v error -i in.ogg -ac 1 -f s16le -   (ArgumentList, RedirectStandardOutput)
const int SamplesPerPeak = 800; // 50 ms at 16 kHz
var peaks = new List<byte>(); var buf = new byte[SamplesPerPeak * 2]; int n;
while ((n = await stdout.ReadAtLeastAsync(buf, buf.Length, throwOnEndOfStream: false, ct)) > 0) {
  int max = 0;
  for (int i = 0; i + 1 < n; i += 2) { int s = Math.Abs((int)BinaryPrimitives.ReadInt16LittleEndian(buf.AsSpan(i))); if (s > max) max = s; }
  peaks.Add((byte)Math.Min(255, max * 255 / 32767));
}
// store {sampleRate:16000, samplesPerPeak:800, peaks:[...]} — 24,000 values for 20 min
```

**Alternative: peaks via ffmpeg filters (dBFS per 50 ms)**

```bash
ffmpeg -nostdin -v error -i in.ogg -af "asetnsamples=n=800:p=0,astats=metadata=1:reset=1:measure_overall=Peak_level:measure_perchannel=none,ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=peaks.txt" -f null -
```

## 10. ChatGPT and Claude connector UX expectations

### Verified facts

**ChatGPT: instructions and the search/fetch contract**

- **Server instructions.** MCP servers can return `instructions` at initialization, and "ChatGPT and Codex use these instructions alongside tool metadata." Use them for cross-tool rules. "Keep the most important details in the first 512 characters", and don't repeat tool descriptions or change the model's personality. (https://developers.openai.com/plugins/build/mcp-server.md)
- **Refresh.** "Keep the first 512 characters self-contained." Refreshing the app in settings pulls new tools, descriptions, and instructions. Nothing is said about text past 512. (https://developers.openai.com/api/docs/guides/custom-mcp-server.md)
- **search.** Arguments: "A single query string." (`search(query: str)`). Returns: "An object with a single key, `results`, whose value is an array of result objects": `id` ("a unique ID for the document or search result item"), `title` ("human-readable title."), and `url` ("canonical URL for citation."). "In MCP, return this object as `structuredContent` and include the same value as a JSON-encoded string in the content array for compatibility." (https://developers.openai.com/api/docs/mcp.md)
- **fetch.** Arguments: "A string which is a unique identifier for the search document." (`fetch(id: str)`). Returns "A single object": `id`, `title`, `text` ("The full text of the document or item"), `url` ("a URL to the document or search result item. Useful for citing specific resources in research."), and `metadata` ("an optional key/value pairing of data about the result"), as `structuredContent` plus JSON in `content`. Sample model: `FetchOutput{id:str,title:str,text:str,url:str,metadata:dict[str,Any]|None=None}` passed as `output_schema`. (https://developers.openai.com/api/docs/mcp.md)
- **Citations.** "For both `search` results and `fetch` responses, ChatGPT creates citation metadata only when `url` is a non-empty string." "Declare an output schema for each tool so clients can validate the result shape." (https://developers.openai.com/api/docs/mcp.md)
- **Company knowledge.** "implement the standard `search` and `fetch` tool input schemas and mark other read-only tools with `readOnlyHint: true`." "Return absolute, user-openable URLs for sources that the model should cite. Keep internal document identifiers in the result's `id` field." And: "Custom MCP servers do not require `search`/`fetch` tools." (https://developers.openai.com/plugins/build/mcp-server.md)

**ChatGPT: `_meta` and result fields**

- **Tool `_meta` (verbatim).**
  - `_meta["openai/outputTemplate"]` (string URI): "OpenAI-specific optional/compatibility alias for `_meta.ui.resourceUri`".
  - `_meta["openai/widgetAccessible"]` (boolean, default false): "prefer `_meta.ui.visibility` + `tools/call`".
  - `_meta["openai/visibility"]` (`public` (default) or `private`): "prefer `_meta.ui.visibility`".
  - `_meta["openai/toolInvocation/invoking"]` (≤ 64 chars): "Short status text while the tool runs."
  - `_meta["openai/toolInvocation/invoked"]` (≤ 64 chars): "Short status text after the tool completes."
  - Also: `_meta.ui.resourceUri`, `_meta.ui.visibility` (string[], default `["model","app"]`), `_meta["openai/profile"]`, `_meta["openai/fileParams"]`, and `_meta["securitySchemes"]`.

  (https://developers.openai.com/plugins/reference.md)
- **Client `_meta` on calls.** `openai/locale` (initialize and calls; BCP 47; older: `webplus/i18n`), `openai/userAgent` ("Optional, best-effort user agent hint"), `openai/userLocation` (city, region, country, timezone, longitude, latitude), `openai/subject` ("Anonymized user id sent to MCP servers for the purposes of rate limiting and identification"), `openai/session` (anonymized conversation id), and `openai/organization` (anonymized org id). Servers "should never rely on them for authorization decisions and must tolerate their absence." (https://developers.openai.com/plugins/reference.md)
- **Result fields.** `structuredContent`: "Surfaced to the model and the component. Must match the declared `outputSchema`, when provided." `content`: "Surfaced to the model and the component." `_meta`: "Delivered only to the component. Hidden from the model." "Only `structuredContent` and `content` appear in the conversation transcript." (https://developers.openai.com/plugins/reference.md)
- **Auth and widget ids.** `_meta["mcp/www_authenticate"]` (string or string[]) on a result carries RFC 7235 challenges to trigger OAuth. The host sets `_meta["openai/widgetSessionId"]`. (https://developers.openai.com/plugins/reference.md)

**ChatGPT: confirmation and connection**

- **Confirmation.** "Write actions by default require confirmation." "We respect the `readOnlyHint` tool annotation ... Tools without this hint are treated as write actions." A choice can be remembered per tool per conversation. "New conversations will prompt for confirmation again. Refreshing the same conversation will also prompt for confirmation again on subsequent turns." (https://developers.openai.com/api/docs/guides/custom-mcp-server.md)
- **Annotations.** `readOnlyHint`, `destructiveHint`, and `openWorldHint` are Required; `idempotentHint` is Optional. `destructiveHint` means the host "knows to elicit explicit approval first". A bounded private workspace "isn't open-world solely because it is externally hosted." "These hints only influence how ChatGPT or Codex frames the tool call to the user; servers must still enforce their own authorization logic." Set all three as explicit booleans. (https://developers.openai.com/plugins/reference.md)
- **Connection.** chatgpt.com/plugins → + → **Add custom MCP server**, over SSE or streaming HTTP, with auth OAuth (CIMD with none or private_key_jwt if advertised, else DCR), No authentication, or OAuth or no authentication. Web only; invoked with @. (https://developers.openai.com/api/docs/guides/custom-mcp-server.md)
- **No numeric limits.** None are published for timeout or response size. The only guidance: "Components feel sluggish when tool calls take longer than a few hundred milliseconds." The Events sample uses `AbortSignal.timeout(10_000)`. (https://developers.openai.com/plugins/deploy/troubleshooting.md)

**Claude**

- **Limits.** claude.ai and Desktop: "~150,000 characters" per result and "240 seconds per tool call". Claude Code: 25,000 tokens (`MAX_MCP_OUTPUT_TOKENS`), with the timeout set via `MCP_TOOL_TIMEOUT`. Supported: tools, prompts, resources, text and image results, and text and binary resources. Not supported: resource subscriptions, sampling, and advanced/draft capabilities. Transport is Streamable HTTP (legacy HTTP+SSE deprecated). (https://claude.com/docs/connectors/building.md)
- **Per-chat use.** "select **+** in the message box and select **Connectors**", with a per-conversation toggle. Approvals are **Allow once** or **Always allow**. Customize > Connectors sets per-tool or per-group **Always allow**, **Needs approval**, or **Blocked**. Works on web, desktop, mobile, and in Claude Code with the Claude account. (https://claude.com/docs/connectors/getting-started.md)
- **Annotations.** "Every tool must include a `title` and the applicable hint: `readOnlyHint: true` for read-only tools, and `destructiveHint: true` for tools that modify or delete data. These determine auto-permissions in Claude. Read-only tools can run without per-call confirmation, and destructive tools always prompt." "Tool names must be 64 characters or fewer." (https://claude.com/docs/connectors/building/review-criteria.md)
- **Prefilled link.** `https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=NAME&connectorUrl=ENCODED_URL`, where `modal` must be `add-custom-connector` and `connectorUrl` is percent-encoded. Example: `https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Example&connectorUrl=https%3A%2F%2Fmcp.example.com%2F`. Admin variant: `https://claude.ai/admin-settings/connectors?modal=add-custom-connector&connectorName=NAME&connectorUrl=ENCODED_URL`. Custom connectors show as **Custom** and always get the external-link modal. (https://claude.com/docs/connectors/building/directory-vs-custom.md)
- **Prompts and resources.** The composer's "Add files, connectors, and more /" → Connectors → "Add to <Server>". "The menu displays all available resources and prompts from your connected server. Select the items you want to include in your conversation." (https://modelcontextprotocol.io/docs/develop/connect-remote-servers.md)
- **OAuth strictness (verbatim).** "A `401` is required to start sign-in, and Claude ignores a `WWW-Authenticate` header on a `200` response", and "Claude uses only the first entry in your metadata's `authorization_servers` list". The other OAuth rules are in section 2. (https://claude.com/docs/connectors/building/authentication.md)
- **MCP Apps domains.** `_meta.ui.domain` is the first 32 hex of SHA-256(server URL) plus `.claudemcpcontent.com`, validated against the connector URL. ChatGPT's default is `https://web-sandbox.oaiusercontent.com`, unique per plugin. (https://claude.com/docs/connectors/building/mcp-apps/getting-started.md)

### Recommendations

- **Instructions.** A self-contained first 512 characters: what the archive is, use `search` then `fetch`, cite the url, times in the user's timezone, and quiet stretches or gaps aren't missing data.
- **search and fetch.** Exactly OpenAI's `search(query: string)` and `fetch(id: string)` (shapes and `outputSchema` in the snippets), with url `https://pebbleaudio.okgodoit.com/c/{id}` (the Razor viewer) and the internal id in `id`.
- **Annotations.**
  - Read tools: `readOnlyHint:true`, `openWorldHint:false`, `destructiveHint:false`.
  - Write tools: `readOnlyHint:false`, plus `destructiveHint:true` if irreversible.
  - Every tool has a `title` and a name ≤64 chars.
  - Invoking/invoked strings ≤64 chars (for example "Searching your conversations…" and "Found conversations"), checked in a unit test.
- **Widgets.** Both `_meta.ui.resourceUri` and `openai/outputTemplate`; `_meta.ui.visibility` over the openai keys; widget-only data in result `_meta`.
- **Size and time.** Stay under ~150,000 characters and 25,000 tokens (paginate or truncate fetch text with a cursor) and well under 240 s; ffmpeg only on the queue.
- **Hints only.** `openai/locale` and `userLocation.timezone` only for formatting (fall back to the account timezone); `openai/subject` and `openai/session` for rate-limit and logging only.
- **Auth signals.** A 401 with `resource_metadata` plus `scope` for unauthenticated calls; `_meta["mcp/www_authenticate"]` when a token lapses mid-session.
- **Install help.** The admin page links `https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Pebble%20Audio&connectorUrl=https%3A%2F%2Fpebbleaudio.okgodoit.com%2Fmcp`. ChatGPT has no equivalent, so give step-by-step text.
- **Prompts.** Optional MCP prompts (for example "Summarize my day") and text resources for Claude's composer menu. No reliance on subscriptions or sampling.

### Risks

- Claude's limits have changed (an older summary said 25,000 tokens and 300 s, and an issue reports a hard 4-min Desktop cutoff), so design to the smaller numbers.
- A user-reported bug: tools whose `inputSchema` exceeds 16 KiB are silently dropped.
- A missing `readOnlyHint` prompts on every call.
- ChatGPT caches tools until Refresh.
- ChatGPT custom MCP is web-only and blockable by policy or Lockdown, and write-tool plan availability is unclear.
- An empty or relative `url` silently loses citations.
- `ui.domain` formats conflict between the hosts.

### Critic flags

- **Tool naming.** `search_conversations` (Hits, Snippet, StartedAt) in the section 1 snippet must become `search` and `fetch` with OpenAI's shapes.
- **Token-free citations.** Cited URLs carry no share token (section 8).
- **Helper annotations (gap).** App-only helpers need explicit annotations too.

### Unverified (verbatim)

- Whether ChatGPT truncates server instructions after 512 characters or just weights them less. The docs only say to keep the important details in the first 512 characters and keep that part self-contained.
- Any OpenAI-documented numeric tool-call timeout or maximum response size for ChatGPT MCP tools. None found in the October 2026 docs.
- Exactly what Claude's model sees when a result has both structuredContent and content. Claude docs don't say (the MCP spec says content should carry a text serialization). Anthropic's examples return both and say the content text "stays for hosts that don't render UI".
- Whether ChatGPT's "remember approval for this conversation" interacts with readOnlyHint tools, which presumably never prompt. The docs only describe write actions.
- The exact current claude.ai label for the prompts/resources menu. The MCP docs say "Add files, connectors, and more /" > Connectors > "Add to <Server>", and the UI may have changed.
- Whether Claude.ai uses MCP server `instructions`. No Anthropic connector doc mentions it.
- A ChatGPT equivalent of Claude's prefilled install link. None documented.

### Snippets

**OpenAI search tool response (verbatim)**

```jsonc
{
  "structuredContent": {
    "results": [{ "id": "doc-1", "title": "...", "url": "..." }]
  },
  "content": [
    {
      "type": "text",
      "text": "{\"results\":[{\"id\":\"doc-1\",\"title\":\"...\",\"url\":\"...\"}]}"
    }
  ]
}
// call: { "query": "What is the quarterly plan?" }
```

**OpenAI fetch tool response (verbatim)**

```jsonc
{
  "structuredContent": {
    "id": "doc-1",
    "title": "...",
    "text": "full text...",
    "url": "https://example.com/doc",
    "metadata": { "source": "vector_store" }
  },
  "content": [
    {
      "type": "text",
      "text": "{\"id\":\"doc-1\",\"title\":\"...\",\"text\":\"full text...\",\"url\":\"https://example.com/doc\",\"metadata\":{\"source\":\"vector_store\"}}"
    }
  ]
}
// Sample models: SearchResult{id,title,url}; SearchOutput{results: list[SearchResult]}; FetchOutput{id,title,text,url,metadata: dict|None=None}
```

**Tool descriptor shape combining both hosts (derived from the docs)**

```jsonc
{
  "name": "search",
  "title": "Search conversations",
  "description": "Use this when the user asks about something they said or heard...",
  "inputSchema": {"type":"object","properties":{"query":{"type":"string"}},"required":["query"]},
  "outputSchema": {"type":"object","properties":{"results":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"url":{"type":"string"}},"required":["id","title","url"]}}},"required":["results"]},
  "annotations": {"readOnlyHint": true, "destructiveHint": false, "openWorldHint": false},
  "_meta": {
    "openai/toolInvocation/invoking": "Searching your conversations…",
    "openai/toolInvocation/invoked": "Searched your conversations"
  }
}
// widget tools add: "_meta": {"ui": {"resourceUri": "ui://widget/day.html", "visibility": ["model","app"]}, "openai/outputTemplate": "ui://widget/day.html"}
```

**ChatGPT client _meta keys on tools/call**

```text
openai/locale        (initialize + tool calls) string BCP 47 (older: webplus/i18n)
openai/userAgent     (tool calls) string, best-effort hint
openai/userLocation  (tool calls) {city, region, country, timezone, longitude, latitude}
openai/subject       (tool calls) anonymized user id for rate limiting/identification
openai/session       (tool calls) anonymized conversation id
openai/organization  (tool calls) anonymized org id, when available
```

**Claude prefilled custom connector link**

```text
https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=NAME&connectorUrl=ENCODED_URL

For this project:
https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Pebble%20Audio&connectorUrl=https%3A%2F%2Fpebbleaudio.okgodoit.com%2Fmcp

Org admin variant:
https://claude.ai/admin-settings/connectors?modal=add-custom-connector&connectorName=NAME&connectorUrl=ENCODED_URL
```

**Claude limits table (verbatim values)**

```text
| Limit | claude.ai and Desktop | Claude Code |
| Maximum tool result size | ~150,000 characters | 25,000 tokens, configurable with MAX_MCP_OUTPUT_TOKENS |
| Tool call timeout | 240 seconds per tool call | Configurable with MCP_TOOL_TIMEOUT |
OAuth: discovery/registration/token 10 s, refresh 30 s.
```

**Claude 401 challenge (verbatim example)**

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"
(add scope="..." to control requested scopes; path-suffixed form: /.well-known/oauth-protected-resource/mcp)
```
