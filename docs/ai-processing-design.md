# AI Processing Design & Enhancement Roadmap

AI processing belongs to the third-party audio companion app and runs only from durable
transcripts, segment metadata, and user-visible events. It must never run inside BLE notification
callbacks and must never require the official Pebble mobile app.

This document is both the **AI design contract** (the invariants every AI feature must respect) and
the **multi-phase roadmap** (what we build next and in what order). It is architecture-level, not
line-by-line: it names the modules, data models, frameworks, and sequencing so a future session can
pick up a phase and design the low-level details with full context.

Companion documents:
- `docs/ux-visual-design-plan.md` — §10 (AI Screen), §19 (AI UX), §11 (Settings) product/UX intent.
- `UPSTREAM_THIRD_PARTY_BACKGROUND_AUDIO_IMPLEMENTATION_PLAN.md` — running progress log (newest
  first). Sessions 59–61 added auto annotations, on-device AI, and this roadmap.

---

## 0. Vision, positioning, and principles

**Vision.** A private, honest **second memory**: a calm, queryable life log plus an assistant that
turns captured conversations into recaps, answers, and gentle automation — where the user owns the
data and most processing runs on-device.

**Positioning (why this wins).** The 2026 market consolidated and *retreated from privacy*: Rewind
became Limitless with a "Confidential Cloud" (audio leaves the device) and was acquired by Meta; Bee
was acquired by Amazon. The loudest, most repeated user complaints across all of them are **privacy,
phone/device battery drain, and transcription accuracy on real-world audio**. We are structurally the
**anti-Limitless**: local-first, on-device AI already shipped (Session 60), power-careful firmware,
honest about gaps, no audio to anyone's cloud by default. Every feature below must preserve that.

**Principles (carry into every phase).**
1. On-device by default; cloud only as explicit, per-surface opt-in with visible provenance.
2. Honesty over cleverness: never hide gaps; never invent content; always cite sources for answers.
3. Calm and reviewable: no hidden automation, no silent sharing; the user does as much or as little
   as they want.
4. Degrade gracefully: every capability must no-op cleanly on unsupported OS/device (the pattern
   established for on-device AI in Session 60).
5. Cheap by default: prefer on-device models and the OS's own indices over bespoke cloud infra.

**Routing & consent invariants (unchanged).**
- All AI routes through `AiProcessingMode` (`LocalOnly`, `RemoteOnly`, `LocalFirst`, `RemoteFirst`)
  via `AiModeRouter`.
- Remote providers require explicit AI consent. Consent failures do **not** fall back to another
  provider (fallback can still violate the user's intent). Cancellation never falls back.
- On-device providers need no consent (data never leaves the device) and back `LocalOnly`/the local
  half of the `*First` modes.

---

## 1. Where we are today (grounding)

Built and shipped (the former "MVP" of this doc, now done):
- **Auto per-segment annotation** — short title (Today) + medium summary (Library detail), live +
  final passes. `app/.../SegmentEnrichmentWorker.kt`, `core/ai/.../SegmentAnnotationStore.kt`,
  `SegmentAnnotationPrompt.kt`.
- **Provider stack & routing** — cloud OpenAI (`core/ai/.../OpenAiChatAiProvider.kt`) + on-device
  (`OnDeviceAiProvider.kt` → Apple Foundation Models / Android Gemini Nano) behind
  `AiModeRouter.kt`; user model picker; `AiTranscriptFormatting` shared input builder.
- **Manual AI workspace** — `app/.../ui/AiScreen.kt`: scope Today/All, the built-in templates
  (summary, meeting notes, action items, decisions, follow-up email) + custom prompt, outputs saved
  with full provenance (`AiOutputStore.kt` — segment ids, prompt template id/title, provider/model,
  token counts, routing mode, timestamp, consent flag), delete.
- **Transcription substrate** — local (Cactus/Parakeet) + cloud (OpenAI/Soniox), live streaming,
  **Soniox diarization (per-token speaker labels already produced)**, explicit gaps.
  `core/transcription/...`.

Designed (ux plan) but not built — the backlog this roadmap sequences: richer scopes, "Ask" Q&A,
saved custom templates, output edit/copy/export/share/regenerate, the Rules Engine,
study-notes/interview templates, deep OS integration, and the personal-context system.

---

## 2. Cross-cutting foundations

Dependencies of multiple phases — build as shared infrastructure, not per-feature. They live mostly
in `core/ai` (and a new `core/search`/`core/knowledge` module).

### 2A. Personal Context Store (the "facts about the user" system)

A single, user-owned store of background facts that improves **both transcription accuracy** (via
provider context/biasing) **and AI quality** (via system-prompt grounding), especially on low-quality
audio. Highest-leverage foundation: it makes everything else better and is largely provider-agnostic.

**Data model (new, in `core/ai`)** — `PersonalContext`, durable, file-backed via the atomic
temp-file+rename pattern used by `FileSegmentAnnotationStore`:
- `profileText: String?` — free-form bio/resume/"about me" the user pastes.
- `people: List<KnownPerson>` — name, aliases/nicknames, relationship, role, org; later linked to
  speaker identities (Phase 3).
- `terms: List<VocabTerm>` — proper nouns, product names, jargon, acronyms (text + optional
  pronunciation hint).
- `places`, `orgs`, `topics` — light entity lists.
- `sources: List<ContextSource>` — provenance per fact (manual / contacts / calendar / derived),
  each independently deletable and consent-gated.
- per-use `enabled` flags (bias transcription? ground AI? both?).

**How it feeds the pipeline (concrete injection points):**
- **Soniox real-time & async** — Soniox exposes a first-class `context` object: *general
  information* (key/value: participant names, org, setting), *terms* (custom vocabulary, ~8,000
  tokens), *text context* (large free-form block — perfect for the pasted profile/glossary), and
  *translation terms*. Inject in `SonioxRealtimeProvider.configJson()` (today builds `api_key/model/
  audio_format/sample_rate/num_channels/enable_speaker_diarization/language_hints`) and the equivalent
  config in `SonioxTranscriptionProvider`. Biggest single accuracy win for proper nouns/names on a
  bad mic.
- **OpenAI transcription** — `gpt-4o-transcribe`/realtime accept a `prompt` for keyword/vocab
  steering. Caveats from research: realtime caps prompts at **1024 tokens**, prefer **short keyword
  lists over prose**, and on near-silent/short chunks the model can *hallucinate glossary words from
  the prompt* — so feed a *bounded, relevant* term list (not the whole profile) and keep it small.
  Inject in `OpenAiTranscriptionProvider` / `OpenAiRealtimeProvider`.
- **Local STT (Cactus/Parakeet)** — no biasing API today; skip, or post-process with a term-aware
  normalize pass (optional, low priority).
- **AI processing** — prepend a compact "About the user / known people & terms" block to the system
  prompt in `OpenAiChatAiProvider`, `OnDeviceAiProvider`, and the annotation prompts
  (`SegmentAnnotationPrompt`). Keep it short for on-device context windows (Foundation Models
  `contextSize` is small; Gemini Nano similar) — summarize the profile to a budget.

**Ingestion UX (effortless; do as much or as little as you want):**
- **Paste** — Settings → "About you" text box (profile/resume/notes). Zero friction, no permissions.
  Ship this first.
- **Import (consented, optional):**
  - iOS **Contacts** (names/nicknames/relationships → people & vocab) and **EventKit** Calendar
    (attendee names, meeting titles, orgs → terms + per-segment context by time window). Use Apple's
    *limited/add-only* access tiers and request access *only when the user taps the import feature*
    (research: just-in-time, intent-linked requests are far more likely to be granted; Privacy
    Manifest is mandatory).
  - Android **Contacts** and **Calendar provider** equivalents, same consent discipline.
  - Each imported fact is tagged with its `ContextSource`, shown in a reviewable list, individually
    deletable, and never re-uploaded — on-device unless the user is already using a cloud provider.
- **Derived (later)** — frequently-heard names/terms surfaced from transcripts as *suggested* vocab
  the user can accept (ties into Phase 3 people memory).

**Privacy:** the store is local; importing is opt-in per source; deleting a source removes its facts;
delete-all wipes it. When a cloud provider is in use, only the minimal needed slice (e.g., the term
list) is sent, with provenance shown.

### 2B. On-device retrieval & embeddings (the RAG substrate) — *and the OS-index synergy*

"Ask" (Phase 2) and people/topic memory (Phase 3) need retrieval over transcripts. **Key insight: the
OS search indices we want to populate for OS integration (Section 6) double as our retrieval
backend**, so we get most of RAG "for free" and avoid bespoke infra:
- **iOS**: Core Spotlight gives full-text + (recent iOS) **semantic search**; iOS 26 adds
  `SpotlightSearchTool`, a Foundation Models *tool* that lets the on-device model query our Spotlight
  index directly during answer generation. Donating transcripts/segments powers both system search
  *and* on-device Q&A.
- **Android**: **AppSearch** (Jetpack) is an on-device full-text index with BM25F scoring and
  multilingual support — our retrieval layer and the system-search donation in one.

For *semantic* retrieval beyond keywords (and the knowledge graph), add embeddings:
- **iOS**: `NLContextualEmbedding` (Natural Language framework) — on-device, sentence-level, 512-dim,
  no model download.
- **Android**: **MediaPipe Text Embedder** (Gecko embedder runs fully on-device) / ML Kit GenAI / AI
  Edge RAG building blocks.
- **Cloud (opt-in only)**: OpenAI `text-embedding-3-small` for higher quality / cross-device, gated
  by remote AI consent.

**Vector storage:** start simple — cosine over a file-backed vector list for small scopes (a day/week
is tiny). Graduate to HNSW for whole-history: **ObjectBox** (on-device vector DB with HNSW, Kotlin/
Java SDK) or **SQLite + sqlite-vec**. Embedding dims differ per platform, so store platform-tagged
vectors (single-device, so fine). New module suggestion: `core/search` with a `TranscriptIndex`
interface and per-platform backends, mirroring the `OnDeviceLanguageModel` bridge pattern from
Session 60.

**Retrieval strategy:** hybrid — OS full-text (BM25) for recall + embeddings for semantic re-rank,
fused, then stuff top-k chunks into the LLM with citations. Chunk by segment and by speaker-turn;
carry segmentId + timestamp on every chunk so answers cite back to the timeline.

### 2C. Evaluation harness

Before tuning prompts/models across providers, add a small offline eval (in `core/ai` tests) over a
fixture set of (transcript → expected title/summary/answer) so we can compare gpt-5.5 vs mini vs
on-device and catch regressions as surfaces expand. Cheap insurance.

---

## 3. Phase 1 — Make Today Useful (low-hanging fruit)

Immediate "didn't ask for it but needed it" value, reusing existing summaries/templates. Mostly
app-layer + the existing `AiModeRouter`.

1. **Daily Recap.** Aggregate per-segment summaries into one end-of-day digest (chronological, with
   times; reuses `AiPromptTemplates.DailySummary`). New worker analogous to `SegmentEnrichmentWorker`
   running on day rollover / on demand; new `DailyDigest` store; a Today card + Library "Days" view.
   The single most-loved competitor feature.
2. **Action items as a first-class list.** Auto-run the `ActionItems` template per day/segment;
   render a checklist with source links and done-state. Store as a typed output, not free text. The
   foundation for integrations (Phase 4).
3. **Finish output detail actions.** Copy / share / export / regenerate / edit (ux plan §19; today
   only delete in `AiScreen.kt`). Pure UI over data already in `AiOutputStore`.
4. **Topic tags in the annotation pass.** Add `tags: List<String>` to `SegmentAnnotation`; ask the
   model for 2–3 tags alongside title/summary (one field, near-zero marginal cost). Enables filtering,
   better search, and Spotlight/AppSearch keywords (Section 6).
5. **Richer scopes + saved custom templates** in `AiScreen` — selected segment(s), date range; persist
   user prompts as reusable templates (extend `AiPromptTemplates`/a templates store).
6. **More templates** — study notes, interview highlights (ux plan §19).

Dependencies: none beyond what exists. Personal Context (2A) improves these but isn't required.

---

## 4. Phase 2 — Make It Queryable ("Ask your day / your life")

Natural-language Q&A over transcripts with citations. The flagship, on-device-first feature.

- **MVP (no new infra):** "Ask" box scoped to a day/range; stuff that scope's transcripts into the
  router (on-device or cloud) and return an answer with segment citations + gap warnings. Works today
  for bounded scopes; reuses `AiModeRouter` + provenance patterns.
- **Scale to whole history (uses 2B):** hybrid retrieval over the OS index + embeddings, top-k into
  the LLM. On iOS 26, optionally let Foundation Models call `SpotlightSearchTool` so the model
  retrieves from our Spotlight index itself.
- **UX:** conversational; every claim links to its source segment/time; "I don't have audio for that
  window" when gaps matter; never fabricate. Save Q&A as `AiOutput` with provenance.

Dependencies: 2B (retrieval) for the at-scale version; Personal Context (2A) sharpens answers.

---

## 5. Phase 3 — Make It Personal (people & knowledge memory)

Turn the diarized stream into durable, useful memory about people and topics.

- **Speaker naming.** We already get per-segment speaker labels from Soniox
  (`SonioxRealtimeAccumulator`, `TranscriptSegment.speaker`). Let the user *name* a speaker once
  ("Speaker 2 = Sarah") and propagate; persist a `SpeakerIdentity` linked to `KnownPerson`. Optional
  later: on-device voice fingerprint to auto-recognize across sessions (privacy-sensitive — on-device
  only, opt-in, deletable).
- **People & topic memory.** Per-person/per-topic rollups ("what did I discuss with Sarah", "every
  time we mentioned pricing") built from retrieval (2B) + light entity extraction. Surfaces as Library
  facets and enriches `KnownPerson`, which *also* feeds transcription context (2A) — a virtuous loop
  (better names → better transcripts → better memory).
- **Personal knowledge graph (light).** People ↔ topics ↔ commitments ↔ segments. Small and honest;
  powers Phase 4 triggers and richer "Ask".

Dependencies: 2A (people store), 2B (retrieval), diarization (have it).

---

## 6. Phase 4 — Make It Act (Rules Engine + integrations)

User-authored, reviewable automation. The rule model (kept from the original design):

```text
trigger -> condition -> action
```

Examples:
- Daily summary at 18:00 -> transcripts exist for today -> create summary output.
- Keyword/topic trigger -> "pricing" discussed -> create action-item extraction.
- Meeting-window trigger -> calendar-linked segment range -> create meeting notes.
- User prompt over a time range -> explicit run -> save and optionally export.

**Cost controls (required before launch):** max runs/day, token budgets, provider allowlist, quiet
hours, clear failure/retry visibility.

**UX guardrails:** no hidden auto-sharing; no default remote execution; every rule has a visible run
history; failed rules explain why and how to fix.

**Integrations (outputs leave only on explicit action):** Apple **Reminders/Calendar** via EventKit
(add-only tier where possible) for action items; Android tasks/calendar equivalents; Obsidian/Notion
export; generic webhook. Action items from Phase 1 become the payload.

Dependencies: Phases 1–3 for content; the consent/cost framework above.

---

## 7. Deep OS integration (parallel track — lands incrementally across phases)

A major differentiator and an explicit priority: be as deeply woven into the phone OS as possible.
Most of this also serves retrieval (2B), so prioritize it early.

### iOS
- **Core Spotlight donation.** Index segments (and optionally day digests / AI outputs) as
  `CSSearchableItem`s with `CSSearchableItemAttributeSet` (title = AI title, contentDescription =
  summary, keywords = tags, `startDate`/`contentCreationDate` = capture time, `lastUsedDate` on view).
  Use **batched indexing with client state + the `isUpdate` flag** to avoid over-donation. Store the
  segmentId as the item's unique id so a Spotlight tap deep-links into Library detail (via
  `NSUserActivity`/deep link).
- **App Intents + `IndexedEntity`.** Model a `SegmentEntity` (and `DayDigestEntity`); adopt
  `IndexedEntity` (or `associateAppEntity` on existing searchable items) so entities appear in
  Spotlight *and* Siri/semantic search understands them. Gateway to:
- **Shortcuts & "Use Model" (iOS 26).** Expose intents like "Summarize today", "Ask my day",
  "Recap last meeting" as App Shortcuts; users compose them with the system **Use Model** action.
- **`SpotlightSearchTool` (iOS 26).** Let Foundation Models query our Spotlight index during
  on-device answer generation — directly powers Phase 2 "Ask" with zero custom retrieval on iOS.
- **App Intents 2.0 niceties (opportunistic):** interactive snippets (e.g., a recap snippet), Visual
  Intelligence, entity view annotations. Lower priority.
- **Widgets / Control Center control** for "today's recap" and "ask" (later).
- **Compliance:** Privacy Manifest; just-in-time consent for Contacts/Calendar; honor an
  "exclude from system search" toggle; never donate content marked private.

### Android
- **AppSearch (Jetpack).** Schema types for `Segment`, `DayDigest`, `ActionItem`; index on-device
  with BM25F. Serves both system-search donation and our retrieval layer.
- **App Functions API (Android 16).** Expose capabilities ("summarize today", "ask my day") to the
  system Assistant via the AppFunctions Jetpack library — Android's analogue to App Intents.
- **Dynamic Shortcuts → Assistant.** `ShortcutManagerCompat.pushDynamicShortcut` +
  `core-google-shortcuts` to surface voice-launchable shortcuts; ≤4 visible launcher shortcuts,
  unlimited pushed to Google surfaces.
- **Live Updates / progress notifications (Android 16).** `Notification.ProgressStyle` for long
  operations (model download, batch transcription/recap); requires `POST_PROMOTED_NOTIFICATIONS`.
- **Widgets / Quick Settings tile** for recap/ask (later).

### Cross-platform notes
- Donation is downstream of durable transcripts/annotations (never from BLE callbacks), so it slots
  in after `SegmentEnrichmentWorker` writes an annotation.
- Add per-item and global **"exclude from system search"** controls. Default to indexing only AI
  title/summary/tags; a setting may additionally index full transcript text for power users (off by
  default — full transcripts in the OS index is a deliberate privacy choice).

---

## 8. Sequencing, dependencies, milestones

Each milestone is independently shippable:

1. **M1 — Personal Context (paste) + Soniox/OpenAI context injection (2A).** Highest accuracy
   leverage, low effort, no new infra, benefits everything downstream. Paste box first, then provider
   context.
2. **M2 — Phase 1 quick wins:** Daily Recap, action-item list, output actions, tags, scopes/templates.
3. **M3 — iOS Spotlight + Android AppSearch donation (Section 6 core).** Serves OS integration *and*
   becomes the retrieval backend; do before/with Phase 2.
4. **M4 — Phase 2 "Ask"** (MVP scoped, then retrieval-backed via M3 + embeddings 2B).
5. **M5 — Personal Context import (Contacts/Calendar) + Phase 3 speaker naming & people memory.**
6. **M6 — App Intents/App Functions + Shortcuts/Use Model + Live Updates** (deepen OS integration).
7. **M7 — Phase 4 Rules Engine + integrations (Reminders/Calendar/export/webhook).**
8. **Cross-cutting throughout:** eval harness (2C), privacy controls, graceful degradation.

Dependency summary: 2A is independent (do first). 2B/Section 6 are intertwined (OS index = retrieval)
→ do together before Phase 2 at scale. Phase 3 needs 2A+2B. Phase 4 needs Phases 1–3 content.

---

## 9. Privacy (invariants, expanded)

- Encoded audio retention is controlled separately from transcript and AI-output retention.
- Diagnostics and support bundles exclude audio, transcript text, and AI output text by default.
- Remote AI calls require explicit provider consent and show provider/model provenance.
- **Delete-all** must delete audio segments, transcripts, transcription tasks, AI outputs, queued
  runs, **and every new store this roadmap adds** (Personal Context, DailyDigest, ActionItems, the
  vector index, donated OS search items).
- Each new source (Contacts, Calendar) and each OS donation is a privacy decision: just-in-time
  consent, per-source delete, exclude-from-index toggle, full-transcript indexing opt-in only.
- Voice fingerprinting (Phase 3) is the most sensitive feature: on-device only, opt-in, deletable;
  consider deferring until people-by-name memory proves valuable.

---

## 10. Risks & open questions

- **On-device context windows are small.** Foundation Models / Gemini Nano have limited `contextSize`;
  budget/summarize the personal-context block and RAG stuffing. Use tight term lists + top-k
  retrieval, not whole transcripts.
- **STT prompt hallucination.** OpenAI realtime can emit glossary words on silent/short chunks; keep
  injected term lists short and relevant; validate against Soniox behavior.
- **Embedding portability.** Per-platform embedders differ in dimensionality; the index is
  single-device by design (no cross-device vector sync) — acceptable, document it.
- **OS API availability/versioning.** `SpotlightSearchTool`/App Intents 2.0 need iOS 26; AppFunctions/
  Live Updates need Android 16; AppSearch/Core Spotlight/embeddings are broadly available. Gate new
  APIs behind availability checks; keep the base experience working everywhere (Session 60 pattern).
- **Cost control.** Cloud paths need the Rules Engine budget controls before any automation ships;
  on-device-first keeps default cost at zero.

---

## Appendix: key APIs & references found in research

- **Soniox context** — `context` object: general info (key/values incl. participant names/org),
  terms/custom vocabulary (~8,000 tokens), text context (free-form glossary/profile), translation
  terms. Diarization via `enable_speaker_diarization` (already used).
- **OpenAI STT** — `gpt-4o-transcribe` / realtime `prompt` for vocab steering (realtime ≤1024
  tokens; short keyword lists; beware glossary hallucination on near-silent chunks); `language` hint.
- **Apple** — Core Spotlight (`CSSearchableItem`, batched indexing + client state + `isUpdate`),
  App Intents `IndexedEntity` / `associateAppEntity`, iOS 26 `SpotlightSearchTool` (Foundation Models
  tool), Shortcuts "Use Model", `NLContextualEmbedding` (on-device, 512-dim), EventKit add-only/full
  tiers, Contacts limited access, mandatory Privacy Manifest.
- **Android** — AppSearch (Jetpack, on-device, BM25F), AppFunctions (Android 16, Assistant),
  `ShortcutManagerCompat.pushDynamicShortcut` + `core-google-shortcuts`, `Notification.ProgressStyle`
  Live Updates (Android 16, `POST_PROMOTED_NOTIFICATIONS`), MediaPipe Text Embedder (on-device
  Gecko) / ML Kit GenAI / AI Edge RAG.
- **On-device vector storage** — ObjectBox (HNSW, Kotlin/Java) or SQLite + sqlite-vec; simple cosine
  for small scopes.
