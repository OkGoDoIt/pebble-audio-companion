#!/usr/bin/env bash
# Build the ZIPs for ChatGPT (portable layout) and Claude (.claude-plugin layout) from this folder.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
out="../dist"; mkdir -p "$out"
rm -f "$out/pebble-audio-openai.zip" "$out/pebble-audio-claude.zip"
zip -qr "$out/pebble-audio-openai.zip" plugin.json mcp.json skills README.md
zip -qr "$out/pebble-audio-claude.zip" .claude-plugin .mcp.json skills README.md
ls -la "$out"
