# SwiftUI Rebuild — Implementation Plan

2026-08-30 · The master spec for the ground-up native iOS rebuild of the Pebble Audio Companion.
This document is written so a build session can work from it **without the design conversation**:
it consolidates every decision, the complete visual/UX spec, the functional contract, the
architecture, and the milestone order.

**Sources of truth, in precedence order:**
1. This document (decisions + contract).
2. The mockup artboards — `docs/redesign/mockups/*.dc.html` (canvas artifact "Audio Companion
   Redesign", 20 artboards) — for anything visual this doc summarizes. Companion:
   `2026-08-30-mockup-spec-extraction.md` (element-by-element extraction).
3. The KMP code + test suites and `spec/fixtures/` — the behavioral/wire contract the Swift
   port must match (Part 4 lists every test by name).
4. Supporting docs: `2026-08-30-direction-decisions.md`, `2026-08-30-existing-app-analysis.md`
   (the teardown; its findings are anti-goals), `2026-08-30-segment-churn-investigation.md`
   (wire behavior), `spec/audio-companion-protocol.md` (normative protocol).

**Ground rules for build sessions:** commit per milestone with `area:` subjects; update the
progress log in `UPSTREAM_THIRD_PARTY_BACKGROUND_AUDIO_IMPLEMENTATION_PLAN.md` every session;
never touch `mobileapp/`; the firmware pair currently deployed is `f91b6e0f3`
(audio-companion branch) — the Swift receiver targets exactly its wire behavior.

---

---

# Part 1 — The Decision Register (complete, normative)

Everything decided across the four design rounds, restated as build requirements. Source docs:
`2026-08-30-direction-decisions.md` (the contract), `2026-08-30-existing-app-analysis.md` (the
teardown; its B/U/D findings are the anti-goals), `2026-08-30-segment-churn-investigation.md`
(wire-behavior contract).

## P0 — Simplify dramatically (overarching)
Minimum steps; labels over helper paragraphs; privacy stated once, calmly ("Recordings stay on
this phone unless you choose a cloud provider." on the Settings root; the legal line once, on
Storage & Privacy); short honest status copy — one line where the old app used three; no
scare-mongering; keep functionality, cut ceremony.

## The nineteen decisions

| # | Decision | Build consequence |
|---|---|---|
| Q1 | Native iOS structure; violet `#5B5BD6` as tint only | Stock SwiftUI components/navigation; the token sheet in Part 2; no custom component shell |
| Q2 | 3 tabs (Today/Library/Settings); AI woven in | No AI tab. Recap + follow-ups on Today; per-conversation AI in detail; Ask as sheet from 3 entry points |
| Q3 | Today = status + live minute + day coverage + recap + follow-ups (+ conversations) | The five-block Today layout in Part 2 |
| Q4 | Full Swift rewrite, no shared KMP core | KMP tests + golden fixtures = the spec (Part 5); migration needed (Q19) |
| Q5 | Finish the half-built features | Speaker naming (Q17), custom templates (post-v1 backlog: template save/reuse), a real date-range picker for Ask scope. Rules engine: NOT ported (stretch, design-for later) |
| Q6 | Calm live preview | 1-line italic rolling snippet on the Live row; full text on the Live Conversation screen |
| Q7 | Settings split into pushed screens | The 5 sub-screens in Part 2; API keys in Keychain with a change flow (never inline fields); retentionDays REAL (old app's was placebo); no placebo controls anywhere |
| Q8 | Churn investigated first | Resolved: reattach fixed in the current pair (app 1dcc6d0/1e5db02, fw 23750e1f9/f91b6e0f3); conversations group segments in the UI (Part 3) |
| Q9 | Loss alerts only | One notification type: ≥30 s continuous loss or spool overflow; ≤1/hour; deep-links to Today; permission requested at first loss event, not onboarding. No other notifications |
| Q10 | Tags editable | AI proposes; add/remove/rename in the Tag Editor sheet; rename is global |
| Q11 | Strip taps explain | Waveform/coverage taps show a popover naming the state ("quiet 2:10–2:14 PM", "missing 40 sec — Bluetooth"); navigation stays in lists |
| Q12 | Dark mode during the build | Light-only mockups; derive dark from iOS semantic colors anchored on Part 2 tokens; tune on device |
| Q13 | Pause stops capture on the watch | Pause sends the watch pause request; paused time is its OWN coverage/timeline state (never "missing", never triggers Q9); Resume from card/App Intent; Background audio toggle remains the master switch, Pause its temporary form |
| Q14 | Transcription choice = onboarding step 3 | "On this phone / In the cloud / Later"; Later keeps capturing safely w/ a Today set-up affordance; changeable in Settings |
| Q15 | Cloud live streaming stays | Port the realtime WebSocket providers (Soniox + OpenAI) for live text under cloud modes; on-device local live transcriber remains the offline path |
| Q16 | Times anchor where recorded | Every segment stores its IANA timezone at open; ALL display + day grouping + coverage + 5 AM logical-day boundary use the recorded zone |
| Q17 | Speaker renames = persistent voice identities | The speaker-identity store becomes real: rename applies past+future via diarization identity, with per-conversation override |
| Q18 | Ask answers persist | Ask history in the sheet (recent questions reopen with citations); replaces the old "Recent outputs" |
| Q19 | Migration: audio + transcripts only | First-launch importer reads the old container (`Application Support/audio-companion/segments/*.{spxlog,meta.json}`, `transcription/transcripts/*.transcript.json`); tags/notes/digests/follow-ups regenerate |

## Conventions settled by design (round 3/4)
- Per-conversation delete: ⋯ menu + swipe action, confirm w/ ellipsis, 5 s undo snackbar
  (resolves teardown U12).
- ⋯ menu contents: Rename / Edit Tags / Re-transcribe / Export Audio… / Delete….
- Search results: ≤3 per section with counts + date scoping; sections Tags / Conversations /
  Follow-ups; top row hands the query to Ask.
- Recap card taps through to a cited recap detail (Saved Notes pattern).
- Mockups are a semantic spec: stock SwiftUI/iOS chrome wins over pixel fidelity.
- Coverage-strip taxonomy: violet recorded · gray quiet · amber missing · bare track off ·
  paused as its own state. No captured/transcribed split at day scale (calm).
- One calm line + at most one action per state card; interruptions inline, never banners.
- Vocabulary: "Follow-ups" everywhere (never "Actions"/"Action items"); the §3.7 string set in
  Part 2 is the approved copy inventory; the teardown's banned words (GATT, spool, checkpoint,
  sequence, stream id…) stay diagnostics-only.

## Native-surface plan
v1: complete deep-link route space (every screen addressable); Pause/Resume App Intents +
Control Center control; today-coverage widget (home + lock); Spotlight donation ported
(persistent index this time — old D7). v1.x: Live Activity exception-only (reconnecting/loss —
never a persistent recording activity; the 8 h cap forbids it); Siri/Ask shortcut (define the
App Intents entity model at v1). Skip: watchOS app, share extension, Focus filters.
Evaluation gate before M3: Apple SpeechAnalyzer / Foundation Models vs porting Parakeet/Cactus.

## Anti-goals (teardown findings the build must not recreate)
B1 states without actions · B2 self-contradicting status · B3 side-effect recording enablement
(Connect never flips recording intent silently — consent + explicit start) · B4 markdown leaks
(strict JSON only) · B5 hidden scope switching (Ask scope always visible in the sheet) · B8/B9
placebo settings · B13 plaintext keys · B14 unconfirmed destructive clears · B17 recompose/
disk-read storms (event-driven, DB-observed UI) · B20 raw exception copy (taxonomized errors
only) · B21 threshold misfires (loss notices honor Q9 thresholds + paused/quiet exclusions) ·
U9 vocabulary drift (single string catalog) · U10 floor: Dynamic Type, VoiceOver on
waveform/strip (audio-graph or summary semantics), ≥44 pt targets, localization-ready strings
from day one.

---

# Part 2 — The Design Spec (extracted verbatim from the mockups)

This section is the normative UI spec, extracted element-by-element from the 20 approved
artboards in `docs/redesign/mockups/` (canvas artifact "Audio Companion Redesign"). Where code
and this spec disagree, the artboards win; where the artboards are silent, the conventions in
§2-C apply. Colors are semantic tokens — the hex values are the light-theme values; dark theme
is derived during the build (Q12) from iOS semantic colors with these as the light anchors.

## 2-A. Design system

### Color roles

**Brand / tint**

| Token (light hex) | Role |
|---|---|
| `tint` `#5B5BD6` | Primary violet. Active tab, back chevrons/labels, link-style row actions, filled primary buttons, play button, progress fill, waveform "transcribed" bars, coverage "recorded", selected radio, speaker-you, text caret, sparkle icon, Ask pill text |
| `tintPressed` `#4A4AC4` | Pressed/hover variant |
| `captured` `#B9B9EE` | Light violet: captured/awaiting-transcription waveform bars; live in-progress speaker marker |
| `tintOnDark` `#9F9FF0` | Undo action on the dark snackbar |
| `tintFill10` `rgba(91,91,214,0.10)` | Tinted chip/pill fill (Ask button, tag chips, scope pill, tag-editor chips) |
| `tintFill12` `rgba(91,91,214,0.12)` | Icon tiles; citation chips |
| `tintFill18` `rgba(91,91,214,0.18)` | Search-match highlight |
| `tintBorder` `rgba(91,91,214,0.4)` | Bordered-button and speed-pill borders |

**Status**

| Token | Role |
|---|---|
| `good` `#34C759` | Recording dot, Live badge, healthy sub-lines, toggle ON |
| `goodFill` `rgba(52,199,89,0.12)` | Live badge fill |
| `missing` `#FF9500` | Missing-data encoding: waveform/coverage/scrubber/inline markers. Reserved for data surfaces |
| `missingHair` `rgba(255,149,0,0.35)` | Hairlines flanking inline missing markers |
| `attention` `#FF9F0A` | Status/state dots for attention states (Paused, Reconnecting, stock firmware, bound-elsewhere, transcription failed) |
| `destructive` `#FF3B30` | Red rows/menu items, Stop, Bluetooth-off dot |
| `neutralDot` `#8A8A8E` | Dot for benign non-recording states |

**Four-state audio taxonomy (canonical):** Transcribed `#5B5BD6` · Captured `#B9B9EE` · Quiet
`#D1D1D6` (stub-height bars) · Missing `#FF9500`; coverage track `#ECECF1` = off/not-recording.
Paused renders as its own state, never as missing.

**Grays / surfaces**

| Token | Value | Role |
|---|---|---|
| `label` | `#1C1C1E` | Primary text; snackbar bg |
| `secondaryBody` | `#3C3C43` | Recap/summary/snippet body |
| `tertiary` | `#6E6E73` | Subtitles, descriptions, gray-chip text |
| `meta` | `#8A8A8E` | Metadata, values, section headers, placeholders, inactive tabs |
| `faint` | `#B0B0B6` | Timestamps-of-record, axis labels, quiet markers, provenance |
| `chevron` | `#C7C7CC` | Chevrons, empty circles, grabber, clear glyph |
| `quiet` | `#D1D1D6` | Quiet state |
| `hairline` | `rgba(60,60,67,0.18)` | In-card row dividers (never after last row) |
| `cardBorder` | `rgba(60,60,67,0.22)` | Unselected option cards; transport-button borders |
| `barHairline` | `rgba(60,60,67,0.29)` | Tab/bottom-bar top borders; input borders |
| `fieldFill` | `#E3E3E8` | Search field; progress track |
| `track` | `#ECECF1` | Coverage off-track |
| `grayChipFill` | `#EFEFF4` | Gray tag chips on rows |
| `pillFill` | `#E9E9EE` | Neutral action pills |
| `toggleOff` | `#E9E9EA` | Toggle OFF track |
| `speakerOther` | `#2E9E9E` | Second speaker (teal); you = tint, unresolved = `captured` w/ dimmed text |
| `scrim` | `#8E8E96` | Sheet backdrop |
| `ground` | `#F2F2F7` | Screen background (iOS grouped) |
| `surface` | `#FFFFFF` | Cards |
| `barBg` | `#F9F9F9` | Tab/bottom bars |

### Type scale

| Size | Weights / tracking | Usage |
|---|---|---|
| 34 | 700, −0.4 | Tab-root titles (Today, Library, Settings) |
| 28 | 700, −0.3 | Onboarding headlines; pushed-Settings titles; state-sheet titles |
| 24 | 700, −0.3 | Pushed detail titles (conversation, Recording now, Meeting notes) |
| 20 | 700, −0.2 | In-page section heads (Conversations); sheet titles (Ask, Tags) |
| 17 | 600 headlines/options/Done/Ask-question · 400 back labels/Cancel | |
| 16 | 600 row titles · 400 settings labels, transcript body, search text, menu items | |
| 15 | 600 card heads + button labels · 500 neutral pills · 400 body/values | |
| 14 | 600 small bordered buttons · 500 editable chips · 400 descriptions/snippets | |
| 13 | 600 UPPERCASE +0.4 section headers · 500 chips/Edit/scope · 400 metadata/footnotes | |
| 12 | 600 speaker names · 400 inline markers/micro-meta | |
| 11 | 700 watch-face title · 600 Live badge/citations/card tags · 400 timecodes/provenance/axis | |
| 10 | 600 active tab · 400 inactive tabs, waveform legend | |

Line-heights: 1.5 (answers/notes), 1.45 (onboarding/bio), 1.42 (recap/transcript), 1.4
(footnotes), 1.35 (descriptions). Dynamic Type: these are the `.large` anchors; map to text
styles in code (34→largeTitle, 28→title1, 24→title2, 20→title3, 17→headline/body, 16→callout,
15→subheadline, 13→footnote, 11–12→caption; the 10px legend needs a larger accessibility
representation).

### Spacing, radii, hairlines

- Screen margins 16 (24 onboarding footers, 32 onboarding heroes). Top inset 54. Tab bar
  padding 6/0/24; bottom action bars 10/16/30; sheets bottom 30–34; onboarding footers 44.
- Block rhythm `gap: 12` (14 Ask sheet, 16 Tag sheet, 18–20 heroes).
- Radii: cards 12 (standard), option cards + primary buttons 14, menu 13, sheets 16 top,
  pills 15–18 by height, chips 9–15 by size.
- Card padding `14 16` (content) / `0 16` with `12 0` rows (lists) / `4 16` with `11 0`
  (follow-ups, menu). Hairlines per the color table.

### Component inventory

(Cards: content/list/option. Rows with trailing value+chevron; value-only rows omit chevron.
Five chip kinds: tint filter chip · gray read-only tag · editable tag chip w/ × and a rename
state (white fill, 1.5px tint border, caret) · suggestion chip "+ name" · action pill h36 r18
filled-tint or neutral. Live badge, speed pill, inline citation chip 16×16 r8. Toggles 51×31
iOS-standard, ON green. NO steppers/sliders/segmented controls anywhere — every multi-value
setting is a disclosure row. Buttons: primary filled h50 r14 full-width; in-card filled h40
r11 = "resolves the state"; bordered tint h40 r11 = helper/retry; small bordered h36 r10;
transport bordered-neutral h40 r18 w/ glyph (Stop tints red); circular play 44 and send 36;
text buttons per type table. Status dots 10 (status cards) / 8 (lifecycle+waiting) / 7
(legend). Waveform: h32 container, 40 bars w3 r1.5, justify space-between. Coverage strip:
h12 r6, percentage spans on `track`. Legend: 10px, dot+label ×4. Tab bar h82 per anatomy.
Back rows: inline (settings) vs nav-bar with trailing Share + ⋯ (content details). Sheets:
scrim + grabber 36×5; Ask ≈620pt, Tags ≈430pt. Search field states: resting/active/Ask-input/
add-tag per extraction. ⋯ menu w250 r13 shadowed, destructive last. Undo snackbar dark r12,
message + tinted action, 5 s.)

## 2-B. Per-screen spec

The authoritative element-by-element walkthroughs for all 20 artboards — every element,
its exact copy, and its affordances — live in the extraction below. Key structural facts:

1. **Onboarding · Connect** — hero glyph, "Audio from your Pebble", "Your watch records in the
   background and streams to this phone. You choose where transcription happens.",
   [Connect Watch], "Requires the custom audio firmware."
2. **Onboarding · Confirm** — watch-face mock ("AUDIO COMPANION" / "Allow this phone to receive
   watch audio?" / "Allow ›" / "Decline ›"), "Confirm on your watch", violet waiting dot
   "Waiting for your Pebble…", [Cancel].
3. **Onboarding · Transcripts** (Q14) — "Where should transcripts happen?"; radio cards
   "On this phone — Private. Downloads a 700 MB model on Wi-Fi." / "In the cloud — Fast and
   accurate. You add a provider key." / "Later — Audio is kept safely; transcribe whenever you
   decide."; [Continue]; "You can change this any time in Settings."
4. **Today** — title + Ask pill; status card (dot · "Recording" · Pause link; "Pebble Time 2 ·
   connected"; 40-bar live minute; 4-item legend); coverage card ("4 hr 12 min recorded" ·
   "1 min missing" · strip · 6 AM/noon/6 PM axis); recap card (sparkle · "Today so far" ·
   "updated 12:40 PM" · 2–3 sentence digest); follow-ups card (2 rows + "See all 7");
   "Conversations" section (live row w/ italic rolling snippet + Live badge + chevron;
   finished rows w/ title · time · duration).
5. **Library** — title + "All ⌄" filter; "Search or ask" field; scrolling tag chips w/ counts +
   "more…"; day-sectioned rows (title, meta, optional 1-line summary, optional gray tag chips,
   "mostly quiet" folds into the meta line; Live rows get the badge, no summary).
6. **Conversation** — nav (back "Library" · Share · ⋯); title/meta/summary/tags; player card
   (play, scrubber w/ amber missing tick, times, 1× pill); transcript (speaker-colored turns,
   inline "quiet for 40 sec" and "2 sec missing · Bluetooth hiccup" markers); provenance line
   "Transcribed with Soniox · yesterday 9:54 PM"; bottom bar [Ask][Notes][Follow-ups].
7. **Search** — active field ("travel") + Cancel; "Ask about “travel”" hand-off row; Tags
   section (chip + "12 conversations"); Conversations w/ highlighted snippets; Follow-ups
   matches. Library tab stays lit.
8. **Ask sheet** — grabber; "Ask" + scope pill "Last 2 days ⌄"; question; answer card w/ inline
   numeric citation chips; footer "2 moments · Coffee with Dana, Evening at home" + chevron;
   follow-up composer + send.
9. **Settings root** — watch card (icon tile · "Pebble Time 2" · green "Recording · connected"
   · chevron; "Background audio" toggle); group rows "Transcription & AI — Soniox · GPT-5.6" /
   "Storage & Privacy — 30 days · 383 recordings" / "About You" / "Diagnostics"; footer
   "Recordings stay on this phone unless you choose a cloud provider."
10. **Settings · Watch** — device card w/ battery "78%"; "Firmware — v4.36 · audio companion";
    "Watch reports — Recording"; [Find Watch]; red "Forget This Watch…"; footer "Also revocable
    from the watch: Settings → Audio Companion."
11. **Settings · Transcription & AI** — Transcription: Mode "Cloud first", Local model
    "Parakeet v3 · installed", Cloud provider "Soniox", "Soniox key — saved in Keychain"; AI:
    Mode "Remote first", Model "GPT-5.6 Luna", "OpenAI key — saved in Keychain";
    [Test Connection] w/ green "Connected · 2 min ago"; footer "Set Mode to “Local only” to
    keep everything on this phone." Keys NEVER appear as inline text fields.
12. **Settings · Storage & Privacy** — "Recordings — 383 · 1.2 GB"; "Free space — 9.6 GB";
    "Keep audio — 30 days ›" (REAL control); "Auto-export WAV files" toggle w/ sub-label;
    [Export All Audio]; red "Delete All Recordings…"; footer "You are responsible for
    following local recording laws."
13. **Settings · About You** — top explainer "Helps transcription and AI get names and jargon
    right. Stays on this phone."; bio card + "Edit"; "Contacts — 142 people imported";
    "Calendar — next 3 weeks"; red "Clear Imported Context…".
14. **Settings · Diagnostics** — "Receiver — Recording from Pebble"; "Watch reports —
    Recording"; "Transcription queue — 0 waiting · 0 failed"; Recent segments in plain
    language ("1:12 PM · continued — reattached after a blip"); [Support Report]
    [Detailed Logs]; footer "Counters and gap metadata only — never audio or transcript text."
15. **Tag Editor sheet** (Q10) — "Tags" + Done; chips w/ × plus one shown mid-rename (white
    fill, tint border, caret); "Add tag…" field; Suggestions "+ budget + evening + family";
    footer "Tap a tag to rename it — the rename applies everywhere."
16. **Saved Notes** — nav back to the conversation + Share + ⋯; "Meeting notes"; "Generated
    9:54 PM · GPT-5.6 Luna · from this conversation"; cited bullets; footer "2 moments ·
    9:36 PM, 9:51 PM"; pills [Copy][Edit][Regenerate]. No tab bar.
17. **Live Conversation** — nav back "Today"; "Recording now" + "Started 12:04 PM · 48 min so
    far" + Live badge; growing transcript w/ inline quiet markers and an in-progress line
    (dot speaker `captured`, dimmed text); provenance "Live transcript · on-device · final
    transcript may differ"; transport bar [Pause][Stop(red)].
18. **States · Status Card** — the six status families with exact copy (see vocabulary below);
    rule: dot + headline + ONE calm sentence + at most one action; filled = resolves,
    bordered = helper.
19. **States · Onboarding** — five failure branches (No Pebble found / "This Pebble can’t send
    audio" + [Firmware Guide] / Declined / "Authorized to another phone" w/ watch-side forget
    instructions / timed out), all bordered retries.
20. **States · Conversation** — lifecycle cards (Captured·waiting w/ "3rd in line. Audio is
    safe on this phone." + [Transcribe Now]; Transcribing w/ progress + "Soniox · about a
    minute left"; "Transcription didn’t finish — It retries on its own. The audio is safe." +
    [Retry Now]); the ⋯ menu (Rename / Edit Tags / Re-transcribe / Export Audio… / Delete…);
    the undo snackbar ("Conversation deleted" / "Undo", 5 s).

## 2-C. Cross-screen conventions (normative)

- **Tab bar** on: the three roots, Search, and all five Settings pushes. Off: onboarding,
  Conversation, Live Conversation, Saved Notes, both sheets.
- **Presentation**: pushes for content/settings; sheets for Ask and Tag Editor; Search is the
  Library field's focus state; ⋯ is a popover menu.
- **Ask entry points** (always context-scoped): Today title pill, Search hand-off row,
  Conversation bottom bar. The sparkle glyph is the AI signature everywhere (also marks the
  recap).
- **Tags**: browse/filter in Library + Search; read on rows/detail; mutate ONLY in the Tag
  Editor; renames are global.
- **Destructive**: always `destructive` red text rows or last-menu items, own single-row card,
  trailing ellipsis = confirmation; deletes get the 5 s undo snackbar; never filled red
  buttons.
- **Footnotes**: one plain sentence, 13/meta, below the cards (About You puts it on top);
  provenance is the quieter 11/faint centered in-card class.
- **State cards**: one calm line, at most one action; interruptions render inline where they
  happened, never as top-of-card banners.
- **Status vocabulary**: the extraction's §3.7 list is the complete approved string set —
  copy changes are design changes.

---

# Part 3 — Architecture, the conversation model, and platform rules

## Architecture

**Shape:** fully native Swift/SwiftUI app (Q4), no shared KMP code. The existing KMP modules and
their test suites are the behavioral spec; the protocol golden fixtures are the wire contract.

**Targets & packages** (one Xcode workspace, SPM packages):

- `PebbleAudioKit` (SPM, no UI):
  - `WireProtocol` — message codecs, constants, enums. Validated against `spec/fixtures/` (the
    48 golden fixtures are copied verbatim into the Swift test bundle and must pass byte-exact).
  - `Receiver` — `AudioGattLink` protocol (CoreBluetooth adapter behind it) + `ReceiverSession`
    actor implementing the full session contract (auth incl. pending-consent + enable-request
    arming, single in-flight control token, 5 s keepalive + 15 s liveness expectations, resync
    after 2 missed pings, checkpoint cadence 2 s audio / 500 ms wall, durability ordering:
    append→flush→bookkeep→checkpoint, StreamContext contiguity incl. RESUME base adoption,
    supersede vs in-place-continue rules from commits 1dcc6d0/1e5db02).
  - `SegmentStore` — byte-identical `.spxlog` + `meta.json` formats (incl. `dedupeFloorSequence`),
    recovery, rotation, reattach (relaxed identity, refill + gap-shrink, sorted reads), retention
    (REAL retentionDays wiring this time).
  - `Transcription` — queue (states/backoff/newest-first/open-segment guard), mode router,
    OpenAI + Soniox batch providers, realtime WebSocket providers (Q15), background
    `URLSession` upload coordinator, Speex decode (16 kHz / 320 samples / no header byte).
  - `Intelligence` — annotation/enrichment worker, DailyRecapEngine (5 AM LogicalDay, 30 min
    debounce, settled-day fingerprints), follow-up extraction (strict JSON schema only — the
    lenient markdown fallback is deliberately NOT ported; it caused the `**Owner:**` leak),
    Ask retriever with stable citation numbering + history store (Q18), personal context with
    injection budgets, speaker identity store (Q17 — now real), editable tags (Q10).
  - `Search` — SQLite FTS5 index (persistent on iOS this time — fixes D7) + Spotlight donation.
- `App` target — SwiftUI screens per the mockup spec, @Observable view models, deep-link router
  (every screen addressable — prerequisite for widgets/intents).
- `Widgets` + `Intents` extensions (coverage widget, Pause/Resume App Intents, Control Center).

**Data layer decision:** keep the proven file formats for durable audio + transcripts
(`.spxlog`, sidecar JSON) — the receiver's durability story depends on them and migration (Q19)
becomes a directory read — and add a **GRDB/SQLite index** for everything the UI queries
(conversations, tags, follow-ups, ask history, speaker identities, recaps). The index is
rebuildable from the files; files remain the source of truth for audio/transcripts, the DB for
AI/organizational state.

**Concurrency:** `ReceiverSession` and `SegmentStore` as actors; pipeline stages communicate via
AsyncStream events (replaces the KMP god-object's polling loop with event-driven passes +
a 30 s fallback timer). Diagnostics is a published struct, not a reload key — the UI observes
the DB, never re-reads the filesystem (fixes B17).

## The conversation model (new — defines what the critique flagged as undefined)

A **conversation** is the UX unit; **segments** stay the storage/transport unit. Grouping rule v1:

- Segments chain into the same conversation when: same `streamId` (rotation/reattach chains), OR
  the next segment's start is < 5 minutes after the previous segment's end (any stream id — watch
  reboots/new streams inside a running conversation still group).
- VAD quiet never splits. An explicit Stop/Pause (Q13) ends the conversation. > 5 minutes of
  no-audio ends it.
- Conversations are index rows referencing ordered segment ids; titles/summaries/tags attach to
  the conversation. Per-segment provenance stays visible in the conversation's Details.
- AI topic-splitting within one long chain is a post-v1 refinement (contract allows it later).

## Timezone rule (Q16)

Every segment stores `recordedTimeZone` (IANA id) at open. All display (rows, day grouping,
coverage strip, logical-day recaps) uses the recorded zone. LogicalDay's 5 AM boundary is
evaluated in the recorded zone.

---

# Part 4 — The Port Contract (KMP → Swift, exhaustive)

The KMP modules and their tests are the spec. This part inventories, per area: the behaviors the
Swift implementation MUST reproduce, and the test files that pin them (ported as the Swift test
suite). File paths are repo-relative.

## 4.1 Wire protocol

Normative spec: `spec/audio-companion-protocol.md` (v1; firmware carries a verbatim copy —
version stamps must match). Sources: `core/protocol/.../ProtocolConstants.kt`, `Enums.kt`,
`Messages.kt`, `Decoder.kt`, `Wire.kt` (LE packed primitives — also used by storage for the
`.spxlog` layout). Fixtures: `spec/fixtures/` (48 protocol + 1 Speex), generated by
`tools/gen_fixtures.py` (`--check` gates CI); `tools/fixtures_to_c.py` feeds the firmware test.

**Message set** — GATT service `7C2B0001-9E4D-4FC2-A2B3-1D6E8A1C9F50`; Info `…0002` (Read,
encrypted), Control `…0003` (Write encrypted + Notify), Data `…0004` (Notify); one message per
write/notification, never fragmented, must fit ATT_MTU−3.
Phone→watch: AUTH_REQUEST 0x01 (36+name), AUTH_REVOKE 0x02 (34), CHECKPOINT 0x03 (26),
PAUSE_REQUEST 0x04 (3), RESUME_REQUEST 0x05 (2), RECEIVER_HEALTH 0x06 (8), ENABLE_REQUEST 0x07
(2). Watch→phone control: AUTH_RESULT 0x41 (4), REVOKED 0x42 (2), ACK 0x43 (3), STATE_CHANGED
0x44 (2), ERROR 0x45 (6). Data: STREAM_START 0x80 (40), STREAM_DATA 0x81 (20+frames),
STREAM_GAP 0x82 (26), STREAM_STOP 0x83 (22). InfoSnapshot = 20 fixed, no msg id.

**Codec invariants (each is a test):**
1. Little-endian, packed, no padding (`u64` ULong.MAX → 8×0xFF).
2. Forward compat: longer-than-v1 payloads decode the v1 prefix, ignore the tail; re-encoding
   emits the v1 prefix only (fixture `checkpoint_v2_appended`).
3. Shorter than v1 size → Malformed, never partial.
4. Unknown message ids → UnknownMessage (ignored), never an error — all three channels.
5. Empty buffer → Malformed.
6. Enum fields stored raw (`UInt8`) with nullable typed accessors so unknown future values
   round-trip byte-exactly.
7. AUTH_REQUEST: name_len > 24 or overrun → Malformed; name UTF-8, not NUL-terminated;
   receiverId exactly 32 bytes.
8. STREAM_DATA: frame_count ∉ 1…32 → Malformed; per-frame len > 200 → Malformed; truncation
   anywhere → Malformed; frame *i* has sequence `first+i`, sample index
   `first_sample_index + i*frame_samples`.
9. STREAM_START flags bit0 = RESUME: re-announcement of an ongoing stream — same stream_id,
   codec params, and stream-birth timestamps (post-fw-fix); receivers reattach on stable
   identity (id + codec params), never timestamps.
10. Version negotiation: `granted_proto_version = min(phone, watch)`, meaningful only on
    status 0.

**Constants:** PROTOCOL_VERSION 1 · MAX_ENCODED_FRAME_BYTES 200 · DEFAULT_FRAME_SAMPLES 320 ·
16000 Hz · 20 ms · 9800 bps · MAX_FRAMES_PER_DATA_MSG 32 · MAX_RECEIVER_NAME_BYTES 24 ·
CONSENT_TIMEOUT 60 s · RECEIVER_ID_BYTES 32 · INFO_SNAPSHOT_BYTES 20 · info flags bit0
authorized / bit1 enabled / bit2 consent-pending · codec bitmap bit0 Speex-wideband · receiver
flags LOW_STORAGE 1 / PAUSE_REQUESTED 2 · STREAM_START_FLAG_RESUME 1.
Enums: ServiceState 0–8, CodecId 0x01–0x04, GapReason 0x01–0x08 (`isSilence` ⇔
SilenceSuppressed — load-bearing), StopReason 0x01–0x04, AuthStatus 0–4, AckStatus 0–2,
RevokeReason 1–3, PauseReason 1–3, ReceiverAppState 1–3, ProtocolErrorCode 1–4.

**Golden fixtures (48 = 37 parse · 9 reject · 2 ignore):** each `<name>.bin` (exact bytes) +
`<name>.json` `{channel, expect: parse|reject|ignore, size, fields}`. Port
`GoldenFixtureTest` 1:1: size check, channel dispatch, parse ⇒ decode + re-encode hex-exact
(except `_v2_appended`: v1 encoding must equal the fixture's prefix), field assertions
(snake_case names; `receiver_id_hex` lowercase; `frame_lengths` stringified list), reject ⇒
Malformed, ignore ⇒ UnknownMessage; sanity counts parsed ≥30 / rejected ≥8 / ignored == 2.
Keep `spec/` shared; resolve the fixtures dir from the test bundle. Never hand-edit — regen
via `gen_fixtures.py`, CI on `--check`.

**Speex fixture** `speex_frames_v1.{bin,json}` + `_input.pcm`: 50 records `{u16 len, frame}`,
every frame 25 bytes (fixed-point wideband 16 kHz q6 c1 9800 CBR, 320-sample frames, one frame
per bits_reset); FNV-1a of the file = `0x490aea30` (same constant as the firmware test);
input = 1 s s16le mono, gain ×3. Swift adds a REAL decode test against it (the JVM test could
only check framing).

**Fixture gap to fill:** RESUME re-announce fixtures (incl. fresh-timestamp variants).

## 4.2 Receiver session

Sources: `core/transport/.../AudioReceiverSession.kt` (740 lines — the contract),
`AudioGattLink.kt` (the platform seam — KEEP IT; it is what makes the receiver testable),
`SegmentSink.kt`; iOS reference adapter `adapter/ble-ios/.../IosAudioGattLink.kt`.
Tests: `AudioReceiverSessionTest.kt` (29 cases, virtual time) + `Fakes.kt` (port the fakes).

**Link seam:** `connectionState (Disconnected|Connecting|Ready)`, `lastFailure {kind, detail}`,
`readInfo()`, `writeControl()`, `controlNotifications`, `dataNotifications`, `disconnect()`,
`resync()`. `ConnectFailureKind = BluetoothOff|BluetoothUnauthorized|BluetoothUnavailable|
WatchUnreachable|LinkRejected|Unknown` — classified from CBError/CBATTError codes, NEVER from
localized strings; `LinkRejected` ≈ stale iOS GATT cache after a firmware update (does not
self-heal by retrying cached handles); `detail` is diagnostics-only.

**Session states:** `Disconnected | Connecting | ConnectionFailed(kind, detail?) | Authorizing
| PendingConsent | PendingEnable | Denied(statusRaw) | Authorized | Streaming(streamId) |
Revoked(reasonRaw)`. Published: state, watchInfo, watchServiceState, lastProtocolError,
grantedProtoVersion. Config: receiverId(32, validated), receiverName, protoVersion 1,
checkpointAudioMs 2000, checkpointMinIntervalMs 500, keepaliveIntervalMs 5000,
keepaliveMaxFailures 2; injected nowMs, desiredEnabled, consumeEnableRequestPermission.

**Contract highlights (port everything; the 29 tests are the checklist):**
- Link-state consumption is cancel-on-change (`collectLatest` semantics); teardown always runs
  `onLinkDown()` non-cancellably and forces Disconnected.
- runConnection order: Authorizing → readInfo (decode failure = diagnostics-only) → control
  consumer (stamps lastInboundMs; malformed/unknown ignored) → keepalive → ENABLE_REQUEST
  arming (only when desiredEnabled && watch disabled; requires the ONE-SHOT permission —
  automatic reconnects never prompt the watch; 35 s ack wait; not-acked ⇒
  Denied(DeniedDisabled); acked ⇒ re-read Info) → AUTH_REQUEST.
- Auth: token-matched results only; PendingUserConsent KEEPS the token in flight (watch pushes
  a second result); Ok ⇒ authorized, start the data consumer once, launch reconcileWatchState;
  otherwise Denied fails closed (esp. DeniedMismatch). REVOKED ⇒ close segment Interrupted,
  stop data. STATE_CHANGED safety net: authorized && PausedPolicy && desiredEnabled && policy
  flags 0 ⇒ RESUME_REQUEST (explicitly NOT for PausedPowerSave). ERROR ⇒ publish only.
- One in-flight control token (counter &0xFF); 2 s token wait polling 50 ms; 2 s ack wait; ack
  = ACK(status 0) with matching token; ALWAYS free the slot on timeout/failure (checkpoints
  must never block forever).
- Keepalive: every 5 s when idle (skip when traffic seen within the interval); RECEIVER_HEALTH
  {0,0,0}; 2 consecutive un-acked ⇒ link.resync() and end the loop. Rationale: the watch's
  15 s liveness watchdog (documented in both PROTOCOL docs) stops capture on expiry and
  RESUME-cycles on revival — under-sending keepalives recreates the churn.
- StreamContext: contiguousNext/contiguousSampleIndex checkpoint watermark; pendingRanges
  (persisted past a hole — do NOT advance checkpoint); pendingWatchGaps (advance);
  openWatchGapFrom (unknown extent, resolved by next data); `baseInitialized` false only for
  RESUME (adopt first message's sequence as base — otherwise a bogus multi-thousand-frame
  leading gap strands resumed audio); advanceAccountedPrefix alternates gap/range consumption.
- STREAM_DATA order (load-bearing): guards → ensureBase → advanceAccountedPrefix → stale-
  duplicate check (endExclusive ≤ contiguousNext ⇒ checkpoint + return, no append) →
  **sink.appendFrames FIRST (durability)** → hole handling (open watch gap accounts ⇒ jump;
  else synthesize SequenceSkip gap and do NOT advance) → advance/park → cadence bookkeeping →
  maybeSendCheckpoint.
- STREAM_GAP: always sink.recordGap (store decides durability); zero-count sets
  openWatchGapFrom; known gaps at/below contiguity advance the checkpoint (this is what lets
  long VAD-quiet spans checkpoint without recurring data).
- Checkpoint: due at ≥2 s audio or ≥500 ms wall; skip when nothing contiguous or unchanged;
  token unavailable ⇒ retry next append; payload carries contiguousNext−1, sample index,
  policy flags, free-storage hint; WRITE FAILURE NEVER TEARS DOWN THE STREAM.
- Supersede vs in-place continue (commits 1dcc6d0/1e5db02): RESUME && same open streamId ⇒
  stream=nil but DO NOT close the segment (sink continues in place); anything else ⇒
  closeOpenSegment(Superseded); then always sink.openSegment + fresh StreamContext.
- onLinkDown: close Interrupted → persist ReceiverResumeState → clear auth/token/waiter/
  grantedProtoVersion.
- reconcileWatchState (after every auth): wantPaused = !desiredEnabled || policyFlags≠0;
  pause/resume the watch to match; sends nothing on the common reconnect (idempotent
  watch-side).

**The 29 session tests (port by name):** happyPath_authStartDataCheckpointStop ·
checkpointWriteFailureDoesNotTearDownStreamingSession · pendingConsentThenOk ·
deniedMismatchFailsClosed · skippedSequencesSynthesizeGap_andCheckpointStaysContiguous ·
explicitGapPassThrough_advancesContiguity ·
futureExplicitGapIsAccountedWhenEarlierFramesArriveLater ·
silenceSuppressionGapCanCheckpointWithoutRecurringQuietData ·
disconnectMidStream_closesInterruptedAndPersistsResume ·
reconnectingClearsConnectionFailedState · onlyOneRequestInFlight_checkpointWaitsForAck ·
checkpointCarriesPolicyFlagsAndStorageHint · unknownMessagesAreIgnored ·
revokedClosesSegmentAndStopsConsumingData · requestPauseWritesPauseRequestAndResolvesOnAck ·
requestPauseTimesOutWithoutAckAndFreesTokenSlot ·
authorizingWhileWatchPausedByPolicySendsResume · authorizingWhileUserStoppedPausesTheWatch ·
disabledWatchDoesNotPromptWithoutFreshStartIntent ·
enableRequestWaitsForHumanApprovalBeforeAuth ·
watchPausingByPolicyAfterAuthorizationTriggersResume ·
watchPowerSavePauseDoesNotTriggerResume · sessionTeardownResetsStateToDisconnected ·
resumeStreamAdoptsBaseFromFirstData_noBogusLeadingGap ·
resumeReannounceForLiveStreamDoesNotSupersedeOpenSegment ·
freshStreamStartStillSupersedesOpenSegment ·
resumeStreamWithLeadingOverflowGap_recordsLossOnceAndAdoptsBase ·
keepalivePingsIdleWatchAndAckKeepsLinkAlive · unansweredKeepalivePingsForceResync.

## 4.3 Storage

Sources: `core/storage/.../SegmentStore.kt` (696), `SegmentMeta.kt`, `RetentionManager.kt`,
`FileReceiverResumeStore.kt`. Tests: `SegmentStoreTest.kt` (35 cases) +
`RetentionManagerTest.kt` (4).

**Layout** (root `<container>/Library/Application Support/audio-companion/`):
`segments/<id>.spxlog` + `<id>.meta.json` (+ `.tmp` transients) · `quarantine/` ·
`receiver_state.json` · `upload-bodies/<id>.body` · `transcription/queue|transcripts|uploads/`
· `ai/personal_context.json`, `ai/annotations|outputs|digests|action_items|templates|speakers/`
(· `ai/rules|rule_runs/` = dead).

**`.spxlog` record:** `u32 sequence · u64 sample_index · u16 len · u8 payload[len]`, LE, 14-byte
header, len ≤ 200. Same shape as the firmware spool and STREAM_DATA frame entries.
**Segment id:** `seg-<receivedAtMs>-<streamId 8-hex>-<counter>`.
**meta.json (SegmentMeta):** segmentId, streamId u32, protocolVersion, codecIdRaw, channels,
frameSamples, sampleRateHz u32, bitRateBps u32, frameDurationMs, startTimeMs u64,
startMonotonicMs u64, receivedAtMs i64, firstSequence?, lastSequence?, firstSampleIndex?,
lastSampleIndexExclusive?, frameCount i64, logBytes i64, gaps[GapMeta], closeReason?
{kind stopped|interrupted|superseded|rotated, stopReasonRaw?, finalSequence?,
finalSampleIndex?}, closedAtMs?, transcriptionState
(Pending|Running|Uploading|Complete|NoSpeech|Failed|Disabled), provenance {fwVersionPacked,
protocolVersion}?, **dedupeFloorSequence?** (new). `isFullyTranscribed = Complete|NoSpeech` —
Disabled deliberately NOT terminal. GapMeta: firstMissingSequence, missingFrameCount,
firstMissingSampleIndex, origin "watch"|"sequence_skip", reasonRaw?, watchDropCounter?.
JSON: unsigned fields serialize as unsigned decimals — use UInt32/UInt64 in Codable so the
representation matches (matters for migration).

**Invariants:** temp+atomicMove for every meta write; appendFrames writes THEN FLUSHES (the
checkpoint's durability point); single-writer by design; copy-on-write in-memory meta index
(reads never re-parse disk; recover() rebuilds it once); open-meta flush every 250 accepted
frames AND immediately on any gap refill; `listSegments()` sorted by receivedAtMs.

**Quiet vs loss:** SilenceSuppressed watch gaps are NEVER persisted as loss;
overlapping/adjacent loss extends the previous record (one outage = one gap, newest non-nil
watchDropCounter); normalization drops silence gaps + skip-gaps fully covered by watch ranges,
sorts, refolds.

**Rotation:** 15 min / 16 MB; successor carries `dedupeFloorSequence = lastSequence ??
dedupeFloor` and receive-time anchoring.

**RESUME reattach (the hardening — port exactly):** openSegment: in-place continue when resume
&& same open streamId && canContinue (log the first failing field otherwise, then supersede);
else close Superseded → tryContinueInterrupted → new. canContinue compares streamId +
protocolVersion + codec fields + provenance — NEVER the start timestamps. tryContinue: window
= interrupted && receivedAtMs−closedAt ≤ 10 min; continued meta resets
transcriptionState=Pending, closeReason/closedAtMs=nil; reopen log append;
openedAtMs = candidate.receivedAtMs (keeps the original 15-min rotation budget). Every
continuation failure is logged ("each failed reattach becomes a Library row").
**Timeline anchoring:** mid-stream segments (resume-flag or rotation successors) set
startTimeMs = receivedAtMs; only a stream-birth segment keeps the watch clock.
**Dedupe/refill:** floor = lastSequence ?? dedupeFloorSequence; accept frame when seq > floor
OR inside a recorded gap (refill — the watch retained those for recovery; dropping them then
checkpointing would trim the spool over unrecovered audio); withRefilledSequences subtracts
refilled runs from gaps, splitting middles, recomputing firstMissingSampleIndex; counters use
min/max; **appendFrames returns accepted frames** (Tee forwards only new audio to live
surfaces); `readFrames` sorts by sequence (post-refill logs are unordered on disk).

**Recovery:** delete .tmp; orphan logs → quarantine; parse only when open-at-crash or size
drift; truncate at first bad record (temp+rename); reconcile with min/max counters,
closeReason ??= Interrupted, **closedAtMs ??= now** (crash-interrupted segments must be
reattach candidates after relaunch); normalize gaps; rebuild index.

**Retention:** RetentionConfig 2 GB / 30 d / floors 500 MB (LOW_STORAGE) + 200 MB
(PAUSE_REQUESTED); age cap then size cap (oldest fully-transcribed first, then oldest
untranscribed, never the open segment); callers cascade task/transcript/annotation deletion.
**The Swift build wires retentionDays/size FOR REAL** (the old app's control was placebo —
factories passed the default config).

**Storage tests (35 + 4, port by name)** — the full list in `SegmentStoreTest.kt`, notably the
hardening set: resumeStartWithChangedTimestampsStillReattaches ·
resumeStartForOpenStreamContinuesInPlace · resumeRewindDoesNotDuplicatePersistedFrames ·
resumeStartForOpenStreamWithChangedCodecSupersedes · reattachResetsTranscriptionStateToPending
· crashRecoveredInterruptedSegmentReattaches · reattachKeepsOriginalRotationBudget ·
rotationSuccessorDropsPreRotationRewindsAndAnchorsAtRotationTime ·
resumeOutsideWindowAnchorsNewSegmentAtReceiveTime · rewindRefillFillsRecordedGapAndShrinksIt ·
rewindRefillPartiallyCoveringGapSplitsIt.

## 4.4 Transcription

Sources: `core/transcription/` (queue, processor, router, stores, providers, realtime,
background upload, Speex decode, WAV, resampler).

**Queue:** task JSON {segmentId, state, attempts, retryable, lastError?, createdAtMs,
updatedAtMs, modeUsed?, providerId?, modelUsed?}; enqueue idempotent; **nextRunnable newest-
first** (newest Pending, else newest retryable Failed past backoff); backoff
`min(30 s << clamp(attempts−1,0…6), 30 min)`, MAX_ATTEMPTS 8; Uploading survives restart
(recoverOnStart resets Running only; resetAbandonedUploads reconciles against the transport);
requeue forces Pending w/ attempts 0 (user re-transcribe + reattach); resetDisabled when a
provider appears.

**Processor:** enqueueClosedSegments requeues terminal-success tasks for reattached (grown)
segments; processNext skips OPEN segments (leave Pending) and re-checks after transcribe
(discard + requeue if reopened mid-run); durability order transcript-save BEFORE markComplete;
NoSpeech terminal; ProviderUnavailable ⇒ Disabled; other errors ⇒ Failed retryable;
cancellation rethrows.
Transcript JSON {segmentId, text, modeUsed, providerId, modelUsed?, createdAtMs,
segments[{text,startMs,endMs,speaker?}], words[{text,startMs,endMs}]}.

**Router:** LocalOnly|RemoteOnly|LocalFirst|RemoteFirst; only-modes never fall back;
First-modes fall back with modeUsed = the fallback's Only-mode (provenance honesty);
**NoSpeechDetected is a result, never a fallback trigger**; fallback chains the primary error
(underlyingError); `onRemoteOutcome` fires for every ACTUAL remote attempt only (Ok also on
NoSpeech — the cloud was reached) — feeds CloudHealthMonitor so local fallback can't hide a
broken cloud.

**OpenAI batch:** POST `https://api.openai.com/v1/audio/transcriptions` multipart (model,
response_format json|verbose_json|diarized_json, timestamp_granularities for verbose, optional
personal-context `prompt` — suppressed for models containing "diarize", file audio/wav);
models `gpt-transcribe` / `gpt-4o-transcribe-diarize` (diarize ⇒ speakers, no word timings);
probe GET /v1/models; 24 MB chunking with running chunkStartMs; empty chunk ⇒ NoSpeech.
**Soniox batch:** base `https://api.soniox.com`, model `stt-async-v5`; POST /v1/files →
POST /v1/transcriptions {model, enable_speaker_diarization} → poll GET (2 s × ≤150) →
GET transcript → best-effort DELETE both; 100 MB cap; token→segment grouping gap 800 ms;
probe GET /v1/transcriptions.

**Realtime (Q15):** Soniox `wss://stt-rt.soniox.com/transcribe-websocket`, model `stt-rt-v5`,
config frame {api_key, model, **audio_format:"s16le"** (NOT pcm_s16le — server rejects),
sample_rate 16000, num_channels 1, diarization, context?}; binary PCM frames; end = empty text
frame; accumulator: final tokens → stable transcript (+speaker-grouped segments), non-final →
volatile tail; `finished` ends. OpenAI `wss://api.openai.com/v1/realtime?intent=transcription`,
model `gpt-live-transcribe`, **resample 16→24 kHz linear**; session.update config;
input_audio_buffer.append base64 chunks + commit; delta/completed events; no diarization.
Both: foreground-only, available iff consent+key. Consumer CloudLiveTranscriber: ≤4
reconnects, backoff 1→15 s.

**Background upload (iOS):** queue Uploading state as the coordination token; job store
`transcription/uploads/<jobId>.upload.json` (Uploading | AwaitingControlPlane); bodies written
to `upload-bodies/` (background sessions need file bodies), boundary
`PebbleAudioBoundary-<segmentId>`; concurrency 4; cloud-primary modes only; reconcile on
relaunch (uploader.reconcile, resetAbandonedUploads, finish AwaitingControlPlane, drop
orphans); success ⇒ Done(result) | NeedsControlPlane(state); transcripts saved with
modeUsed=RemoteOnly; maps directly onto URLSession background configuration +
uploadTask(fromFile:) with taskDescription = job id.

**Speex decode:** SpeexCodec(16000, 9800, 320), **no header byte** (unlike official dictation),
one frame at a time, bounded PCM chunks (default 1 s); non-success ⇒ TranscriptionFailed.
Validate against the Speex fixture. `PcmWav.encodeMono16` = standard 44-byte RIFF.

**Tests to port:** router (16) · processor (9, incl. the open-segment/reattach trio) · queue
(14) · transcript store (6) · OpenAI provider (6, incl. WAV header) · Soniox (4, incl.
realtimeConfigUsesSonioxRawPcmFormat) · SonioxContext (2) · realtime accumulators (3+2, incl.
resampler ratio/identity) · background coordinator (3).

## 4.5 AI layer

**Prompts to port verbatim:** `SegmentAnnotationPrompt.kt` (the low-quality-wearable-mic
framing, never-invent rule, tag rules lowercase/TitleCase-proper-nouns/≤4/reusable, no
Markdown; live vs final user prompts; the lenient TITLE/SUMMARY/TAGS parser with its bounds
80/600/32×4). `AiPromptTemplates.kt` — 7 templates + Ask + custom, all under
COMMON_SYSTEM_RULES ("never invent content for gaps…"); DailySummary carries the 5 AM day
framing and no-Markdown rules; **Ask citation rules verbatim** ([n] after the statement,
multiples as [2][5], never raw ids/timestamps/links); ActionItems demands the plain checklist
shape (`- Task. Owner: X. Due: Y.`) or `No action items found.`

**Recap engine:** LogicalDay ROLLOVER_HOUR 5 (compute in the segment's recorded zone per Q16);
15 min loop + post-pass trigger, mutex-serialized; newest day first; settled-day fingerprint
Set<(segmentId, transcriptionState)> ⇒ zero-I/O steady state; digests regenerate only on
genuinely new non-blank transcript content (retention deletions and no-speech never churn);
30 min debounce; excerpts sorted by startTimeMs with local "YYYY-MM-DD HH:mm" timeLabels;
digest id `day-<dateKey>` replaces in the search index. Tests: DailyRecapEngineTest (6) +
digest-donation test.

**Enrichment gates:** final pass (closed + Complete + non-blank durable transcript) beats
live; tagless finals get one structured backfill pass; finalAttempts ≤ 3; live pass only while
open, ≥120 chars first, refresh needs +280 chars AND ≥45 s; closed-but-not-complete keeps
provisional; failures preserve existing content with bumped attempts. Tests:
SegmentEnrichmentWorkerTest (11).

**Follow-ups:** strict JSON schema path ONLY for structured-output providers
(`action_items` schema, additionalProperties:false, all required, empty string = unknown);
the lenient parser is a last resort that must REJECT residual markdown/list structure rather
than clean it (bug B4: `**Owner:**` leaks + numbered fragments shipped as items). Display
composition `task. Owner: X. Due: Y`; ids `<prefix>-action-<i>`.

**Ask:** hybrid retrieval (index hits first, then excerpt stuffing, cap 12 chunks);
**citation numbers keyed to source-segment order** (`citationNumberOf(id) = firstIndex+1`) so
[n] ⇒ output.segmentIds[n-1]; chunk format `[n] [segment <id>@<start>-<end>ms] / GAPS: … /
text`; gap summary injected per segment — Swift MUST use the visible-loss filter here (the
old code summed all gaps incl. silence — bug B7). Port `AnswerCitations` rendering behaviors
(8 tests: truncated-link resolution, adjacent grouping, source-order footnotes,
first-appearance display numbers, dedupe, unresolvable dropped, real links kept, bullets
preserved). Ask history per Q18.

**Personal context budgets:** Soniox context.text 10 000 · OpenAI STT prompt 800
(keyword-list only) · AI grounding block 2 000 (prefix "About the user / known context:",
prepended to system prompts) · ≤40 derived terms; composition caps people 50 / orgs 40 /
topics 40 / vocab 40; gates biasTranscription / groundAi. Tests: PersonalContextTest (4).

**Models catalog:** default `gpt-5.6-luna`, plus terra/sol; legacy replacements
(5.4-nano/mini→luna, 5.4→terra, 5.5→sol); ALWAYS resolve via byId before sending.
`AiModeRouter` mirrors the transcription router; **ConsentRequired never falls back**.
OpenAI chat = Responses API `/v1/responses`, reasoning.effort "low", 240 000-char input
truncation (not rejection), usage tokens captured. On-device provider wraps Foundation
Models bridge (availability 0/2/3), degrades gracefully. Tests: AiModelsTest (5),
AiModeRouterTest (3), OpenAiChatAiProviderTest (8), OnDeviceAiProviderTest (6),
AiEvalHarnessTest (6), SegmentAnnotationStoreTest parse set (7).

## 4.6 Runtime glue, lifecycle, settings

**Keep (as separate Swift services):** the recovery startup order (recover → queue recover →
retention enforce w/ cascade → enqueue → diagnostics); the pipeline pass ORDER (background
early-return → reconsiderDisabled → enqueue → drain processNext under a mutex → enrichment +
donation → recap → local live processOnce/prune → cloud live prune → WAV export → idle model
release — single-instance native model is never used concurrently); adaptive sleep (1 s
worked / 5 s live / else nextRetry clamped 1–30 s; conflated wake channel); the one-shot
armWatchEnableRequest (only explicit Start/Settings taps prompt the watch; resync when
Denied(DeniedDisabled)); stopReceiving's pause-first + resume-if-reenabled-mid-flight race
handling; the delete cascades (segment ⇒ task+transcript+annotation+outputs-sourced-only-
from-it+action-items+digest-membership+index removals incl. `day-<key>`); reprocessSegment.
**Restructure:** the 55-param god object → ReceiverService / TranscriptionService /
EnrichmentService / RecapService / LibraryStore / DiagnosticsService; drop the
diagnostics-keyed disk reload (B17) for observable stores; drop dailyDigestUpdates.

**CloudHealthMonitor:** threshold 3 consecutive failures before surfacing Failed (streaming
paths self-heal); Ok resets; NotConfigured surfaces immediately; explicit Test Connection
publishes immediately and primes the streak on failure. Tests (5).

**iOS lifecycle (port the design + its validation debt):** restoration relaunch applies
receive-only BEFORE the receiver starts (launchedInBackground flag); scene-manifest trap —
register UIApplication notification observers, the app-delegate callbacks never fire;
foreground ⇒ startReceiver (idempotent) + reconcilePendingTranscriptions; background ⇒ stop
waveform decode, release model (interrupt in-flight), hand cloud-primary pending to the
background uploader; BGProcessing task `dev.audiocompanion.app.receiver-processing` (+15 min,
no network/power requirement, chained first) does maintenance ONLY — never STT/AI/export,
never touches receiver run state; expiration cancels optional work only; catch-up burst ≤10
segments, cancellable, model released in non-cancellable finally; memory warning ⇒ release
model; handleEventsForBackgroundURLSession ⇒ uploader reconnect. Model residency: 30 s
foreground idle release; 60 s background loop sleep. UIBackgroundModes bluetooth-central +
processing; NSBluetoothAlwaysUsageDescription; NO microphone entitlement. **Hardware matrix
0/8 — M9 must run it.**

**Settings truth table:** wired = backgroundReceiverEnabled, transcriptionMode,
localTranscriptionModelId, cloudTranscriptionProvider, API keys (→ Keychain in Swift!),
aiMode, aiModel (via byId), automaticWavExportEnabled, onboardingComplete. Placebo/dead (fix
or delete): retentionDays (WIRE IT), retentionMaxBytes (delete), remoteAiConsent (the real
gate is aiMode ≠ LocalOnly), diagnosticsIncludeContent (hardcoded false). Derived semantics
to keep: cloudTranscriptionEnabled/speakerLabels/liveCloud = mode ≠ LocalOnly; remoteAiEnabled
= aiMode ≠ LocalOnly.

**Also port:** `StatusUi.kt` — the pure state→copy layer + visibleLossGaps classifier, 33
tests incl. noProtocolVocabularyInHeadlines and
connectionFailedNeverLeaksRawPlatformErrorAndGuidesRecovery — as the engine behind Part 2's
status-card families. Live constants: monitor window 60 s, SILENCE_RMS 90, DISPLAY_LOUD_RMS
8000, MIN_RECORDED_AMPLITUDE 0.08, decode ≤250 frames/pass (+500 catch-up); LiveTranscriber
chunk 400–3000 frames, backoff 30 s, ≤3 entries; TeeSegmentSink forwards only ACCEPTED frames
and emits open/close boundaries across rotation.

## 4.7 Do NOT port

Rules engine (D1 — store+evaluator complete but zero UI, dead triggers; drop from the loop;
design fresh if ever built) · the AI tab IA (Q2) · LibraryScreen's hand-rolled fuzzy search
engine (keep the behaviors pinned by TranscriptFormattingTest as spec, not the code) ·
ReceiverResumeStore.load-never-called asymmetry (give it a consumer or drop the read path) ·
transcriptionPausedInBackground (surface or delete) · dailyDigestUpdates ·
retentionMaxBytes · remoteAiConsent/diagnosticsIncludeContent as-is · the iOS in-memory
search index + includeFullTranscript=false (D7 — Swift gets a persistent index AND indexes
transcript text; Spotlight donation ported, not regressed) · vendored Cactus extras
(cactusVad/cactusDiarize/RAG/embeddings — pending the SpeechAnalyzer evaluation) · the entire
Compose UI layer · and the confirmed-bug list (B1 B2 B3 B4 B5 B7 B21) as anti-goals.

## 4.8 Migration inputs (Q19)

Old container (bundle id `dev.audiocompanion.app`): read ONLY
`Library/Application Support/audio-companion/segments/*.spxlog` (sort frames by sequence),
`segments/*.meta.json`, `transcription/transcripts/*.transcript.json`. Regenerate everything
under `ai/`. Ignore queue/uploads/bodies/quarantine/receiver_state.
**NSUserDefaults:** `receiver_id_v1` (32-byte id, lowercase hex) is LOAD-BEARING — the watch
stores its SHA-256; reuse it (migrate into Keychain), never regenerate. Migrate surviving
settings keys (`background_enabled`, `transcription_mode`, `local_transcription_model`,
`cloud_transcription_provider`, `openai_api_key`/`soniox_api_key` → Keychain + delete
defaults, `ai_mode`, `ai_model`, `retention_days`, `automatic_wav_export`,
`onboarding_complete`). Use a NEW background-session identifier. Clamp pre-1e5db02
`startTimeMs` against `receivedAtMs`. Leave `Documents/PebbleAudioExports` alone.

---

# Part 5 — Milestones, testing, risks

## Milestones (each gated by tests; commit per milestone)

- **M0 Foundation**: packages, design tokens, deep-link router, DB schema. Gate: builds, tokens
  render a screen gallery.
- **M1 Wire + storage**: WireProtocol + SegmentStore ports. Gate: 48/48 golden fixtures byte-
  exact; SegmentStore suite ported (incl. the 11 reattach/refill tests) all green.
- **M2 Receiver**: CoreBluetooth link + ReceiverSession. Gate: ported AudioReceiverSessionTest
  suite green against a fake link; on-device: connect→consent→stream→blip→reattach as one
  segment (validates against real watch running f91b6e0f3 firmware).
- **M3 Pipeline**: Speex decode, queue, batch providers, background upload. Gate: ported queue/
  processor/router tests; a real recording transcribes via Soniox on-device.
- **M4 App shell**: tabs, Today (all status-card states), Library, conversation grouping,
  Search. Gate: state-family snapshot tests; grouping unit tests.
- **M5 Intelligence**: enrichment, recaps, follow-ups, Ask + history, tags editable, speaker
  identities, notes. Gate: engine tests ported (5 AM boundary, debounce); citation round-trip.
- **M6 Live**: live waveform (four states), live conversation screen, local live transcriber,
  realtime cloud streaming (Q15), Pause/Stop wiring. Gate: on-device live session.
- **M7 Settings + onboarding**: all five settings screens, Keychain keys, three-step onboarding
  incl. every failure branch, model download. Gate: onboarding state walkthrough on simulator.
- **M8 Migration (Q19)**: importer reads the old container (segments/*.spxlog+meta,
  transcription/transcripts/*) → new store; tags/notes/digests regenerate. **Identity is
  load-bearing:** the migrator MUST carry over `receiver_id_v1` from the old NSUserDefaults
  (into Keychain) — the watch stores SHA-256(receiver_id) and a regenerated id fails closed
  (denied-mismatch) until a watch-side Forget Receiver. Also migrate the surviving settings
  keys, move both API keys defaults→Keychain (deleting the defaults entries), use a NEW
  background-URLSession identifier, and clamp pre-fix `startTimeMs` values against
  `receivedAtMs` (data recorded before commit 1e5db02 can carry stream-birth anchors hours
  out of place). Gate: import of a copy of the real 383-recording container; spot-check
  durations/text; connect to the watch WITHOUT re-consent.
- **M9 Native surfaces**: coverage widget, App Intents + Control Center, Spotlight, loss
  notification (Q9 spec), background lifecycle hardening. Gate: BGProcessing + restoration
  matrix on hardware (the matrix the old app never ran).
- **M10 Polish**: dark mode (Q12), Dynamic Type pass, accessibility (VoiceOver on waveform/
  strip via audio-graph/summary semantics), haptics, app icon.

Old app remains installed/usable throughout; the new app ships to G17 at every milestone from
M2 on (side-by-side is safe: single-receiver binding means only ONE app can hold the watch —
during development the new app takes over the binding via watch-side Forget Receiver).

## Testing strategy

- The KMP test suites are the contract: port them class-by-class (fixture tests byte-exact;
  session/store/queue behavior tests re-expressed in Swift Testing with the same case names).
  The session tests REQUIRE virtual time — inject a Clock into ReceiverSession and use a test
  scheduler; never port them to real-time sleeps.
- Port `StatusUi` (the pure state→copy layer + `visibleLossGaps` classifier) with its 33 test
  cases — including `noProtocolVocabularyInHeadlines` and
  `connectionFailedNeverLeaksRawPlatformErrorAndGuidesRecovery` — as the copy engine behind the
  status-card state families.
- Every mockup state family gets a snapshot/preview test (SwiftUI previews double as the state
  gallery).
- The firmware stays untouched; hardware validation gates M2/M6/M9 use the Detailed Logs +
  reboot-trace checks already established.

## Risks / open evaluations

- **SpeechAnalyzer vs Parakeet/Cactus** (native plan): evaluate Apple's on-device speech APIs
  before M3; if quality suffices, the local model path may shrink dramatically (no 700 MB
  download). Decision point at M3 start.
- iOS 26 chrome: mockups are semantic; stock SwiftUI wins. Revisit tokens on the target OS.
- Realtime cloud streaming (Q15) is the most fragile port — schedule after batch path proves out.
- Hardware BLE matrix (restoration, jetsam relaunch) unvalidated until M2/M9 gates.
