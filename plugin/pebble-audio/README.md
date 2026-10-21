# Pebble Audio plugin

One folder, two manifests, one skill. It connects an assistant to the Pebble Audio archive
server (`../../server`), the companion to the iOS app in `../../ios`.

- `plugin.json` + `mcp.json` + `skills/`: the portable Agent Plugins 1.0.0 layout used by Codex,
  and by ChatGPT where a Business, Enterprise, or Edu workspace owner or admin uploads it (admin
  console › Plugins › Add › Upload plugin, as a ZIP of this folder). An uploaded plugin's skill
  works in ChatGPT on the desktop only, unless its `.app.json` points at the app that was created
  for it. Any other ChatGPT account adds the server itself (chatgpt.com/plugins › Add › Add custom
  MCP server, Authentication OAuth, Create as a plugin, then Install under Personal; the steps
  are in `../../server/docs/connect-commands.md`), which carries the server but not the skill.
- `.claude-plugin/plugin.json` + `skills/`: the Claude plugin layout (claude.ai Customize →
  Plugins → upload a ZIP of this folder; Claude Code `claude plugin add`). It carries the skill
  only, no server: the server comes from the custom connector added in Claude, which syncs to
  Claude Code for anyone signed in with their Claude account. A plugin that declared the server
  itself (an `.mcp.json`) would outrank that connector and ask for a second sign-in.
- `skills/pebble-audio/SKILL.md`: how an assistant should use the archive. The same text, cut
  to 512 characters, is the server's MCP `instructions`, because a ChatGPT custom MCP
  connection carries no skills. `skills/pebble-audio/agents/openai.yaml` is its ChatGPT and
  Codex card (`short_description` 30 characters or fewer, transport `streamable_http`).

Every client signs in with the server's OAuth: ChatGPT, Claude, Gemini, Grok, Muse, and the CLI
agents (Claude Code, Codex, Cursor, Antigravity) too, which open the browser for the passkey
sign-in (each path is in `../../server/docs/connect-commands.md`). For headless use only, an
access key made on the server's Connect page works instead:

```json
{ "mcpServers": { "pebble-audio": { "type": "http", "url": "https://pebbleaudio.okgodoit.com/mcp", "headers": { "Authorization": "Bearer pat_…" } } } }
```

Build the two ZIPs with `./pack.sh`.
