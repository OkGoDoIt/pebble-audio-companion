# Pebble Audio plugin

One folder, two manifests, one skill. It connects an assistant to the Pebble Audio archive
server (`../../server`), the companion to the iOS app in `../../ios`.

- `plugin.json` + `mcp.json` + `skills/`: the portable Agent Plugins 1.0.0 layout used by
  ChatGPT (Plugins → Add → Upload plugin archive, as a ZIP of this folder) and Codex.
- `.claude-plugin/plugin.json` + `.mcp.json` + `skills/`: the Claude plugin layout (claude.ai
  Customize → Plugins → upload a ZIP of this folder; Claude Code `claude plugin add`).
- `skills/pebble-audio/SKILL.md`: how an assistant should use the archive. The same text, cut
  to 512 characters, is the server's MCP `instructions`, because a ChatGPT custom MCP
  connection carries no skills.

The server's OAuth sign-in is used by ChatGPT and Claude; CLI agents (Claude Code, Codex,
Cursor, OpenCode) use a bearer token created in the server's admin area:

```json
{ "mcpServers": { "pebble-audio": { "type": "http", "url": "https://pebbleaudio.okgodoit.com/mcp", "headers": { "Authorization": "Bearer pat_…" } } } }
```

Build the two ZIPs with `./pack.sh`.
