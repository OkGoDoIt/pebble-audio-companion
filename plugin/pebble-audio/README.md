# Pebble Audio plugin

One folder, two manifests, one skill. It connects an assistant to the Pebble Audio archive
server (`../../server`), the companion to the iOS app in `../../ios`.

- `plugin.json` + `mcp.json` + `skills/`: the portable Agent Plugins 1.0.0 layout used by Codex,
  and by ChatGPT where a workspace owner or admin uploads it (admin console › Plugins › Add ›
  Upload plugin, as a ZIP of this folder). A personal ChatGPT account has no upload: it adds the
  server itself (chatgpt.com/plugins › Add › Add custom MCP server, Authentication OAuth, Create
  as a plugin; the steps are in `../../server/docs/connect-commands.md`), which carries the server
  but not the skill.
- `.claude-plugin/plugin.json` + `.mcp.json` + `skills/`: the Claude plugin layout (claude.ai
  Customize → Plugins → upload a ZIP of this folder; Claude Code `claude plugin add`).
- `skills/pebble-audio/SKILL.md`: how an assistant should use the archive. The same text, cut
  to 512 characters, is the server's MCP `instructions`, because a ChatGPT custom MCP
  connection carries no skills.

Every client signs in with the server's OAuth: ChatGPT, Claude, and the CLI agents (Claude Code,
Codex, Cursor) too, which open the browser for the passkey sign-in (commands in
`../../server/docs/connect-commands.md`). For headless use only, a bearer token from the server's
admin area works instead:

```json
{ "mcpServers": { "pebble-audio": { "type": "http", "url": "https://pebbleaudio.okgodoit.com/mcp", "headers": { "Authorization": "Bearer pat_…" } } } }
```

Build the two ZIPs with `./pack.sh`.
