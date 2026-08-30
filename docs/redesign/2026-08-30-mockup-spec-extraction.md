# Mockup Spec Extraction — 2026-08-30

Element-by-element extraction of the 20 approved artboards in `mockups/` (canvas artifact
"Audio Companion Redesign"), produced as the written design record for the SwiftUI rebuild.
The artboard HTML is the ground truth; this document is its prose form. Companion to
`2026-08-30-swiftui-implementation-plan.md` Part 2.

All artboards share: `font-family: -apple-system, 'SF Pro Text', system-ui, sans-serif`,
antialiased, link `#5B5BD6`/hover `#4A4AC4`, root frame 390×844 flex column, overflow hidden.

## 1. Design system

### 1.1 Colors (every value, with role)

Brand/tint: `#5B5BD6` primary violet (active tab, back chevrons/labels, row actions, filled
buttons, play, progress fill, waveform "transcribed", coverage "recorded", selected radio,
speaker-you, caret, sparkle, Ask pill); `#4A4AC4` pressed; `#B9B9EE` captured/awaiting bars +
live in-progress speaker marker; `#9F9FF0` undo action on dark snackbar; `#C9C9F0` onboarding
illustration connector dashes; `rgba(91,91,214,0.10)` tinted chip/pill fill;
`rgba(91,91,214,0.12)` icon tiles + citation chips; `rgba(91,91,214,0.18)` search-match
highlight; `rgba(91,91,214,0.4)` bordered-button/speed-pill borders.

Status: `#34C759` green healthy (recording dot, Live badge, connected sub-lines, toggle ON) +
`rgba(52,199,89,0.12)` Live fill; `#FF9500` amber = missing DATA (waveform/coverage/scrubber/
inline markers) + `rgba(255,149,0,0.35)` its hairlines; `#FF9F0A` amber attention DOTS
(Paused, Reconnecting, stock firmware, bound-elsewhere, transcription failed); `#FF3B30` red
destructive (red rows/menu items, Stop, Bluetooth-off dot); `#8A8A8E` neutral dots for benign
non-recording states.

Four-state audio taxonomy: Transcribed `#5B5BD6` full-height · Captured `#B9B9EE` full-height
· Quiet `#D1D1D6` stub h4 · Missing `#FF9500` h10; coverage track `#ECECF1` = off. Paused is
its own state, never missing.

Grays/surfaces: `#1C1C1E` label + snackbar bg + watch bezel; `#3C3C43` secondary body;
`#6E6E73` tertiary; `#8A8A8E` meta/values/placeholders/inactive tabs; `#B0B0B6` faintest meta
(updated-at, axis, quiet markers, provenance); `#C7C7CC` chevrons/empty circles/grabber/clear;
`rgba(60,60,67,0.18)` row hairlines; `rgba(60,60,67,0.22)` option-card + transport-button
borders; `rgba(60,60,67,0.29)` bar top-borders + input borders; `#E3E3E8` search field +
progress track; `#ECECF1` coverage track; `#EFEFF4` gray tag chips; `#E9E9EE` neutral pills;
`#E9E9EA` toggle OFF; `#D9D9DE` watch strap; `#2E9E9E` speaker-other teal; `#8E8E96` sheet
scrim; shadows `rgba(0,0,0,0.25)` toggle knob, `rgba(0,0,0,0.12)` menu. Backgrounds:
`#F2F2F7` screens, `#FFFFFF` cards, `#F9F9F9` bars.

### 1.2 Type scale

34/700 −0.4 tab-root titles · 28/700 −0.3 onboarding + pushed-Settings + state-sheet titles ·
24/700 −0.3 pushed detail titles · 20/700 −0.2 section heads + sheet titles · 17 (600
headlines/options/Done/question; 400 back labels/Cancel) · 16 (600 row titles; 400 settings
labels, transcript body, search, menu items) · 15 (600 card heads/buttons; 500 neutral
pills/Pause link; 400 body/values) · 14 (600 small bordered buttons; 500 editable chips; 400
descriptions/snippets) · 13 (600 UPPERCASE +0.4 section headers; 500 chips/Edit/scope; 400
metadata/footnotes) · 12 (600 speaker names; 400 inline markers; watch-face 700 Allow) · 11
(700 watch title; 600 Live/citations/card tags; 500 gray chips; 400
timecodes/provenance/axis) · 10 (600 active tab; 400 inactive tabs/legend). Line-heights 1.5
answers/notes, 1.45 onboarding/bio, 1.42 recap/transcript, 1.4 footnotes, 1.35 descriptions.

### 1.3 Spacing, radii

Margins 16 (24/32 onboarding); top inset 54; tab bar pad 6/0/24 (h82); bottom bars 10/16/30;
sheets 30–34 bottom; onboarding footers 44. Block gap 12 (14 Ask, 16 Tags, 18–20 heroes).
Radii: cards 12; option cards + h50 primary buttons 14; menu 13; sheet tops 16. Card padding
`14 16` content / `0 16` + `12 0` rows lists / `4 16` + `11 0` follow-ups & menu. Row gaps 10
(title-value-chevron), 12 (icon-label), 8 (dot-label), 2–3 in stacks.

### 1.4 Components

Content/list/option cards per above. Chevron rows (8×14 `#C7C7CC` stroke-2); value-only rows
omit chevrons. Five chips: tint filter 13/500 on 10% fill r13 `4 11`; gray tag 11/500 on
`#EFEFF4` r9 `2 8` (white fill `3 9` on detail); editable tag 14/500 on 10% r15 `6 12` w/
10×10 ×, rename state = white fill 1.5px tint border `5 11` + 1.5×14 caret; suggestion "+ x"
14/500 white r15; action pill h36 r18 `0 16` filled-tint(15/600 white) or neutral (`#E9E9EE`
15/500). Live badge 11/600 on green 12% r9 `2 8`. Speed pill 13/600 tint-border r12 `3 9`.
Citation chip inline min-w16 h16 r8 12%-fill 11/600 valign 2. Toggles 51×31 r16 pad2, knob
27 white shadowed; ON `#34C759`, OFF `#E9E9EA`. NO steppers/sliders/segmented controls
anywhere. Buttons: primary filled h50 r14 full-width 17/600; in-card filled h40 r11
("resolves"); bordered tint h40 r11 ("helper/retry"); small bordered h36 r10 14/600;
transport bordered-neutral flex-1 h40 r18 w/ glyph (Stop red); circular play 44 / send 36;
text buttons per scale. Dots 10/8/7 by context. Waveform: h32 flex-end space-between, 40 bars
w3 r1.5. Coverage: h12 r6 percentage spans. Legend: 10px, 7px dots, 4 items. Tab bar:
h82 `#F9F9F9` top-hairline, 3 flex columns, 24px stroke icons (Today=5 bars,
Library=calendar, Settings=gear), labels 10; active tint+600. Back rows: inline (settings) vs
nav-bar 54/16/8 w/ trailing Share (20×24 tray-arrow) + ⋯ (3×1.9r dots). Sheets: scrim, r16
top, grabber 36×5 r2.5. Search: resting `#E3E3E8` r10 `8 10` w/ magnifier + "Search or ask";
active + caret 2×18 + clear glyph + external Cancel; Ask input white r20 h40; add-tag white
r10 `9 12`. Menu w250 r13 `0 16` rows `11 0` shadowed, destructive last. Snackbar dark r12
`12 16`, action `#9F9FF0`, 5 s. Progress h4 r2 track/fill; scrubber carries amber 3×6 tick.

## 2. Per-artboard spec

Canvas rows y = 0 / 1000 / 2000 / 3000 / 4000; columns x = 0 / 470 / 940 / 1410 / 1880.

### 2.1 Onboarding · Connect (0,0)
Note (row): "Onboarding is now three steps: connect, confirm on the watch, choose where
transcripts happen (Q14). Permissions are requested in place; privacy is one calm sentence."
Hero: watch→phone SVG (140×72); "Audio from your Pebble" 28/700 centered; "Your watch records
in the background and streams to this phone. You choose where transcription happens." 17
`#6E6E73` max-w300; [Connect Watch] h50; "Requires the custom audio firmware." 13 centered.
Connect Watch starts discovery → Confirm. No tab bar/back.

### 2.2 Onboarding · Confirm (470,0)
Watch mock: straps 148×26 `#D9D9DE`; body 190×190 r22 `#1C1C1E`; white screen with
"AUDIO COMPANION" 11/700, "Allow this phone to receive watch audio?" 13, right-aligned
"Allow ›" 12/700 / "Decline ›" 12 `#8A8A8E`. Headline "Confirm on your watch"; violet 8px dot
+ "Waiting for your Pebble…" 15 `#6E6E73`; [Cancel] 17 tint. Failure branches live in States ·
Onboarding.

### 2.3 Onboarding · Transcripts (940,0)
"Where should transcripts happen?" 28/700 centered. Radio cards: "On this phone — Private.
Downloads a 700 MB model on Wi-Fi." (unselected); "In the cloud — Fast and accurate. You add
a provider key." (SELECTED: 2px tint border + filled check circle); "Later — Audio is kept
safely; transcribe whenever you decide." [Continue] h50; "You can change this any time in
Settings." Single-select; editable later at Settings → Transcription & AI → Mode.

### 2.4 Today (1410,0)
Note: "The 5-second glance: status + live minute, day coverage, recap, follow-ups,
conversations. The live minute keeps the full state story - transcribed, captured-awaiting,
quiet (known silence), missing (no data) - with a small legend. Ask is one tap from the title
bar."
A. Title row: "Today" 34/700 + trailing Ask pill (h32 r16 10%-fill, sparkle + "Ask" 15/600).
B. Status card: green 10px dot · "Recording" 17/600 · spacer · "Pause" 15/500 tint;
"Pebble Time 2 · connected" 13 meta; 40-bar live minute (14 transcribed violet h10–30, 5
quiet stubs h4, 2 missing amber h10, 3 quiet, 16 captured `#B9B9EE` h8–34); legend
Transcribed/Captured/Quiet/Missing.
C. Coverage card: "4 hr 12 min recorded" 15/600 · spacer · "1 min missing" 12 amber; strip
h12 (8% off, 10% rec, 6% quiet, 12% rec, 1% missing, 9% rec, 14% off, 7% quiet, 16% rec, 17%
off); axis "6 AM / noon / 6 PM" 11 faint.
D. Recap card: sparkle 14 + "Today so far" 15/600 + "updated 12:40 PM" 12 faint; body 15/1.42
`#3C3C43`: "Quiet morning. Around noon you worked through the app redesign — simpler
onboarding, conversations instead of segments. Decision: rebuild in Swift."
E. Follow-ups card: circle + "Send Dana the new firmware build" + "See all 7" 13 tint;
hairline; circle + "Book the theater walkthrough for Tuesday".
F. "Conversations" 20/700.
G. Conversations card: live row "App redesign session" 16/600, "12:04 PM · 48 min so far",
italic snippet "“…so the settings pages each push from one clean root…”" 13 `#6E6E73`, Live
badge, chevron; row 2 "Coffee with Dana", "9:12 AM · 24 min", chevron.
H. Tab bar (Today active).
Affordances: Ask→sheet (day scope); Pause↔Resume; circles check off; See-all→full list; live
row→Live Conversation; rows→Conversation; strips tap-to-explain (Q11).

### 2.5 Library (1880,0)
Title + "All ⌄" 13/500 tint. Resting search "Search or ask". Tag chip row: "travel 12" "work
8" "family 5" "dining 3" + "more…". Sections "Today"/"Yesterday" 13/600 uppercase. Rows:
title 16/600; meta 13 (e.g. "7:02 PM · 1 hr 40 min · mostly quiet" — quiet folds into meta);
optional 1-line summary 13 `#6E6E73`; optional gray tag chips; Live rows get badge, no
summary, no chevron; others chevron. Tab bar Library active.
Affordances: All⌄ = scope/filter menu; tag chips filter; search field → Search screen; rows →
Conversation.

### 2.6 Conversation (0,1000)
Note: "Conversations group the tiny transport segments into one card. Interruptions appear
inline where they happened - quiet in gray, missing in amber - never as top-of-card warnings.
AI tags sit under the summary and feed filtering and search."
Nav: back "Library" · Share · ⋯. Header: "Planning work for tomorrow" 24/700; "Yesterday ·
9:35 – 9:53 PM · 18 min" 13; summary 15/1.4; white tag chips work/planning/money. Player:
play 44; scrubber 22% fill + amber tick at 61%; "4:01 … 18:12" 11; "1×" pill. Transcript:
Roger(tint)/Sam(teal) turns 16/1.42; centered "quiet for 40 sec" 12 faint w/ gray rules;
centered "2 sec missing · Bluetooth hiccup" 12 amber w/ amber rules; provenance "Transcribed
with Soniox · yesterday 9:54 PM" 11 faint centered. Bottom bar: [✦ Ask filled][Notes]
[Follow-ups]. No tab bar.
⋯ menu: Rename / Edit Tags / Re-transcribe / Export Audio… / Delete… (red).

### 2.7 Search (470,1000)
Note: "One field does both: results appear as you type (tags, conversations with highlighted
snippets, follow-ups), and the top row hands the same text to Ask as a question. Tapping the
tag filters the Library."
Active field "travel" + caret + clear + Cancel. Ask row: sparkle + "**Ask** about “travel”" +
chevron. "Tags": chip "travel" + "12 conversations" + chevron. "Conversations": rows w/
title/meta/snippet, match term on 18% violet r3 padding 0-2 weight 600. "Follow-ups": circle
+ highlighted text. Tab bar Library active.

### 2.8 Ask sheet (940,1000)
Note: "Ask is a sheet from Today's title button, search, or a conversation - scoped to what
you were looking at. Citations tap through to the exact moment."
Scrim; sheet h≈620. Grabber; "Ask" 20/700 + scope pill "Last 2 days ⌄"; question 17/600
"What did we decide about the trip?"; answer card 15/1.5 with inline citation chips [1][2][2];
footer "2 moments · Coffee with Dana, Evening at home" + chevron; spacer; composer "Ask a
follow-up" + violet send 36.

### 2.9 Settings root (1410,1000)
Note: "Settings root fits one screen. Everything else is a pushed screen; API keys move to
Keychain; the retention control becomes real."
"Settings" 34/700. Watch card: icon tile 36 + "Pebble Time 2" 16/600 + green "Recording ·
connected" 13 + chevron; hairline; "Background audio" + toggle ON. Groups: "Transcription &
AI — Soniox · GPT-5.6 ›", "Storage & Privacy — 30 days · 383 recordings ›", "About You ›",
"Diagnostics ›". Footer "Recordings stay on this phone unless you choose a cloud provider."
Tab bar Settings active.

### 2.10 Settings · Watch (0,2000)
Note (row): "The five pushed Settings screens. Keys show as 'saved in Keychain' with a change
flow, never an inline text field. Diagnostics reads as plain language - 'continued -
reattached after a blip' - not key=value dumps; the raw logs stay behind Detailed Logs."
Back "Settings"; "Watch" 28/700. Device card: tile 44 + "Pebble Time 2" 17/600 + green sub +
"78%" 15 meta. Info card: "Firmware — v4.36 · audio companion"; "Watch reports — Recording".
Action card: [Find Watch] 16 tint. Destructive card: "Forget This Watch…" red. Footer "Also
revocable from the watch: Settings → Audio Companion."

### 2.11 Settings · Transcription & AI (470,2000)
"Transcription": Mode — Cloud first ›; Local model — Parakeet v3 · installed ›; Cloud
provider — Soniox ›; Soniox key — saved in Keychain ›. "AI": Mode — Remote first ›; Model —
GPT-5.6 Luna ›; OpenAI key — saved in Keychain ›. [Test Connection] + green "Connected · 2
min ago". Footer "Set Mode to “Local only” to keep everything on this phone."

### 2.12 Settings · Storage & Privacy (940,2000)
Stats: "Recordings — 383 · 1.2 GB"; "Free space — 9.6 GB". Controls: "Keep audio — 30 days ›"
(REAL); "Auto-export WAV files" + sub "Plain audio copies in the export folder" + toggle OFF.
[Export All Audio]. Red "Delete All Recordings…". Footer "You are responsible for following
local recording laws."

### 2.13 Settings · About You (1410,2000)
Top explainer 13 meta: "Helps transcription and AI get names and jargon right. Stays on this
phone." Bio card 15/1.45 ("Roger — software engineer, former CTO. Planning long-term travel
in Asia. Business partners at the Great Star Theater: Paul Nathan, Red Bettie…") + "Edit" 13
tint. Imports: "Contacts — 142 people imported ›"; "Calendar — next 3 weeks ›". Red "Clear
Imported Context…". (No bottom footer — the explainer is on top.)

### 2.14 Settings · Diagnostics (1880,2000)
Live card: "Receiver — Recording from Pebble"; "Watch reports — Recording"; "Transcription
queue — 0 waiting · 0 failed". "Recent segments": "1:42 PM · recording now — 12 min · quiet
2 min"; "1:12 PM · continued — reattached after a blip"; "12:40 PM · stopped — 30 min · 2 sec
missing". [Support Report][Detailed Logs]. Footer "Counters and gap metadata only — never
audio or transcript text."

### 2.15 Tag Editor sheet (0,3000)
Note (row): "Tag editor (Q10): AI-suggested chips to add, x to remove, rename applies
everywhere. Saved notes keep the citation pattern from Ask - numbered chips tap through to
the exact moment."
Scrim; sheet h≈430. Grabber; "Tags" 20/700 + "Done" 17/600. Chips: "work"×, "planning" in
RENAME state (white, tint border, caret), "money"×. "Add tag…" field. "Suggestions": "+
budget + evening + family". Footer "Tap a tag to rename it — the rename applies everywhere."

### 2.16 Saved Notes (470,3000)
Nav: back "Planning work for tomorrow" · Share · ⋯. "Meeting notes" 24/700; "Generated 9:54
PM · GPT-5.6 Luna · from this conversation" 13. Cited bullets 15/1.5: "Stop for the night;
plan and finish the remaining work tomorrow [1]." / "Roger sends the money plus the extra
piece so it can go faster [2]." / "Sam stays in; shopping and the ice-cream run wait for
lunchtime [2]." Footer "2 moments · 9:36 PM, 9:51 PM" + chevron. Pills [Copy][Edit]
[Regenerate]. No tab bar, no bottom bar.

### 2.17 Live Conversation (940,3000)
Note: "Tapping the Live row opens the live conversation: growing on-device transcript with
inline quiet markers, the in-progress line in light violet, Pause and Stop here rather than
on the status card."
Nav: back "Today" (no trailing actions). "Recording now" 24/700 + "Started 12:04 PM · 48 min
so far" + Live badge. Transcript: Roger turn; "quiet for 2 min" marker; Roger turn; IN-
PROGRESS line (speaker "·" in `#B9B9EE`, text dimmed `#8A8A8E`): "so the suggestions row can
stay under the field…"; provenance "Live transcript · on-device · final transcript may
differ". Transport: [⏸ Pause][⏹ Stop red]. No tab bar.

### 2.18 States · Status Card (0,4000)
Note (row): "The unhappy paths, drawn before code this time (the old app's worst bugs were
undesigned states). Status-card families with exactly one calm line and one action each;
onboarding failure branches including stock-firmware and bound-to-another-phone; the
transcription lifecycle, the overflow menu, and delete-undo. Coverage strip taxonomy: violet
recorded, gray quiet, amber missing, track = off; paused renders as its own state, never as
missing."
Families (dot · headline · line · action): green "Recording" — "Pebble Time 2 · connected ·
live minute shown above" — none · attention "Paused" — "The watch is not capturing. Coverage
shows this as paused, not missing." — filled [Resume] · attention "Reconnecting…" — "Your
Pebble is out of range. It keeps recording and buffers a few minutes." — bordered [Find
Watch] · red "Bluetooth is off" — "Turn on Bluetooth to receive audio from your watch." —
filled [Open Settings] · neutral "Not recording" — "Background audio is off." — filled [Start
Recording] · violet "Confirm on your watch" — "Your Pebble is asking to allow this phone to
receive audio." — none. Rule: filled = resolves; bordered = helper.

### 2.19 States · Onboarding (470,4000)
neutral "No Pebble found" — "Make sure the watch is nearby and Bluetooth is on." — [Try
Again] · attention "This Pebble can’t send audio" — "It needs the custom audio firmware
first." — [Firmware Guide] · neutral "Declined on your watch" — "Nothing was set up. You can
try again any time." — [Try Again] · attention "Authorized to another phone" — "On the watch:
Settings → Audio Companion → Forget Receiver, then try again." — [Try Again] · neutral "No
answer on the watch" — "The request expired after a minute." — [Ask Again]. All bordered
(recoverable).

### 2.20 States · Conversation (940,4000)
Lifecycle (8px dots, 15/600 heads, h36 bordered buttons): captured-dot "Captured · waiting to
transcribe" — "3rd in line. Audio is safe on this phone." — [Transcribe Now] · tint dot
"Transcribing…" — 55% progress — "Soniox · about a minute left" · attention "Transcription
didn’t finish" — "It retries on its own. The audio is safe." — [Retry Now]. Plus the ⋯ menu
(2.6) and the undo snackbar "Conversation deleted" / "Undo" (5 s).

## 3. Cross-screen conventions

Tab bar ON: three roots, Search, all five Settings pushes. OFF: onboarding, Conversation,
Live Conversation, Saved Notes, both sheets. Pushes for content/settings; sheets for
Ask/Tags; Search = the Library field's focus state; ⋯ = anchored popover. Ask entries (all
context-scoped): Today title pill · Search hand-off row · Conversation bottom bar; sparkle =
the AI signature (also on the recap). Tags: browse/filter Library+Search, read on rows/
detail, mutate only in Tag Editor, renames global. Destructive: red text rows/last menu
items, own single-row card, ellipsis = confirmation, undo snackbar for deletes, never filled
red. Footnotes: one plain 13/meta sentence below the cards (About You on top); provenance =
11/faint centered in-card. Speaker colors: you tint, other teal, unresolved captured+dimmed.
Status vocabulary (complete approved set): Recording · Paused · Reconnecting… · Bluetooth is
off · Not recording · Confirm on your watch · No Pebble found · This Pebble can’t send audio
· Declined on your watch · Authorized to another phone · No answer on the watch · Captured ·
waiting to transcribe · Transcribing… · Transcription didn’t finish · Live · Transcribed/
Captured/Quiet/Missing · quiet for N · N missing · Bluetooth hiccup · recording now ·
continued · reattached after a blip · stopped · mostly quiet · N recorded · N min missing ·
N waiting · N failed · Recording from Pebble · Cloud first · Remote first · Local only ·
saved in Keychain · Connected · Conversation deleted · Undo — plus the sub-lines quoted in
§2. Copy changes are design changes.
