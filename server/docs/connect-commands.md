# Connecting each assistant (verified 2026-10-21)

The server's `/connect` hub lists ChatGPT, Claude, Claude Code, Codex, Cursor, Gemini, Muse, Grok,
then Another assistant (Antigravity and anything else), and `/connect/{tool}` gives each one's
steps. Every one of them signs in with OAuth against this server (dynamic registration or a
client-ID metadata document, PKCE), so the default path needs no access key: the assistant
opens the browser, the person signs in with their passkey and allows access, done. An access
key (`pat_…`, made on the page) is the fallback for headless use only. The iPhone app's Connect
step (`ios/App/Screens/Settings/Assistants/AssistantsConnectScreen.swift`) uses the same links.

"Verified" below means an official page says it; "reported" means forum or GitHub reports only.
Undated pages are marked "accessed 2026-10-21".

## On the assistant's website

| Assistant | One click as far as it goes | Plans and limits | Sources |
| --- | --- | --- | --- |
| ChatGPT | `https://chatgpt.com/plugins` › **+** › **Add custom MCP server** › **Name** "Pebble Audio", **Server URL** `https://<host>/mcp`, **Authentication** OAuth › tick **I understand and want to continue** › **Create as a plugin** › sign in › under **Personal**, **Install**. No prefilled link or deep link exists (openai/codex#54925 is still open). Developer Mode is no longer needed. | Web only to add; it then works in the ChatGPT app. Help center: full MCP for Business and Enterprise/Edu, Pro "read/fetch" only, Plus not mentioned (the coordinator's reading: rolling out). The developer docs say read and write with no plan limit; the page hedges: "On Pro it reads, and Plus may not offer it yet." | https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt (updated about 2026-10-20); https://developers.openai.com/api/docs/guides/custom-mcp-server (accessed 2026-10-21) |
| Claude | `https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Pebble%20Audio&connectorUrl=https%3A%2F%2F<host>%2Fmcp` opens Add custom connector filled in (values encoded whole, `://` and `/` too, as Claude's example writes them); then Connect and sign in. Owners: the same query on `https://claude.ai/admin-settings/connectors`. | Free (one custom connector), Pro, Max. Team: Owners and Primary Owners add it; Enterprise: Owners, Primary Owners, and roles that manage the organization's libraries. A connector added on the web syncs to the phone and the Mac. On the iPhone the link is a universal link into the Claude app (untested whether the app completes the dialog), Safari otherwise. | https://claude.com/docs/connectors/building/directory-vs-custom; https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp; https://claude.com/docs/connectors/custom/add-unlisted (accessed 2026-10-21) |
| Gemini | `https://gemini.google.com/apps` (Connected Apps, as Google's help links it) › under **Custom apps**, **Add a custom app** › **MCP server URL** › **Next** › sign in. | 18 or over and in the US, a personal Google Account, English only, and Keep Activity on ("Custom apps are unavailable when this setting is off"), so Google may use what it reads. Not in the EEA, Nigeria, Switzerland, or the UK. Added on the web, it works on mobile too. Reported: Google AI Pro/Ultra only. | https://support.google.com/gemini/answer/17209137; https://support.google.com/gemini/answer/16598406 (accessed 2026-10-21) |
| Grok | `https://grok.com/connectors` › **New Connector** › **Custom** › the URL › sign in. No prefilled link. | "Connectors are available to all Grok users" (a secondary guide says paid tiers). On Grok Business and Enterprise an admin adds it first: console.x.ai › Grok Business › Connectors › **+ Add Connector** › **Other**. Connectors went live on web, iOS, and Android on 2026-05-06; adding a custom one on mobile is unverified. | https://docs.x.ai/grok/connectors; https://docs.x.ai/grok/connector-management (accessed 2026-10-21); https://x.ai/news/grok-connectors (2026-05-06) |
| Muse (Meta) | Ask Muse in its app, at muse.ai, or in WhatsApp: "Create a custom connector named Pebble Audio for https://<host>/mcp". The page's Copy Prompt copies that; Open Muse opens `https://muse.ai`. Separate from pairing Muse through the watch (iPhone app, Settings › Muse). | US, rolling out on iOS, Android, muse.ai, and WhatsApp. Meta's help page says custom connectors exist and Meta doesn't review them; it never says MCP. | https://www.meta.com/help/artificial-intelligence/1687253048996149/; https://about.fb.com/news/2026/09/introducing-muse (2026-09-08) |

## On the computer

| Tool | Default (OAuth) | Fallback (access key) | Source |
| --- | --- | --- | --- |
| Claude Code | Nothing, when Claude Code is signed in with the Claude account that added the connector in Claude: it is already in `/mcp`. With an API-key login: `claude mcp add --transport http --scope user pebble-audio https://<host>/mcp`, then `/mcp` to sign in. A local `claude mcp add` (or a plugin's `.mcp.json`) hides the synced connector and asks for a second sign-in, so the page says to use it only with an API key. | `claude mcp add --transport http --scope user pebble-audio https://<host>/mcp --header "Authorization: Bearer pat_…"` | https://code.claude.com/docs/en/mcp |
| Codex (CLI, IDE, ChatGPT desktop app) | `codex mcp add pebble-audio --url https://<host>/mcp`, which starts the sign-in itself (no separate `codex mcp login`). | `~/.codex/config.toml`: `[mcp_servers.pebble-audio]` / `url = "https://<host>/mcp"` / `bearer_token_env_var = "PEBBLE_AUDIO_KEY"`, with `export PEBBLE_AUDIO_KEY=pat_…` in the shell profile | https://learn.chatgpt.com/docs/extend/mcp.md?surface=cli |
| Cursor | `cursor://anysphere.cursor-deeplink/mcp/install?name=pebble-audio&config=<base64 of {"url":"https://<host>/mcp"}>` (documented); "Or open in the browser": `https://cursor.com/install-mcp?name=…&config=…` (undocumented, resolves, and Slack's docs use it). `https://cursor.com/link/mcp/install?…` follows Cursor's documented deeplink-to-https rule but its examples don't cover MCP. The web link never carries an access key. Cursor's official badges are not copied in; the page uses its own button. | `"headers": { "Authorization": "Bearer ${env:PEBBLE_AUDIO_KEY}" }` in the entry, or the app link with the key's header | https://cursor.com/docs/context/mcp/install-links; https://cursor.com/docs/reference/deeplinks |
| Antigravity (replaces Gemini CLI on consumer plans) | `~/.gemini/config/mcp_config.json`: `{"mcpServers":{"pebble-audio":{"serverUrl":"https://<host>/mcp"}}}`; it handles OAuth itself through dynamic registration. | An access key from Another assistant | https://antigravity.google/docs/mcp (accessed 2026-10-21) |
| Grok Build | `grok mcp add --transport http pebble-audio https://<host>/mcp`; OAuth opens the browser on first use. | `--header "Authorization: Bearer pat_…"` | https://docs.x.ai/build/features/mcp-servers |
| Gemini CLI (paid API keys and Code Assist Standard/Enterprise only since 2026-06-18) | `gemini mcp add --transport http pebble-audio https://<host>/mcp` | `--header "Authorization: Bearer pat_…"` | https://geminicli.com/docs/tools/mcp-server/ (updated 2026-10-06); https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli (2026-05-19) |

## What the OAuth server accepts for them

Redirect URIs: Claude `https://claude.ai/api/mcp/auth_callback`; ChatGPT
`https://chatgpt.com/connector_platform_oauth_redirect` and `https://chatgpt.com/connector/oauth/{id}`;
Claude Code a loopback port of its choosing; Codex `http://127.0.0.1:<port>/callback`; Cursor
`http://localhost:8787/callback`, `https://www.cursor.com/agents/mcp/oauth/callback`, and on some
installs `cursor://anysphere.cursor-mcp/oauth/callback`; Gemini (reported)
`https://oauth-redirect.googleusercontent.com/r/<id>`; Antigravity `https://antigravity.google/oauth-callback`;
Grok (reported) `https://grok.com/connectors-oauth-exchange-code/` with its trailing slash; Muse
(reported) `https://agent.meta.ai/api/hatch/oauth/callback`, or `https://muse.ai/connect/oauth-callback`
with a metadata document on muse.ai.

- https redirects and any loopback port (RFC 8252) are accepted. Cursor's private-use redirect is
  the one custom scheme allowed, by its exact scheme and host with no port; no other custom
  scheme is.
- A registration asking for `client_secret_basic` or `client_secret_post` (Gemini, reportedly) is
  registered as a public client and answered `token_endpoint_auth_method: "none"` (RFC 7591
  §3.2.1). The token endpoint still refuses a client secret or Basic credentials.
- An app that gives no `client_name` is named from where it returns to: ChatGPT, Claude, Gemini,
  Antigravity, Muse, or Grok.
- The 401 on `/mcp` carries `scope="archive:read archive:write"` beside `resource_metadata`.
- No tool schema carries `$defs` or `$ref` (Gemini reportedly cannot read them); a test guards it.
- On a plan without write tools (ChatGPT Pro, any read-only grant) nothing breaks: the write tools
  are not listed, and the instructions say writing happens when allowed.
