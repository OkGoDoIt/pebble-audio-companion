# Existing App Analysis — 2026-08-30

Full teardown of the current Pebble Audio Companion app (Compose Multiplatform, Android + iOS),
done as step 1 of the ground-up redesign (iOS/SwiftUI first, then Android/Kotlin). Method:

- Read the design docs (`docs/ux-visual-design-plan.md`, implementation plan §6, the guide).
- Mapped the entire UI layer and the entire functional layer file-by-file.
- Built the app for the iOS Simulator (iPhone 17 Pro, no Bluetooth available there) and walked
  every screen of the first-run/empty experience with screenshots
  (kept in the session scratchpad; embedded in the companion HTML report artifact).
- Reviewed 10 real-device screenshots from Roger's phone with live data (383 segments,
  Soniox cloud-first, remote AI configured), which confirmed several code-level findings in
  the wild and surfaced new ones.

Finding IDs (B=bug, U=UX issue, D=dead/half-wired, Q=open question) are stable — use them in
feedback.

---

## 1. What the app actually is today

**On iPhone, nothing is native.** `iosApp/` is a 373-line Swift shell: `ContentView.swift` hosts
one Compose `UIViewController`; the AppDelegate does real work (BGProcessing task, Core Bluetooth
restoration hand-off, Spotlight continuation, FoundationModels bridge) but every pixel of UI is
Compose Multiplatform rendering Material 3 with a custom violet theme. Platform divergence in the
UI is exactly one flag (`isIOS`) used in three places (tab-bar indicator, back-chevron icon,
share icon).

**Structure:** ~7,000 lines of shared UI, 63% of it in three monoliths — `LibraryScreen.kt`
(2,508 lines: list + detail + a hand-rolled fuzzy search engine + transcript timeline builder),
`AiScreen.kt` (958), `SettingsScreen.kt` (897). Navigation is `rememberSaveable` enum state (no
nav graph, no TopAppBar, no snackbars anywhere). `AppActions` is a 60-lambda bag passed by hand —
which is precisely how several wired-but-never-called actions went unnoticed (see §5).

**The engine underneath is genuinely good.** The receiver session
(`core/transport/AudioReceiverSession.kt`) has a careful contiguity/checkpoint model, keepalive +
resync self-healing, and full virtual-time test coverage. Storage
(`core/storage/SegmentStore.kt`) does atomic sidecar writes, truncate-at-first-bad-record
recovery, quarantine, and merges loss gaps into single honest records. The gap taxonomy (VAD
"quiet" is never persisted as loss; real loss is merged, reason-tagged, surfaced to AI prompts as
"never invent content for gaps") is exactly the product's stated differentiator. The AI prompt
discipline (low-quality-mic framing, plain-text output rules, strict JSON schemas) is solid. The
1,041-line `AudioCompanionRuntime` god object and the two ~300-line duplicated platform factories
are the main structural liabilities, not the domain logic.

**Pipeline in one line:** watch GATT service → session/checkpoints → `.spxlog` + JSON sidecars →
newest-first transcription queue (local Parakeet via Cactus, or OpenAI/Soniox cloud incl. iOS
background `NSURLSession` uploads) → enrichment worker (titles/summaries/tags) → daily recap
engine (5 AM logical days) → Ask/templates/action items with citation-grounded answers.

---

## 2. Screen-by-screen walkthrough

### Onboarding (7 steps, gates the app)

Screens: Welcome → Before you start → Permissions → Find your watch → Confirm on your watch →
Privacy choices → Ready.

What it gets right: plain-language framing ("This app never uses the phone microphone"), the
firmware requirement stated up front, honest transcription warning on the privacy step, legal
one-liner without preachiness.

What's wrong (details in §3/§4): every screen is a mostly-empty page with small left-aligned
buttons; two filled primaries compete on most steps ("Grant Permissions" vs "Continue",
"Download model" vs "Continue"); "Continue" always enabled so the wizard never actually gates
anything; permissions give zero result feedback; the scan state never times out or reports
Bluetooth-unavailable; "Privacy choices" is titled "Choose your defaults" but is read-only;
"Skip For Now" is styled as the primary filled button; the checklist has no checks. On the
simulator (no Bluetooth) the app claims "Looking for your Pebble…" indefinitely — the
`CBManager.unsupported`/off state is not represented.

### Today

Status hero card (severity-tinted) + detail lines + one action button, live waveform (60 s) with
a permanent 4-color legend, "Needs follow-up" action items card, "Daily recap" card, then
timeline rows. Empty state is two bare sentences.

Real-device observations: the status card stacks **"Transcription up to date"** directly above
**"2 transcription tasks failed"** (B2); a **1-second** interruption is flagged in amber on the
currently-recording row (B21); the live waveform renders as two disconnected strips with a long
empty middle; recent recordings appear as multiple tiny segments ("Recording now · 10 sec",
"Testing one, two, three… · 25 sec") suggesting reconnect churn is surfaced as card churn (O1).

### Library

Search field + 6 filter chips (All/Today/Actions/AI/Gaps/Untranscribed) + tag chips + card list.
Rows: AI title (or fallbacks), date · time · duration, state badge, summary, tags, gap note,
search-match snippet.

Real-device observations: fallback titles are raw transcript snippets — a row literally titled
**"1, 2, 3. Testing. 1, 2, 3. This is a test"** — and no-speech segments are all titled
**"Conversation"** (U5); a 15-minute "No speech" segment carries an amber "Audio was interrupted
for about 2 sec (watch buffer filled while disconnected)" line — a 2-second blip presented as
the row's most prominent information (B21); the tag chip row clips mid-word ("dinn…"); there is
no grouping by day — just an undifferentiated card stack.

### Segment detail

Back row → title/date/badge → waveform (the only seek control) + legend + "0 sec / 18 min" +
Play/Stop/speed → AI Summary + tags → Ask/Actions/Notes buttons → transcript timeline (speaker
gutters, time pills, "quiet for 40 sec" rows) → Re-transcribe → Details (provenance) →
Interruption details → Delete.

Real-device observations: speed button reads **"1.0×"** (B6); the transcript shows Soniox
artifacts ("wantice cream", "likeice cream") with no affordance to correct/report; the
whole detail is one non-lazy scroll column — an hour-long transcript materializes every row
(B17-adjacent); provenance is honest and good ("Soniox (cloud) · stt-async-v5 · 14 hr ago ·
341 KB").

### AI

Not-configured banner → Action items (checkbox list) → Ask card with suggestion chips → Scope
chips + count → Templates (7 cards whose subtitles are the raw internal prompts) → Custom prompt
→ Recent outputs. Output detail: rendered answer with tappable citations, sources section,
Copy/Share/Export/Edit/Regenerate row, provenance, evidence bottom sheet.

Real-device observations: action items show **literal markdown** — `**Research transcription
timestamps support** — **Owner:** Roger/team` — plus a fragment item "2. a **sorted list by
urgency/importance**." (B4); items are unbounded run-on sentences with no source/date context and
no grouping; the scope was silently on **"Selected · 1 segment"** because a Library segment had
been viewed earlier (B5); suggestion chips clip mid-sentence ("What needs follow…").

### Settings

One giant scroll: WATCH (Status, Watch reports, Background audio switch, Find Watch, Revoke
receiver) → STORAGE & RETENTION (counts, Keep audio stepper, WAV auto-export, Export all, Delete
all local data) → TRANSCRIPTION (Mode, Local model, On-device model, Cloud provider, API key
field, model download, Test connection) → AI (Mode, Model, API key) → ABOUT YOU (free-text
personal context + contact/calendar import) → PRIVACY (two paragraphs) → DIAGNOSTICS (3 counters,
Support report + Detailed logs dialogs).

Real-device observations: **"Status: Connecting to your Pebble" directly above "Watch reports:
Recording"** (B2) while Diagnostics lower on the same screen says "Receiver: Recording from
Pebble"; "Local model: Recommended · 673 MB" vs "On-device model: Installed" reads as two
different models (it's a picker row and a status row for the same thing, U7); the About You box
displays the full personal-context dossier inline in Settings.

---

## 3. Bugs (B)

Ordered roughly by user-facing damage. File refs are to current `main`.

- **B1 — Status actions that render no button.** `Components.kt:148` maps
  `PrimaryAction.Troubleshoot → Unit`, but `App.kt:317` defines what Troubleshoot should do.
  Every state that resolves to Troubleshoot — "This watch is authorized for another receiver",
  "Not authorized", "Bluetooth access is off for this app", "Watch audio needs attention"
  (`StatusUi.kt:94–226`) — shows a headline demanding action with **no affordance**. The worst
  navigational bug in the app.
- **B2 — The app contradicts itself about its own state.** Three confirmed instances: Settings
  shows "Status: Connecting to your Pebble" one row above "Watch reports: Recording"
  (real device); Today's status card stacks "Transcription up to date" above "2 transcription
  tasks failed" (`TodayScreen.kt:191–197` — "up to date" only means "nothing queued"); the same
  card claims "up to date" above an amber "transcription will not run" warning when no provider
  is usable (simulator). For a trust-first product this is the most corrosive class of bug.
- **B3 — "Find My Watch" silently turns on background recording intent (iOS).**
  `MainViewController.kt:149–156`: `pairWatch` → `startReceiver()` →
  `setBackgroundReceiverEnabled(true)` as a side effect. Tapping a "find" button in onboarding
  step 4 flips the consent-adjacent master switch without saying so (default is correctly
  `false` in `AudioCompanionSettings.kt:10`).
- **B4 — Markdown leaks into action items (real device).** Literal `**…**` bold markers and
  numbered-list fragments stored as separate action items. The lenient checklist parser
  (`ActionItemParser`) ingests markdown structure lines; the plain-text prompt rule isn't
  enforced on this path.
- **B5 — Viewing a segment silently hijacks the AI scope.** `App.kt:459` passes the last-viewed
  Library segment as `selectedSegmentIds`; `AiScreen.kt:157–159` auto-switches scope to
  Selected. Confirmed on device ("1 segment in scope · 1 selected"). Every subsequent Ask runs
  against one segment while the user thinks it's Today/All.
- **B6 — Playback speed label renders a raw float** ("1.0×"), `LibraryScreen.kt:2504`. Confirmed
  on device.
- **B7 — Evidence sheet mis-flags quiet as loss.** `AiScreen.kt:844–845` sums *all* gaps incl.
  `SilenceSuppressed`, so normal VAD quiet produces "Some audio was missing here — this moment
  may be incomplete." Violates the quiet-vs-loss contract everywhere else honored via
  `visibleLossGaps` (`StatusUi.kt:302–305`).
- **B8 — The "Keep audio" setting does nothing.** `retentionDays` is persisted and rendered, but
  both platform factories construct `RetentionManager` with default `RetentionConfig()` (30
  days / 2 GB hardcoded). The stepper is a placebo whenever the user changes it.
  `retentionMaxBytes` is fully dead.
- **B9 — Consent/diagnostics settings are vestigial.** `remoteAiConsent` persists but the actual
  remote-AI gate is `aiMode != LocalOnly`; `diagnosticsIncludeContent` persists but
  `buildSupportReport(includeContent=false)` is hardcoded. The AI banner still tells users to
  "enable consent" — there is no consent UI.
- **B10 — AI output Regenerate and Export discard their results.** `AiScreen.kt:535–547` —
  no spinner, no error, no file path. Both look like dead buttons when they fail.
- **B11 — Onboarding shows "Watch found" for denials.** `OnboardingScreen.kt:232–241` only
  special-cases Disconnected/ConnectionFailed/Connecting, so `Denied`, `Revoked`,
  `PendingConsent` display "Watch found" beside an amber warning dot.
- **B12 — Permission grant has no observable result**, and Bluetooth-unavailable has no state:
  the scan claims "Looking for your Pebble…" forever on unsupported/off adapters.
- **B13 — API keys in plaintext prefs, written per keystroke.** NSUserDefaults /
  SharedPreferences, no Keychain/Keystore; `MainActivity.kt:210–217` /
  `MainViewController.kt:363–370` persist + reconfigure the pipeline on every character.
- **B14 — "Clear" (About You) wipes the entire personal context** including imported
  contacts/calendar **without confirmation** (`PersonalContextCoordinator.clear`), while
  less destructive actions do get confirm dialogs.
- **B15 — Cross-tab jumps lose their origin.** Today row → detail whose back button says
  "Library" and lands in Library; same for AI evidence-sheet "Open in Library".
- **B16 — Android: hardcoded light launcher theme** (white flash into dark mode) and no
  edge-to-edge handling with targetSdk 35.
- **B17 — Systemic jank by construction.** 500 ms `nowTick` recomposes the whole tree
  (`App.kt:152–158`); every diagnostics change re-reads every transcript/annotation from disk
  (`App.kt:204–273`); segment detail and AI home are non-lazy columns rendering unbounded
  content.
- **B18 — AI detail action row (5 TextButtons) clips on narrow devices; no wrap/scroll.**
- **B19 — AI output edit mode has no Cancel** (`AiScreen.kt:502–513`).
- **B20 — Raw exception text shown to users** ("Export failed: {message}",
  `LibraryScreen.kt:1258`; "AI failed: …" `:1403`) — the exact vocabulary leak `StatusUi.kt`
  was built to prevent (cf. session 87's `ConnectFailureKind` fix).
- **B21 — Interruption-notice thresholds misfire at the edges.** Session 52 gated minor-loss
  copy on Today, but: a 1 s interruption is still flagged on the open/recording row (no
  transcript text yet → threshold rule passes), and a 15-min No-speech segment leads with a
  2 s buffer blip. The calm-quiet contract fails exactly where attention is highest.

Observations, not yet confirmed as bugs:

- **O1 — Segment churn.** Real-device Library/Today show runs of 10–25 s segments during active
  use. If reconnect/resume churn is fragmenting sessions (rather than the RESUME path
  reattaching), the UI multiplies cards and the recap engine gets confetti. Worth a dedicated
  investigation before redesigning the timeline model.

## 4. UX issues (U)

- **U1 — Nothing about the iPhone app is iOS-idiomatic.** Material switches, checkboxes,
  radio-button alert dialogs, chips, `ModalBottomSheet` with drag handle; no large-title
  collapsing nav; edge-swipe at tab root switches tabs (no iOS app does this); pickers are
  modal dialogs instead of pushed lists/menus; destructive actions are floating red text
  buttons, not red list rows; no context menus, no swipe actions, no pull-to-refresh, no share
  sheet previews. This is the single biggest driver of "clunky" and the core motivation for the
  SwiftUI rebuild.
- **U2 — Button hierarchy is broken everywhere.** Multiple filled primaries per screen
  (Grant Permissions + Continue; Download model + Continue; Save + others), "Skip For Now" as
  the filled primary, lone left-aligned pills floating in whitespace. The design plan's own rule
  ("exactly one filled primary button") is violated on most screens.
- **U3 — Onboarding is 7 taps of low-information ceremony.** Nothing verifies anything (the
  checklist checks nothing, Continue never gates), so the wizard costs seven screens and buys
  almost no configured state. It also fires the notification-permission prompt from a button
  that claims to be about Bluetooth.
- **U4 — Today doesn't answer "what happened today?"** The plan's own bar: "Is my watch
  connected? Is anything being lost? What happened today?" Status is answered (dashboard-first
  is right); the day itself is a flat card stack with the recap buried under action items, no
  time-of-day structure, no sense of coverage vs. quiet vs. loss across the day. The
  permanently-visible waveform legend spends prime real estate re-explaining four colors
  forever.
- **U5 — Library rows have no identity.** Snippet-as-title produces garbage titles; every
  no-speech row is "Conversation"; no day headers; six system-centric filter chips
  (Gaps/Untranscribed are debug concepts); tags clip; no favorites despite the filter being
  designed; sort is fixed newest-first.
- **U6 — Segment detail buries the payoff.** The transcript — the thing the user came for — is
  below waveform, legend, playback, AI summary, and AI buttons; the waveform is the only seek
  control (inaccessible, and imprecise for an 18-min segment); "0 sec / 18 min" reads like a
  bug; Interruption details sit at the very bottom, far from the gap markers they explain.
- **U7 — Settings mixes five different products.** Live status readouts, receiver control,
  storage config, provider config with API keys, a personal-data dossier, legal text, and
  diagnostics in one scroll. Duplicated status rows ("Status" vs "Receiver"), confusable rows
  ("Local model" vs "On-device model"), two identical "Mode" rows in adjacent groups, helper
  paragraphs with three different indents, "Add a OpenAI API key" grammar.
- **U8 — The AI tab exposes plumbing.** Template cards show raw internal prompts as
  descriptions; the Ask button sits disabled with no explanation when unconfigured; action items
  render as an unbounded, ungrouped, undated checkbox wall; Recent outputs renders every output
  ever with no cap.
- **U9 — Vocabulary drift.** "Find Watch"/"Find My Watch"; "Needs follow-up"/"Action
  items"/"Actions"; "Cloud only" (transcription) vs "Remote only" (AI); `...` vs `…`; ASCII
  `->` arrows in user copy; "AI"/"Transcript" as both badges and section titles.
- **U10 — Accessibility floor.** Color-only status dots with no semantics; both waveforms are
  bare canvases (the seek control is invisible to VoiceOver); tag chips ~24 dp tall; hardcoded
  12-hour AM/PM and English month names; zero localization infrastructure; ~7
  `contentDescription`s in the entire app.
- **U11 — Empty states are dead ends.** Bare left-aligned paragraphs, no illustration, no CTA
  (Library's doesn't even offer "start recording" or "check watch").
- **U12 — No feedback layer.** No snackbars/toasts, no undo for any deletion, silent success
  for most actions (Save, Copy), raw errors for failures (B20). Deletes are confirm-then-gone.

## 5. Dead & half-wired inventory (D)

Implemented but unreachable, or reachable but inert. Each needs a kill-or-finish decision before
the rebuild (Q5).

- **D1 — Rules engine**: complete store + evaluator + run log; zero UI; all trigger kinds return
  `false`; Export/Webhook actions are previews. Evaluated (as a no-op) every transcription pass.
- **D2 — Speaker naming**: `FileSpeakerIdentityStore` + runtime APIs never called; UI renders
  "Speaker 1/2" with no rename affordance.
- **D3 — Custom templates**: store + save action wired on both platforms; no composable calls
  it. Custom prompts run one-shot and are discarded.
- **D4 — "Date range" AI scope** = "All" (no picker; `AiScreen.kt:169`).
- **D5 — `ReceiverResumeStore.load()` never called** — resume state written on every close, read
  never.
- **D6 — `transcriptionPausedInBackground`** computed for the UI ("show honest paused status"),
  rendered nowhere.
- **D7 — iOS search index is in-memory only**; empty every launch until enrichment re-donates,
  and `includeFullTranscript` is permanently `false` — index search never sees transcript text.
  (Digest donation, the other half of this finding, was fixed mid-analysis by session 99,
  `7106e60`.)
- **D8 — ~~`AiScreen` takes `dailyDigests` and never renders it~~** — fixed mid-analysis by
  session 99 (`7106e60`): the dead parameter was removed.
- **D9 — Vendored Cactus surface unused**: `cactusVad`, `cactusDiarize`, RAG index, embeddings —
  the app hand-rolls VAD and pays cloud for diarization while shipping native equivalents.
- **D10 — Android parity holes**: no background upload coordinator, no `setForeground(false)`
  caller (Android always runs the full pipeline), no AppSearch↔detail deep links.

## 6. What's worth keeping (the redesign should not discard these)

- The **receiver session** and its checkpoint/contiguity model, keepalive+resync, and tests.
- **Storage durability**: atomic sidecars, recovery, quarantine, gap sparsification.
- The **quiet vs. missing taxonomy** end-to-end (protocol → store → display classifier) — it
  just needs to be applied consistently (B7, B21).
- **`StatusUi` as a pure state→copy layer** and the `ConnectFailureKind` plain-language error
  taxonomy (session 87). This is the right architecture for honest status; the rebuild should
  port it, not reinvent it.
- **AI prompt discipline** (gap honesty, plain-text rules, mic-quality framing, strict schemas)
  and **citation-grounded Ask** with stable source numbering.
- **Daily recap engine** (5 AM logical days, debounce, settled-day fingerprints).
- The **iOS lifecycle design** (restoration → receive-only mode, BGProcessing that can never
  break receiving, jetsam-aware model release) — unverified on hardware (0/8 matrix) but
  correct in shape.
- Provenance everywhere (provider · model · mode · time on transcripts and outputs).

## 7. Design-doc tensions the redesign must resolve

1. **"Native platform behavior wins" vs. the shipped violet brand.** The ux plan mandates
   system colors/dynamic color/8pt radius; session 73 shipped a fixed indigo-violet cross-platform
   theme with 14 dp cards. Both are currently asserted. (Recommendation in Q1.)
2. **Notifications**: §16 says "No notifications or alerts at this time" while §7/§11/§12/§15/§26
   specify permission copy, loss alerts, reminders, and the Android foreground notification.
3. **Consent model leftovers**: "Enable Cloud" actions and a standalone cloud-consent toggle
   survive in §21/§17 from an older model; the real model is mode-driven (and B9 shows the
   remote-AI consent flag is vestigial in code too).
4. **§6.7 of the implementation plan is stale** (Home/Transcripts/Diagnostics IA).
5. **Unspecified features referenced by the UI**: Favorites filter, "Priority (as judged by
   AI)" sort, "Needs attention" sort, "Delete audio only" — designed as chips/options, defined
   nowhere.
6. The plan **predates shipped features** (tags, citations, rolling recap, personal context,
   on-device AI) — the redesign should treat the app + session log as the real spec, with the
   plan as principles.

## 8. Open questions for Roger (before mockups)

- **Q1 — Visual identity.** Recommendation: iOS-native structure (large titles, grouped lists,
  SF Symbols, system materials, real tab bar) with the violet kept only as the accent/tint color
  and the semantic green/amber/red status system preserved. The alternative — carrying the full
  violet brand into custom components — rebuilds today's clunkiness in Swift. Decide before
  mockups.
- **Q2 — Information architecture.** Keep 4 tabs (Today/Library/AI/Settings)? Options:
  (a) keep as-is; (b) 3 tabs — Today, Library, Settings — with AI woven into Today (recap,
  follow-ups) and Library (per-segment actions) plus an Ask entry point in both; (c) 2 + search
  — Today and Library with search/Ask unified. The AI tab currently duplicates content that has
  a natural home elsewhere (action items on Today, per-segment AI in detail).
- **Q3 — The daily loop.** What should the 5-second glance answer? Proposal: connection +
  recording state, today's coverage (a time strip showing recorded/quiet/missing), the recap,
  and open follow-ups. Confirm what you actually check daily.
- **Q4 — Rebuild scope.** Recommendation: keep the KMP core (`core/protocol`, `transport`,
  `storage`, `transcription`, `ai` engines) as a shared framework and rebuild only the app
  shell natively in SwiftUI (the Swift shell already proves the embedding). Full-native Swift
  rewrite of the pipeline is a much bigger, riskier project. Decide.
- **Q5 — Kill or finish** each of D1–D10 (rules, speaker naming, custom templates, date-range
  scope, WAV auto-export…). Default proposal: kill rules + custom templates for v1, finish
  speaker naming (cheap, high value), fix the parity holes.
- **Q6 — Live transcript.** How prominent should live transcription be on Today while
  recording? (Currently invisible until a segment closes, except as row snippets.)
- **Q7 — Settings scope.** Proposal: split into Watch & Recording / Transcription & AI /
  Storage & Privacy / Diagnostics (pushed screens), move the About You dossier behind its own
  screen, move API keys to Keychain with a proper reveal/save flow, and delete the placebo
  controls (B8/B9) or make them real.
- **Q8 — O1 (segment churn)** — investigate before or during redesign? It shapes the timeline
  model.

---

*Companion artifact: designed HTML version of this report with the full simulator screenshot
walkthrough. Progress log entry: session 100 in
`UPSTREAM_THIRD_PARTY_BACKGROUND_AUDIO_IMPLEMENTATION_PLAN.md`. Note: session 99 (`7106e60`,
digest donation + AiScreen dead-param removal) landed in a parallel session while this analysis
was running; D7/D8 above are annotated accordingly.*
