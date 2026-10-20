# Round 2 review fixes

These changes answer the round-2 review (score 8). Every screen is rebuilt from `_tools/build.py` and
`_tools/server_pages.py`, so a shared sentence is written once and used everywhere it appears. I
re-rendered every PNG and `sheet.png` and looked at each one again. The console is clean on all 37
renders, nothing reaches the network, nothing scrolls sideways, and no product target is under 44 pt.

New screens: `05e-connect-cursor`, `06c-server-mac-cursor` (1280 × 800), `07d-scope-from-date`, and
`07e-linked-paused`. That makes 26 on the sheet.

## Must fix

1. **The audio sentence now covers only the server.** The intro says "No audio goes to your server
   unless you allow clips." Choose (04a, 04b) says "No audio goes to your server." The sentence
   "Audio stays on this phone" now appears only in the Privacy stance, which works it out from
   every input (09b).
2. **D6 and the stance count.** I kept the design: each assistant appears once, under "Who can read
   your archive", directly below "Where it goes", and the stance counts it (c: 1 + 2 = three
   places; d: 3 + 3 = six). I could not change `docs/privacy-model.md`, because this task may only
   write inside `round2/`. **Roger needs to apply this change to §3.2** so the model and the
   mockups agree:
   > Assistants reading your server (D6) are not repeated here. Each connected assistant appears
   > once, under Who can read your archive (item 3), which directly follows this list, and each
   > counts toward N in the stance.
3. **"From today on" now names the day: "From October 21 on".** Its card says "Today's 3
   conversations, and every new one.", so this morning is clearly included. The linked editor
   offers the same dated option. Switching to it later works like choosing a shorter window. It
   gets its own confirmation (new `07d`): "Remove 165 conversations from your server?", the date,
   that assistants can no longer read them, and that they stay on this phone.
4. **One name and one header for clips and edits.** Choose and Linked now use the same block,
   "Assistants may also": "Ask for audio clips" and "Add follow-ups and notes", each with the same
   subtitle. On the linked screen, the Conversations · Last 90 days row is now the last row of its
   card. The rolling-window line sits directly under it.

## Should fix (all accepted)

- **Counts in every scope card:** "168 conversations, back to July 23." and "Today's 3
  conversations". The 30-day window says "57 conversations, back to September 21."
- **Keep audio line:** "Your server keeps the text even after Keep audio clears a recording here."
- **Intro:** "Nothing syncs until you tap Start Syncing." The "open in a browser" need now uses a
  new browser glyph. The clock glyph stays with Muse's "a few minutes".
- **Passkey step:** "Sign in to your server with your passkey." on ChatGPT, Claude, and Another
  assistant.
- **Claude:** the "Waiting for Claude" spinner is gone before the tap. In the real app it appears
  only after Open in Claude is tapped.
- **Mac tools:** the steps follow the picked app. Codex and Claude Code: Open Setup in Safari, then
  "Copy it, then paste it into Terminal on your Mac." Cursor (new `05e`): "Tap Copy Link, then
  paste it into Safari on your Mac." and "Click Add to Cursor, then confirm in Cursor." Both end
  with "Or, on your Mac, open pebbleaudio.okgodoit.com/connect." I dropped the "Opens …/connect/codex"
  line to make room. The server page's Cursor tab is drawn at Mac width (new `06c`). It has an
  Add to Cursor button that carries the key, not a Terminal command.
- **One copy set for the server page at both widths (06a, 06b, 06c):**
  - The same lede: "Codex gets its own access key, so it can read your conversations."
  - The same three numbered steps.
  - The same shown-once note.
  - The same waiting line: "It shows up here and in Pebble Audio once it reads."
  - The same footer: "Each app has its own access key."
  - The only line that differs is on iPhone, where it explains how the copy reaches the Mac
    (Universal Clipboard).
  - The command now wraps at spaces and spans the full card width, so the access key reads in full
    and nothing fades out.
- **"Can read · Last read 1 hr ago"** on 07a, 07e, 09c, and 09d. When clips are on, the longer
  label "Can read and ask for clips" puts "Last read …" on its own line.
- **Linked screen:**
  - It has a permanent "What goes to pebbleaudio.okgodoit.com" block, as the Muse paired screen
    keeps "What goes to Meta". It holds the text sentence and the deletion line, with the
    Conversations row inside it.
  - The paused state is now designed (new `07e`): "Sync is paused", "Assistants can still read
    what your server already has.", and the Sync switch off. The block then says "Your server has
    the text of 168 conversations. Nothing new goes to it while Sync is off."
- **Unlink confirmation (07c):** "Deletes the text of 168 conversations from
  pebbleaudio.okgodoit.com. ChatGPT, Claude, and Codex on Mac lose access. Nothing on this phone
  changes." It is now the same bottom confirmation as 07b and 07d. The app's Forget Watch uses the
  same kind of confirmation (`confirmationDialog`).
- **Deletion footer:** "Deleting a conversation here deletes it from your server too." no longer
  appears on Privacy. It lives only on the linked screen, and the paused state leaves it out
  because nothing propagates while sync is off.
- **Tiles:**
  - The two services the phone sends to are circles with one letter: Soniox "S" and Meta "M".
  - ChatGPT and Claude, the assistants that read, are rounded squares with initials ("GPT", "Cl").
  - Codex on Mac uses a Terminal glyph, and the Mac tools group uses a laptop glyph.
  - So "Cl" and "Cx" no longer meet at squint size, and "Me" is gone.
- **Official Pebble app:** every Privacy state adds "The official Pebble app never receives your
  audio." The model lists this as a lasting commitment. `Copy+PrivacyStance.swift` should gain the
  same line when this ships.
- **Accessibility:**
  - The segmented controls are now 44 pt tall. The Choose screen's 36 pt override is removed.
  - Step-bar labels use a type token (`--f-step-label`, which maps to `.footnote`) instead of a
    fixed 13 px, and they can wrap.
- **Destructive buttons:** in all three confirmations they are now red text on the same neutral
  pill as Cancel, with no pink fill. This matches how `role: .destructive` draws and the
  red-text-only Forget Muse.

## Declined

None declined. One item is kept as it was and flagged instead of changed:

- **"Nothing else leaves this phone." (09c, 09d).** I kept it because `privacy-model.md` §3.1
  requires it. It conflicts with `Copy+PrivacyStance.swift`, which leaves out any blanket "nothing
  else" sentence on purpose, because the bundled speech engine carries its own HTTP stack and the
  claim cannot be verified from source. **Roger has to decide before this ships.** One option is to
  keep the sentence once the engine's network use is verified. The other is to change the model's
  line to "Each is listed below." alone.

## Also for Roger

- **Paused sync in the model.** The model sets `server` to nil when sync is paused (§2), so Privacy
  would say "Everything stays on this phone". But assistants can still read what the server holds.
  A paused server should still count as D5 and D6 on Privacy, just without new text going to it.
- **The rolling window is server-side.** "Older conversations are removed from your server each
  day" holds while the phone is off or Sync is paused only if the server applies the window
  itself.
- **Commands are illustrative.** The Codex command, the Cursor Add to Cursor link and its confirm
  step, and the ChatGPT labels need a check against each tool's current release before the
  server's setup pages ship.
