# AI Processing Design

AI processing belongs to the third-party audio companion app and runs only from durable
transcripts, segment metadata, and user-visible events. It must never run inside BLE notification
callbacks and must never require the official Pebble mobile app.

## MVP

The MVP is manual and user-invoked:

- Select one segment, several segments, or a day.
- Choose a prompt template such as summary, meeting notes, action items, decisions, or custom.
- Edit the system/user prompt before running.
- Route through `AiProcessingMode` (`LocalOnly`, `RemoteOnly`, `LocalFirst`, `RemoteFirst`).
- Save `AiOutput` with segment ids, prompt template id/title, provider id, model, token counts,
  routing mode used, timestamp, and whether remote consent was enabled.
- Show results in a review screen before export/share.

Remote providers require explicit AI consent. Consent failures do not fall back to another provider
because fallback can still violate the user's intent. Cancellation also never falls back.

## Rules Engine

Scheduled and trigger-based processing is post-MVP. The rule model should be:

```text
trigger -> condition -> action
```

Examples:

- Daily summary at 18:00 -> transcripts exist for today -> create summary output.
- Keyword/topic trigger -> "pricing" discussed -> create action-item extraction.
- Meeting-window trigger -> calendar-linked segment range -> create meeting notes.
- User prompt over a time range -> explicit run -> save and optionally export.

Rules need cost controls before launch: maximum runs per day, token budgets, provider allowlist,
quiet hours, and clear failure/retry visibility.

## Privacy

- Encoded audio retention is controlled separately from transcript and AI-output retention.
- Diagnostics and support bundles exclude audio, transcript text, and AI output text by default.
- Remote AI calls require explicit provider consent and should show provider/model provenance.
- Delete-all must delete audio segments, transcripts, transcription tasks, AI outputs, and queued
  runs from local durable storage.
