# Round 3: real logos, and round 1's Privacy diagram

Round 3 is round 2 with two changes: real vendor logos, and round 1's Privacy card. Everything else
is unchanged. `_tools/` and the sources were copied from round 2, and every screen is rebuilt from
`_tools/build.py` and `_tools/server_pages.py`. The new `_tools/logos.py` draws every brand tile.

These eight pages are byte-identical to round 2: 01, 02, 03a, 03b, 04a, 04b, 06a, 07b, and 07d.
Settings root, intro, and the iPhone server page are on that list because none of them has a
vendor tile. Their only tiles are our own glyphs: the watch, the feature's chat circle, and
Pebble Audio.

I re-rendered 40 PNGs (390 × 844 @2x, Mac 1280 × 800 @2x) and `sheet.png` (28 screens), and looked
at every one. All 40 renders pass the same checks:

- The console is clean.
- Nothing loads from the network.
- Nothing scrolls sideways.
- No interactive target is under 44 pt.

New screens:

- `09e-privacy-paused`
- `05c-connect-mac-dark`, a dark-mode check of the brand tiles

## 1. Real logos

- **Where the marks come from.** They are in `logos/`, and `logos/SOURCES.md` gives the URL,
  version, and license for each file.
  - Simple Icons 16.35.0 (CC0) for Claude, Cursor, Gemini, Meta, and iCloud.
  - Soniox is not in Simple Icons. Its mark is the official icon from soniox.com/brand.
  - OpenAI is gone from Simple Icons as of 16.0.0, so its mark comes from 15.22.0, the last release
    that has it. openai.com/brand returned 403, so I could not fetch the press-kit file.
  - Codex uses the OpenAI mark and Claude Code uses the Claude mark, as asked.
- **Tile sizes.** There is one size and radius for each context:
  - 34 pt, radius 9, in lists.
  - 40 pt, radius 10, in the Privacy diagram.
  - 52 pt, radius 13, as the header on the assistant detail screen (08).
- **Colors.** Each mark is drawn in its official color on a white tile. Two pairs share a mark, so
  the tile color tells them apart:
  - ChatGPT is white on black, and Codex is black on white.
  - Claude is on white, and Claude Code is on Anthropic's near-black, #191919.
  - Soniox keeps its own blue square.
- **Contrast.** Every mark has at least 3:1 against its tile (WCAG non-text contrast): Claude on
  white is 3.1:1, iCloud 3.2:1, and the rest are higher. The tile colors are fixed, so the ratios
  are the same in light and dark mode. White tiles get a hairline in light mode, and dark tiles get
  a light edge in dark mode.
- **Where the marks now appear:**
  - Connect (05a–05e).
  - The Mac server pages' "Who can read" (06b, 06c): Codex and Cursor waiting.
  - Linked (07a, 07e, and 07c, which is drawn over 07a).
  - Assistant detail (08).
  - Every Privacy state.
- **Groups.** A row that stands for several apps gets one tile of the usual size with their marks
  inside it, like an iOS folder:
  - "Codex, Claude Code, or Cursor" shows the OpenAI, Claude Code, and Cursor marks.
  - "Claude Code or Cursor" shows two of them.
  - "Another assistant · Gemini and others" shows Gemini plus a small plus sign.

  A full Gemini tile on that row would read as "Gemini" alone.

## 2. Privacy: round 1's stance card, grown into a tree

- **The card.** It has the headline and one line, then the flow diagram. It starts with a green
  This iPhone tile labelled "Audio and text".
- **One branch per destination.** Each place the phone sends to gets a branch (arrow and tile), in
  the model's order:

  | Destination | Branch label |
  | --- | --- |
  | Soniox or OpenAI (transcription) | Audio |
  | OpenAI (AI) | Text |
  | iCloud Drive | Older audio |
  | Your server | Text, plus Clips when asked if clips are on |
  | Meta | Your questions, typed ones as text, spoken ones as a short recording |

  Only active branches are drawn. With nothing active (a), there is no diagram, as in round 1.
- **Assistants.** They hang off the server's branch:
  - With assistants connected: their real marks overlap, then their names with an Oxford comma,
    then one chip saying what they may do. The chip reads "Can read", "Can read and ask for clips",
    "Can read and add", or "Can read, ask for clips, and add".
  - With none connected: a hatched tile, "Assistants · None yet" (b), as in your crop.
- **Sync paused (new 09e).** The branch to your server is dashed, has no arrowhead, and reads
  "Sync is paused". The branch from the server to ChatGPT and Claude stays solid, because they can
  still read what the server has.
- **It fits at 390 pt.** The tree is vertical and each level indents 50 pt, so no row gets long.
  State (d) has Soniox, your server with clips, ChatGPT, Claude, and Codex on Mac, and Meta, and
  every label fits without truncation.
- **The diagram and the rows use one source.** Both are built from one destination list in
  `build.py`, so names and chips are the same words in both places:
  - **Where it goes.** Each row has the name, one line on why ("Transcribes your recordings",
    "Writes summaries", "Keeps audio older than 60 days", "So your assistants can read it",
    "Answers your questions"), and round 2's chips.
    - The server row is now titled "Your server", to match the diagram. Its host and scope moved
      to a small last line.
    - The Meta row keeps the typed and spoken line.
  - **Who can read your archive.** Each assistant has its mark, "Last read …", and the same
    permission chip as the diagram.
  - **Below these:** Siri & Spotlight, and the derived commitments, as in round 2.
- **Changes from the updated `privacy-model.md`:**
  - "Nothing else leaves this phone" is gone. A state with several destinations says only "Each is
    listed below."
  - N counts every assistant: (c) is three places, (d) six, and (e) five.
  - A paused server is still a destination. Its row reads "Sync is paused", and the stance never
    says "Everything stays on this phone" while the server holds text.
  - With Muse on, the model's sentence appears word for word under Where it goes: "The questions
    you ask Muse go to Meta: typed ones as text, spoken ones as a short recording. Its answers come
    back as text. Nothing goes while you aren't asking."
  - The vendor line is deduplicated and uses the Oxford comma. In (e) it reads "What OpenAI,
    ChatGPT, and Claude keep is governed by them, not by this app."

## For Roger

- **Headlines follow the model, not round 1's crop.** The model sets the headline:
  - (b) is "Text syncs to pebbleaudio.okgodoit.com", the model's own example. Round 1 said "Text
    goes to your server".
  - (c) is "Your data goes to three places you chose". Round 1 said "ChatGPT and Claude can read
    your text". The diagram now carries what that headline said.

  If you would rather keep round 1's headlines, the model's §3.1 has to change first.
- **09e turns on more than pause.** Besides pausing sync, 09e also turns on OpenAI for AI and
  iCloud for audio older than 60 days. That way every branch type, and every vendor logo except
  Cursor and Gemini, appears somewhere on the Privacy screens. If you want a pure "paused" state
  instead, it is one line in `build.py`.
- **"Can read and add" is supported but never shown.** The code handles it, but no state turns
  edits on, so no screen shows it.
- **Two shapes for the same words.** The linked screen (07a, 07e) still shows "Can read · Last read
  1 hr ago" as one text line, as in round 2. Privacy shows the same words as a chip under "Last
  read …". Say if the linked screen should use the chip too.
- **Logo permissions.** Trademark use needs a check against each vendor's guidelines before this
  ships:
  - Soniox's brand page asks for the icon in square formats with a matching corner radius, which
    is what the tile does.
  - OpenAI's mark comes from an older Simple Icons release.

## Checker pass

- **Overlapping logos hid each other.** In the Privacy diagram each tile covered 12 pt of the one
  before it, which cut into the marks themselves (Claude's star was half hidden behind Codex in
  (d)). The overlap is now 6 pt, so it covers only the tile padding and every mark is whole. Three
  assistants take 108 pt and still fit at 390 pt.
- **The dashed branch stopped short.** A dashed branch (sync paused, or "Assistants · None yet")
  has no arrowhead, so its stub ended 8 pt before the tile. It now reaches the tile.
- Re-rendered the 12 Privacy PNGs and `sheet.png`. The console is clean, and nothing loads from the
  network or scrolls sideways. Each logo file still matches its source URL byte for byte.
