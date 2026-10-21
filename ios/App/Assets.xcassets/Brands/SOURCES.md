# Logo sources (round 3)

Downloaded 2026-10-21. Each file is the vendor's mark, unmodified; `_tools/logos.py` inlines it and sets
the fill color at build time (the files themselves carry no color, except Soniox's). Trademarks stay
with their owners: these marks are here to identify each service in a design mockup, not to imply
endorsement. Check each vendor's brand guidelines before the shipping app uses them.

| File | Used for | Source URL | Version | License | Color used |
| --- | --- | --- | --- | --- | --- |
| `openai.svg` | ChatGPT, Codex, OpenAI (cloud transcription and AI) | https://cdn.jsdelivr.net/npm/simple-icons@15.22.0/icons/openai.svg | Simple Icons 15.22.0 | CC0-1.0 (Simple Icons) | black or white, per OpenAI's brand page |
| `claude.svg` | Claude, Claude Code | https://cdn.jsdelivr.net/npm/simple-icons@16.35.0/icons/claude.svg | Simple Icons 16.35.0 | CC0-1.0 (Simple Icons) | #D97757 |
| `cursor.svg` | Cursor | https://cdn.jsdelivr.net/npm/simple-icons@16.35.0/icons/cursor.svg | Simple Icons 16.35.0 | CC0-1.0 (Simple Icons) | #000000 |
| `googlegemini.svg` | Gemini ("Another assistant") | https://cdn.jsdelivr.net/npm/simple-icons@16.35.0/icons/googlegemini.svg | Simple Icons 16.35.0 | CC0-1.0 (Simple Icons) | #8E75B2 |
| `meta.svg` | Meta (Muse) | https://cdn.jsdelivr.net/npm/simple-icons@16.35.0/icons/meta.svg | Simple Icons 16.35.0 | CC0-1.0 (Simple Icons) | #0467DF |
| `icloud.svg` | iCloud Drive (older audio) | https://cdn.jsdelivr.net/npm/simple-icons@16.35.0/icons/icloud.svg | Simple Icons 16.35.0 | CC0-1.0 (Simple Icons) | #3693F3 |
| `soniox-icon-blue-white.svg` | Soniox (used) | https://soniox.com/images/brand/soniox-icon-blue-white.svg, linked from https://soniox.com/brand | as served 2026-10-21 | Soniox brand assets, use per Soniox's brand guidelines (not open-licensed) | its own: white on #1881FF |
| `soniox-icon-white-blue.svg` | Soniox (alternate, not used) | https://soniox.com/images/brand/soniox-icon-white-blue.svg | as served 2026-10-21 | as above | its own: #1881FF on white |

Notes:

- **OpenAI is not in current Simple Icons.** `openai.svg` returns 404 from 16.0.0 on (checked 16.0.0,
  16.10.0, 16.20.0, 16.30.0, and 16.35.0); 15.22.0 is the last release that ships it. OpenAI's own brand
  page (https://openai.com/brand/) refused a non-browser download (HTTP 403), so the press-kit file
  could not be fetched here. Simple Icons' last hex for OpenAI, #412991, is a retired purple; the
  mockups draw the mark black or white, as OpenAI's brand page shows it.
- **Soniox is not in Simple Icons** (404 for `soniox.svg` in 16.35.0). Its brand page offers the icon
  as a square that carries the wordmark and asks that its corner radius match the surface; the tile
  clips it to the tile's radius.
- **Codex** uses the OpenAI mark and **Claude Code** the Claude mark, as asked. The tile tells each
  pair apart: ChatGPT is white on black and Codex black on white; Claude is on white and Claude Code
  on Anthropic's near-black (#191919, Simple Icons' Anthropic hex).
- Contrast of each mark against its tile (non-text, WCAG 1.4.11 needs 3:1): OpenAI and Cursor 21:1,
  Meta 5.2:1, Claude Code 5.6:1, Gemini 3.9:1, Soniox 3.7:1, iCloud 3.2:1, Claude on white 3.1:1. The
  tiles use fixed colors, so the same ratios hold in light and dark mode; dark tiles get a light edge
  in dark mode and white tiles a hairline in light mode.
