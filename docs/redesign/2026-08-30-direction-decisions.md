# Redesign Direction Decisions — 2026-08-30

Roger's answers to the open questions (Q1–Q8) from
`2026-08-30-existing-app-analysis.md`. This is the design contract for the mockups and the
rebuild; revisit only with an explicit new decision.

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

---

**Sequence from here:** churn investigation (Q8) → web-tech mockups honoring Q1–Q7 →
native SwiftUI implementation (Q4) → Android.
