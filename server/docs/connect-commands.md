# Connecting the Mac tools (verified 2026-10-21)

The server's `/connect/{tool}` pages show these. All three tools sign in with OAuth against this
server (dynamic registration or a client-ID metadata document, PKCE), so the default path needs
no access key: the tool opens the browser, the person signs in with their passkey and allows
access, done. An access key (`pat_…`, made on the page) is the fallback for headless use only.

| Tool | Default (OAuth) | Fallback (access key) | Source |
| --- | --- | --- | --- |
| Claude Code | `claude mcp add --transport http --scope user pebble-audio https://pebbleaudio.okgodoit.com/mcp`, then `/mcp` inside Claude Code (or `claude mcp login pebble-audio`) to sign in | `claude mcp add --transport http --scope user pebble-audio https://pebbleaudio.okgodoit.com/mcp --header "Authorization: Bearer pat_…"` | https://code.claude.com/docs/en/mcp |
| Codex | `codex mcp add pebble-audio --url https://pebbleaudio.okgodoit.com/mcp`, then `codex mcp login pebble-audio` | `~/.codex/config.toml`: `[mcp_servers.pebble-audio]` / `url = "https://pebbleaudio.okgodoit.com/mcp"` / `bearer_token_env_var = "PEBBLE_AUDIO_KEY"`, with `export PEBBLE_AUDIO_KEY=pat_…` in the shell profile | https://learn.chatgpt.com/docs/extend/mcp.md?surface=cli |
| Cursor | One-click: `cursor://anysphere.cursor-deeplink/mcp/install?name=pebble-audio&config=<base64 of {"url":"https://pebbleaudio.okgodoit.com/mcp"}>`; or `~/.cursor/mcp.json`: `{ "mcpServers": { "pebble-audio": { "url": "https://pebbleaudio.okgodoit.com/mcp" } } }`; Cursor prompts to sign in | `"headers": { "Authorization": "Bearer ${env:PEBBLE_AUDIO_KEY}" }` in the same entry | https://cursor.com/docs/context/mcp, https://cursor.com/docs/plugins/mcp/install-links |

Redirect URIs these tools use (the OAuth server must accept them): Claude Code a loopback port
of its choosing; Codex `http://127.0.0.1/callback` (any port); Cursor desktop
`http://localhost:8787/callback`, Cursor web/agents `https://www.cursor.com/agents/mcp/oauth/callback`.
The OAuth server accepts https redirects and any loopback port (RFC 8252), so all of these work.

The ChatGPT steps (web): Plugins › Add › Add custom MCP server › Name "Pebble Audio", Connection
"Server URL" `https://pebbleaudio.okgodoit.com/mcp`, Authentication "OAuth", tick "I understand
and want to continue", Create as a plugin, then sign in with the passkey. (Labels verified from
Roger's screenshots of his account, 2026-10-20.)

Claude (claude.ai): the prefilled link
`https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Pebble%20Audio&connectorUrl=https%3A%2F%2Fpebbleaudio.okgodoit.com%2Fmcp`
opens the Add custom connector dialog filled in; then Connect and sign in with the passkey.
