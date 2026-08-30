# Redesign Direction Decisions — 2026-08-30

Roger's answers to the open questions (Q1–Q8) from
`2026-08-30-existing-app-analysis.md`, plus the overarching principle P0. This is the design
contract for the mockups and the rebuild; revisit only with an explicit new decision.

## P0 — Overarching principle: **simplify dramatically** (applies to everything below)

Roger, verbatim intent: remove extraneous steps and any extra text that overly explains things;
keep it simple, direct, and easy to use; don't remove functionality — simplify what exists and
the messaging around it; **don't scare-monger around privacy/security**, just make it easy and
direct.

Concretely, for the rebuild:

- Onboarding collapses to the minimum real steps (connect + consent + go); no ceremony screens,
  no checklist-that-checks-nothing, no read-only "choices".
- Helper paragraphs largely disappear. A control's label should carry the meaning; explanation
  lives behind it (footnote, info popover) only when genuinely needed.
- Privacy is stated once, calmly, in plain words ("Stays on your phone unless you choose a
  cloud provider") — not repeated legal-adjacent warnings on every surface. The legal-consent
  line appears once, in Settings, not in onboarding AND settings AND the AI tab.
- Status copy stays honest but short; one line where the current app uses three.
- Every screen should survive the question "what can be removed without losing function?"

## Q1 — Visual identity: **native iOS structure, violet as tint**

Standard iOS structure — large titles, grouped lists, SF Symbols, system materials, real tab
bar. The existing violet (`#5B5BD6` family) survives only as the app's accent/tint color. The
green/amber/red semantic status system is preserved. No custom-branded component shell.

## Q2 — Information architecture: **3 tabs, AI woven in**

Today / Library / Settings. The recap and open follow-ups live on Today; per-segment AI
(ask/actions/notes) lives in segment detail; Ask gets a prominent entry point rather than a
dedicated tab. The current AI tab is dissolved into those homes (its output-detail/citations
surface must land somewhere sensible — likely reachable from Today recap + Library detail).

## Q3 — The Today glance answers **all of it**

All four proposed elements, plus one retained from the current app:

1. Recording + connection state.
2. Coverage across the day (recorded / quiet / missing time strip).
3. The daily recap, promoted.
4. Open follow-ups.
5. **The recent-minute live waveform stays** (Roger explicitly wants to keep it).

## Q4 — Rebuild scope: **full Swift rewrite**

Everything is rewritten natively — including the BLE receiver, storage, and the
transcription/AI pipeline. No shared KMP core in the new iOS app. (Android later gets its own
Kotlin rewrite.) Consequences to plan for:

- The battle-tested logic in `core/transport` / `core/storage` (checkpoint/contiguity model,
  recovery semantics, quiet-vs-loss taxonomy) must be **ported deliberately, with its tests** —
  the existing KMP test suites become the spec for the Swift implementations.
- The wire protocol spec + golden fixtures (`spec/`) become even more load-bearing: the Swift
  receiver must pass the same fixtures.
- Existing on-phone data (segments, transcripts, digests) needs a migration story or an explicit
  fresh-start decision.

## Q5 — Dead features: **finish most of them**

The rebuild completes the designed-but-unfinished surface rather than cutting it:

- Speaker naming (rename "Speaker 1" → a real name) — yes.
- Custom templates (save/reuse) — yes.
- Date-range AI scope with a real picker — yes.
- Rules engine — "maybe a minimal rules UI"; treat as stretch, design for it but it can slip.

## Q6 — Live transcript: **calm preview only**

A one-or-two-line rolling snippet on the current segment's card while recording; full text on
tap. Status stays the hero; no full streaming-text wall on Today.

## Q7 — Settings: **split sub-screens**

iOS-style grouped root with pushed screens: Watch & Recording / Transcription & AI /
Storage & Privacy / Diagnostics. About-you dossier gets its own screen. API keys move to
Keychain with a real save flow. Placebo controls (retention stepper, consent flag,
diagnostics-content toggle) are made real or deleted.

## Q8 — Segment churn: **investigate first**

Before mocking up Today, dig into the receiver/RESUME path to establish whether the 10–25-second
segment runs on Roger's phone are real loss, cosmetic fragmentation, or firmware-side stream
restarts. The answer determines how the new timeline groups and displays segments.

## Round-2 decisions (mockup feedback, same day)

From Roger's mockup feedback: the live minute waveform must keep the full state story
(transcribed / captured-awaiting-transcription / quiet i.e. known silence / missing i.e. no data
received, plus calm hiccup display); a Search screen exists showing the unified search-and-ask
pattern; Today carries an Ask button; **tags stay** — AI-generated, used for filtering and
search (Library chips + row pills + detail pills + a Tags section in search results).

- **Q9 — Notifications: loss alerts only.** One rate-limited notification when audio is actually
  being lost (buffer overflow, dead receiver). Nothing else — no reminders, no recap pushes.
  This resolves the old docs' §16 contradiction.
- **Q10 — Tags are editable.** AI proposes as today; the user can add, remove, or rename tags on
  a conversation, and renames apply everywhere.
- **Q11 — Waveform/coverage taps explain, not navigate.** A tap shows a small popover naming the
  state at that point ("quiet 2:10–2:14 PM", "missing 40 sec — Bluetooth"); navigation stays in
  the lists.
- **Q12 — Dark mode is designed during the Swift build**, derived from iOS semantic colors and
  tuned on device; mockups stay light-only.

---

**Sequence from here:** churn investigation (Q8) → web-tech mockups honoring Q1–Q7 →
native SwiftUI implementation (Q4) → Android.
