# Pebble Audio sync protocol (phone ↔ server), version 1

The iPhone app is the system of record. The server holds a mirror of the text (and clips on
request) so assistants can read it while the phone is in a pocket. This file is the contract
both halves are built against; change it here first, then both sides.

Base URL: `https://pebbleaudio.okgodoit.com`. JSON everywhere except clip bodies. All wall-clock
times are RFC 3339 strings in UTC (`2026-10-14T13:05:09.754Z`); media offsets and durations
are integer milliseconds. Every request from the phone carries `Authorization: Bearer <device
token>`. Tokens are opaque, prefixed `pad_`, stored hashed on the server. A device token opens
`/link` and `/sync/*` only; the `pat_` tokens assistants use open `/mcp` (and the Pebble plugin's
`/plugin/*`, see `pebble-plugin/README.md`) only, and neither works on the other's endpoints.

Optional fields are sent as an explicit `null`, never left out. An error answer carries
`{ "error": "…" }`, which the phone logs and never shows.

## 1. Linking a phone

1. The person opens the admin area on the server (passkey login), *Phones*, and taps *Link a
   phone*. The server shows a one-time code (8 characters from `A–Z` and `2–9` without `I`, `L`,
   `O`, valid 10 minutes, shown as `K7QM-3XWD`) and a QR code of
   `https://pebbleaudio.okgodoit.com/link?code=K7QM3XWD`, a universal link the app opens (the
   app-site association claims `/link*`); without the app, that page shows the code to type in.
   The app still accepts the older `pebbleaudio://link?code=…&origin=…`. Showing a new code ends
   the previous unused one.
2. The app calls `POST /link` (no token) with `{ "code": "…", "deviceName": "Sam's iPhone", "appVersion": "…", "appBuild": "…" }`.
   Case, spaces and dashes in the code do not matter.
3. Response `201 { "deviceId": "…", "deviceToken": "pad_…", "userId": "…", "serverTime": "…" }`.
   The app stores the token in the Keychain. `409` if the code is wrong, used or expired. After
   ten wrong codes from one address in ten minutes the server answers `429` until the window
   turns (right codes are not counted).

`DELETE /link` (device token) unlinks and deletes: the server deletes everything it holds for
the account (as `POST /sync/wipe` does), ends every assistant's access (every OAuth connection
and every personal token), then revokes this device token, all in one transaction, `204`. The
person asked for this (2026-10-21): unlinking must clear the server, never leave a copy behind.
The phone says so in its confirmation before calling it.
The admin area can rename and unlink a phone too. Unlinking the last linked phone there does
what `DELETE /link` does, after a confirmation that says so; while another phone stays linked,
it only revokes that phone's token, and the archive stays for the phone that keeps syncing it.

## 2. Entities

Each entity is identified by `(kind, id)` and carries a `version`: a 64-bit integer that only
increases for that entity (the app uses its own `updatedAtMs`). The server stores the highest
version it has seen; a batch item with a lower or equal version is accepted and ignored
(idempotent replays), so the phone can resend freely.

Ops: `upsert` (payload present), `delete` (the person deleted it in the app; the server deletes
it and everything derived from it), `expire` (the app's retention aged it out; the server keeps
it and marks `expiredOnPhone`; a later upsert of it clears the mark). A whole-account wipe is
a separate endpoint (§5).

| kind | id | payload |
| --- | --- | --- |
| `conversation` | the app's conversation id (`conv-seg-…`) | see 2.1 |
| `transcript` | the conversation id | see 2.2 |
| `recap` | the logical day key, `2026-10-14` | see 2.3 |
| `brief` | `week:2026-10-11` or `month:2026-10` | see 2.4 |
| `followUp` | the follow-up id | see 2.5 |
| `note` | the note id | see 2.6 |
| `person` | the person id | `{ "name": "Roger" }` |
| `coverage` | the logical day key | see 2.7 |
| `deviceStatus` | the phone's device id (the `deviceId` the batch carries) | see 2.8 |

### 2.1 `conversation`

```json
{
  "startedAt": "2026-10-14T13:05:09.754Z",
  "endedAt": "2026-10-14T13:28:12.462Z",
  "timeZone": "Asia/Jakarta",
  "dayKey": "2026-10-14",
  "state": "closed",
  "startReason": "topicChange",
  "provisional": false,
  "title": "Stale audiobook playback on the watch",
  "summary": "…",
  "tags": ["Pebble", "firmware"],
  "titleEditedByUser": false,
  "isFinal": true,
  "annotationProvider": "openai-chat",
  "annotationModel": "gpt-6-luna",
  "contentKind": "conversation",
  "contentDescriptor": null,
  "mostlyQuiet": false,
  "hasMissingAudio": true,
  "recordedMs": 1123000,
  "missingMs": 242920,
  "pieces": [
    { "ordinal": 0, "segmentId": "seg-1791997844787-ed737f28-63", "startMediaMs": 83010, "endMediaMs": null, "startedAt": "…", "endedAt": "…" }
  ],
  "people": [ { "label": "1", "personId": "…", "name": "Roger" } ],
  "gaps": [
    { "startedAt": "…", "endedAt": "…", "kind": "lost", "origin": "watch", "missingMs": 91300, "label": "audio interrupted for 1 min over 14 min", "cause": "watch buffer filled while disconnected" },
    { "startedAt": "…", "endedAt": "…", "kind": "quiet", "label": "quiet for 3 min" },
    { "startedAt": "…", "endedAt": "…", "kind": "lost", "origin": "watch", "missingMs": 3000, "label": "audio interrupted for 3 sec", "cause": "watch buffer filled while disconnected", "shown": false },
    { "startedAt": "…", "endedAt": "…", "kind": "lost", "origin": "watch", "missingMs": 52000, "label": "audio interrupted for 52 sec", "cause": "2 reasons",
      "causes": [ { "code": "spoolOverflow", "text": "watch buffer filled while disconnected", "ms": 40000, "count": 1 }, { "code": "transportReset", "text": "connection was interrupted", "ms": 12000, "count": 1 } ] }
  ]
}
```

`state` is `live` or `closed`; `provisional` is true while the segmenter may still move the
boundary. `dayKey` is the app's logical day (5 AM boundary, in `timeZone`). `recordedMs` is
stored audio inside the conversation; `missingMs` is the audio genuinely missing inside it (its
first word to its last), the number the app's History card shows as "N missing", and
`hasMissingAudio` says whether there is any. A conversation whose `contentKind` is
`noConversation` (music, TV, announcements) is synced too, so days add up, but is flagged.

`gaps` are the quiet and interrupted rows the app's Conversation screen shows, made by the
screen's own rule (`SearchKit.pieceTimeline`), so the server, the viewer and every tool read a
conversation the way the phone shows it:

- Gap records within 5 seconds of each other are one row. When the watch drops a fraction of a
  second every couple of seconds, one row covers minutes: `startedAt`…`endedAt` is that stretch,
  and `missingMs` is what is actually missing inside it. Never read the stretch as the loss.
- `kind` is `quiet` (nothing was said: a stretch of 30 seconds or more between two turns, or the
  watch's skipped silence) or `lost` (an interruption: audio the phone does not have). The two are
  never mixed up.
- `label` is the row's own words, without its cause, exactly as the app shows them: "audio
  interrupted for 1 min over 14 min" (a stretch of brief drops), "audio interrupted for 40 sec"
  (one hole), "audio briefly interrupted", "quiet for 3 min". The app puts the `cause` after it in
  parentheses.
- A `lost` row's `cause` is the app's words for why ("watch buffer filled while disconnected",
  "connection was interrupted", "phone briefly missed audio", …), or "2 reasons" with `causes`
  listing each, largest first: a stable `code` (`spoolOverflow`, `micConflict`, `userDisabled`,
  `lowBattery`, `codecError`, `transportReset`, `powerSave`, `phoneMissed`, `unknown`), the
  words, the milliseconds, and how many records.
- `shown: false` marks an interruption too brief for a transcript row of its own (its stretch is
  under 10 seconds). It still counts in `missingMs`, and the app still ticks its scrubber for it.
  Present only when false.
- Only rows that reach into the conversation's first word to its last are sent.

What the phone actually sends, and the server accepts:

- A piece that is a whole segment has `startMediaMs: 0` and `endMediaMs: null`; `startMediaMs`
  is never null.
- A `lost` gap's `origin` is where its main cause happened: `watch` (the watch never recorded
  it) or `link` (recorded, but it never reached the phone). A `quiet` gap has no `origin`.
  `unknown` was a hole between pieces that no record explains; a phone with the gap change no
  longer sends those (the app calls such a hole not recording, and before 2026-09-30 most were
  the watch's skipped silence the old store dropped).
- A `quiet` gap may carry `"reason": "watchPause"`: an interruption made only of the watch's own
  power-save pause, which the app does not count as missing. The server stores the reason.
- A phone before the gap change (export version 1) sends one gap per record, without `label`,
  `missingMs` or `shown`, and no `missingMs` on the conversation. The server reads those the
  app's way until the phone sends the conversation again (`GapRows`).
- Required: `startedAt`, `timeZone`, `dayKey`, `state`, `contentKind`, `pieces` (it may be
  empty), each piece's `segmentId`, `startMediaMs` and `startedAt`, and each gap's times and
  `kind`. Anything else missing takes its empty value.

### 2.2 `transcript`

One per conversation, already cut to the conversation's pieces, with wall-clock times, loop
artefacts collapsed and the music/TV mask applied, exactly what the app's own Ask feature
reads. Items are in time order and include the honest markers.

```json
{
  "conversationId": "conv-…",
  "sourceHash": "…",
  "provider": "soniox",
  "model": "stt-async-v5",
  "language": "en",
  "charCount": 10356,
  "text": "Roger: … \nSpeaker 2: …",
  "items": [
    { "kind": "turn", "at": "…", "endAt": "…", "speaker": "1", "name": "Roger", "text": "…", "confidence": 0.93 },
    { "kind": "quiet", "at": "…", "endAt": "…", "label": "quiet for 3 min" },
    { "kind": "lost", "at": "…", "endAt": "…", "origin": "watch", "missingMs": 91300, "label": "audio interrupted for 1 min over 14 min", "cause": "watch buffer filled while disconnected" },
    { "kind": "masked", "at": "…", "endAt": "…", "descriptor": "music" }
  ]
}
```

`text` is the plain joined form the server indexes; `items` is what tools return as turns. A
transcript's version increases whenever any piece's transcript changes (re-transcription,
speaker naming, a boundary move). Size: a two-hour conversation is under 1 MB.

The phone sends `language: null` today (it does not know the language yet). `conversationId`
must equal the item's `id`. The `quiet` and `lost` items are the conversation's gaps that the
app's transcript gives a row (§2.1, not the ones with `shown: false`), with the same fields
(`origin`, `reason`, `label`, `cause`, `causes`, `missingMs`) and the gap's `startedAt`/`endedAt`
as `at`/`endAt`.

### 2.3 `recap`

```json
{ "dayKey": "2026-10-14", "timeZone": "Asia/Jakarta", "headline": "…", "lineSummary": "…", "shortText": "…", "text": "…", "conversationIds": ["conv-…"], "provider": "openai-chat", "model": "gpt-6-luna" }
```

### 2.4 `brief`

```json
{ "kind": "week", "periodKey": "week:2026-10-11", "startDay": "2026-10-11", "endDay": "2026-10-17", "headline": "…", "lineSummary": "…", "text": "…", "provider": "…", "model": "…" }
```

### 2.5 `followUp`

```json
{ "text": "…", "quote": "…", "why": "…", "dueAt": null, "priority": 1, "done": false, "completedAt": null, "archivedAt": null, "snoozedUntil": null, "origin": "ai", "stage": "suggested", "sourceConversationId": "conv-…", "sourceAt": "…", "sourceEndAt": "…", "sourceApproximate": false, "createdAt": "…", "editedAt": null }
```

`origin` is `ai`, `user` or `assistant` (created through an MCP write tool, see §4).
`priority` is `0` (low), `1` (normal) or `2` (high).

`stage` (`docs/reminders.md`) is `suggested` (something the app noticed that the person might act
on, waiting for their review: not a commitment), `reminder` (they said yes to it or asked for it),
or `skipped` (they said no; kept and findable, on no list). A phone from before stages sends no
`stage`, and the server reads that as `reminder`, as it does every row it stored before stages.
Any other value rejects the item (`payload: stage 'x' is not known`). The phone's outbox records a
stage change like any other edit, so the server always has the current stage. Once both halves
know stages, the phone sends every follow-up again (one migration) so the server learns each
one's stage; until then a suggested or skipped follow-up reads as a reminder.

### 2.6 `note`

```json
{ "conversationId": "conv-…", "templateId": "meeting-notes", "title": "…", "body": "…", "citations": [ { "conversationId": "…", "at": "…", "endAt": "…" } ], "origin": "user", "provider": "…", "model": "…", "createdAt": "…", "editedAt": null }
```

### 2.7 `coverage`

```json
{ "dayKey": "2026-10-14", "timeZone": "…", "spans": [ { "startedAt": "…", "endedAt": "…", "kind": "recorded" }, { "…": "…", "kind": "quiet" }, { "kind": "missing" }, { "kind": "paused" }, { "kind": "off" } ], "recordedMs": 31200000, "quietMs": 9000000, "missingMs": 120000 }
```

### 2.8 `deviceStatus`

What the phone last knew about its watch, for the Pebble plugin (`GET /plugin/status`). One per
linked phone, replaced by every newer version; send it with the regular sync passes, upsert only.

```json
{
  "updatedAtMs": 1791999175292,
  "capture": "active",
  "link": "streaming",
  "recording": true,
  "lastAudioAtMs": 1791999170000,
  "watchBatteryPercent": 62,
  "watchFirmware": "v4.41.0-667",
  "todayRecordedMinutes": 312,
  "todayQuietMinutes": 95,
  "todayLostMinutes": 4,
  "storageUsedBytes": 734003200,
  "phoneBatteryPercent": 81
}
```

- Required: `updatedAtMs` (epoch milliseconds, when the phone took the reading), `capture`
  (`active`, `paused`, `off`), `link` (`unbound`, `disconnected`, `connecting`, `connected`,
  `streaming`, `revoked`), and `recording`. Every other field may be `null` (not known).
- Times are epoch milliseconds here, not RFC 3339, so the plugin can use them without parsing.
  Numbers may carry a fraction; the server rounds them.
- A reading that cannot be right (a percentage outside 0 to 100, a negative count) is stored as
  `null` rather than rejecting the report. An unknown `capture` or `link` value rejects it
  (`payload: link 'x' is not known`).
- The server files it under the phone the token names, whatever `id` says, and keeps its version
  on that row rather than in the archive's ledger: `stale` and `duplicate` work as for any kind.
  It is not archive content, so the sharing scope does not apply to it. `delete` and `expire` are
  rejected (`op: device status is only upserted`). Unlinking a phone, or a wipe, removes it.
- A server from before this kind rejects it (`kind: 'deviceStatus' is not known`) and applies the
  rest of the batch; deploy the server first.

## 3. Batches

### Speaker changes when the phone retains only a conversation's tail

`transcript` also accepts `op: "speakerPatch"`. It shares the transcript's normal increasing
version ledger, requires an existing transcript, and never changes words, markers, timing,
provider metadata, or the retained conversation's extent. A phone must never send a shortened
replacement transcript to rename speakers in retained history.

```json
{ "kind": "transcript", "id": "conv-…", "version": 1791999182001, "op": "speakerPatch", "changedAt": "…",
  "payload": { "conversationId": "conv-…", "sourceHash": "…", "ranges": [
    { "segmentId": "seg-…", "startMediaMs": 12000, "endMediaMs": 18000,
      "at": "…", "endAt": "…", "personId": "person-…", "name": "Alex" },
    { "segmentId": "seg-…", "startMediaMs": 18000, "endMediaMs": 22000,
      "at": "…", "endAt": "…", "personId": null, "name": null }
  ] } }
```

Ranges are half-open and use the source segment's stored-media clock. Each range carries its
wall-clock span solely for safely updating exports from older phones. A null name explicitly
clears attribution. The server updates only intersecting turns: a name needs consistent coverage
of the entire turn; partial or conflicting coverage clears the name instead of assigning words
outside the confirmed range. All other turns, including the expired prefix, remain unchanged.
The server rebuilds participant metadata and searchable text from the preserved turns.

Full transcript payloads may additionally carry `speakerRanges`, with the same fields plus
`itemIndex`, identifying a turn in `items`. The server stores these source anchors and stable
person IDs. For older turns without anchors, a patch must unambiguously identify the source
through the conversation's stored pieces and wall-clock span; ambiguous legacy timing is left
unchanged. These additive fields are safe for older servers to ignore.

An old server rejects the unknown `speakerPatch` operation without recording its version. The
phone keeps that item pending through its bounded rejection handling, then parks it until the
entity changes again; it must not retry it as an upsert. Deploy server support before the phone
release. No biometric vectors, samples, or model profiles are part of either payload.

Automatic names additionally carry `voiceEvidence` on each `speakerRanges` entry and on a
conversation participant whose name has no manual assignment. It is an array of
`{ "originID": "local-store-id", "generation": 0, "runID": "recognition-pass-id" }`.
An absent or empty array means a manual/legacy name, which voice-profile operations preserve.
If several automatic intervals support one exported turn, carry all their distinct provenance.

`kind: "voiceRevocation", op: "upsert"` is an immutable, account-scoped privacy decision:

```json
{ "kind": "voiceRevocation", "id": "unique-decision-id", "version": 1791999182002,
  "op": "upsert", "changedAt": "…", "payload": {
    "originID": "local-store-id", "generation": 1, "scope": "person", "targetID": "person-id"
  } }
```

The scope is `person` (target person ID), `run` (target recognition pass ID), or `all`
(`targetID: null`). It removes matching automatic names whose provenance has the same origin
and a **lower** generation. Every local revocation increments a durable counter; new explicit
recognition uses the current generation, so a clock correction does not affect ordering.
When a restored backup has lost its device-bound profile key, the phone permanently retires
the old origin with generation `9223372036854775807`, then chooses a new origin. This also
revokes matches created after the backup's older counter was saved. Parse generations as
signed 64-bit integers, never floating-point numbers.
The server updates retained transcript names, participants and search without removing words,
and keeps the revocation to reject older evidence in delayed full uploads or speaker patches.
Revocations bypass the date-sharing filter, survive local retention and unlink/relink, and
cannot be deleted, expired, or changed under the same ID. Account archive wipe removes them
along with the archive. Names saved manually remain. Voice material never crosses this wire.

`PUT /sync/batch`

```json
{
  "deviceId": "…",
  "sentAt": "…",
  "items": [
    { "kind": "conversation", "id": "conv-…", "version": 1791999175292, "op": "upsert", "changedAt": "…", "payload": { … } },
    { "kind": "transcript", "id": "conv-…", "version": 1791999180000, "op": "upsert", "changedAt": "…", "payload": { … } },
    { "kind": "followUp", "id": "…", "version": 1791999181000, "op": "delete", "changedAt": "…" },
    { "kind": "conversation", "id": "conv-…", "version": 1791999182000, "op": "expire", "changedAt": "…" }
  ]
}
```

Limits: 200 items or 8 MB per batch, whichever first. The phone writes each batch to a file and
uploads it with a background `URLSession` upload task (background tasks need file bodies), so
the body is the file. Items are applied in order inside one database transaction per batch;
batches for one account are applied one at a time. The body's `deviceId` and `sentAt` are
informational: the token says which phone sent it.

Response `200`:

```json
{ "serverTime": "…", "accepted": [ { "kind": "…", "id": "…", "version": 1 } ], "ignored": [ { "kind": "…", "id": "…", "version": 1, "reason": "stale" } ], "rejected": [ { "kind": "…", "id": "…", "reason": "payload: pieces missing" } ], "pendingRequests": 2 }
```

`ignored` reasons are `stale` (older than what the server holds), `duplicate` (the same
version; a replay), `outsideScope` (dated before the sharing scope, §5: not stored and not
recorded, so the same version is taken when the phone sends it again after the scope widens), and
`unknownKind` (a `kind` this server does not know, from a phone newer than the server: logged,
not stored, never a failure; `version` is 0 when the item had none). The phone treats all four as
held. `rejected` items are the phone's bug to fix;
the rest of the batch still applies. A reason names the field (`payload: pieces missing`,
`payload: gaps[2].kind 'x' is not known`, `kind: missing`); `server: could not
store it` means the database refused that one item, and the rest still applied. Nothing about a
rejected item is recorded, so the same version can be sent again once fixed. `400` means the
body is not JSON or has no `items` array. `401` means the token is gone (unlinked); the app
stops syncing and tells the person. `413` means the batch is over the limit
(`{ "error", "maxItems": 200, "maxBytes": 8388608 }`); the app halves it.

Ordering rule: a `transcript` may arrive before its `conversation`; the server stores it and
links it when the conversation arrives (the two share the id and are joined when read). A
`delete` for a conversation also deletes its transcript, notes and server-side derived rows (its
clips and their files, their requests, and its id in the AI-read log); follow-ups whose source
was that conversation keep their text but lose the source link (`sourceConversationId`,
`sourceAt` and `sourceEndAt` become null). The phone sends the transcript's own `delete` too.
The server keeps each entity's version after a delete, so a late copy of an older upsert stays
ignored.

## 4. Requests from the server to the phone

The phone pulls on every sync pass (every 30 s while the app is active, on each background
pass otherwise).

`GET /sync/requests` → `200 { "requests": [ { "id": "…", "kind": "clip", "createdAt": "…", "expiresAt": "…", "payload": { … } } ] }`

At most 100, oldest first. A request is offered on every pull until the phone answers it or it
expires, so the phone must treat one it has already handled (or is still uploading) as such.
Payload keys come back in Postgres `jsonb` order, not the order they were written.

| kind | payload | the phone does |
| --- | --- | --- |
| `clip` | `{ "conversationId": "conv-…", "startAt": "…", "endAt": "…", "maxMs": 1200000 }` | resolves wall → media across the conversation's pieces, remuxes the span to Ogg Speex (no decoding), and uploads it |
| `followUp.create` | a §2.5 payload with `origin: "assistant"`, `stage: "reminder"`, and a server-assigned `id` | inserts it into the local store as a reminder (which then syncs it back as an `upsert`, closing the loop) |
| `followUp.update` | `{ "id": "…", "done": true, "completedAt": "…" }` or edits to `text`, `dueAt`, `snoozedUntil`, `archivedAt`, `stage` (`reminder` or `skipped`, only when the person said so); a key left out is left alone, `null` clears it | applies the change; a new `stage` is the person's answer, as on the phone: it is stamped as decided and brings the item back out of the archive |
| `note.create` | a §2.6 payload with `origin: "assistant"` and a server-assigned `id` | inserts it |

Results:

- Clips: `PUT /sync/clips/{requestId}` with `Content-Type: audio/ogg`, the Ogg Speex file as the
  body, and headers `X-Clip-Start-At`, `X-Clip-End-At` (the span actually covered, which may be
  shorter than asked when audio was lost) and `X-Clip-Gaps` (JSON array of the stretches inside
  it with no audio, placed where each gap record says: `[{ "startedAt": "…", "endedAt": "…" }]`
  for lost audio, and the same with `"kind": "quiet"` for the silence the watch skipped and its
  power-save pause, which are not lost but are not in the file either. A player places the
  clip's audio on the clock from these, never from the conversation's rows, whose stretches
  include audio the clip holds). `201 { "clipId": "…" }` when stored, and again for
  a retried upload of a clip the server already has. `415` if it is not `audio/ogg`, `400` if the
  body is not Ogg or a header cannot be read, `404` for an unknown request. The server queues a
  transcode job (ffmpeg to AAC in m4a, 16 kHz mono) and then serves the clip.
- Everything else, and a clip the phone cannot make: `POST /sync/requests/{requestId}/result`
  with `{ "status": "done" | "failed" | "unavailable", "detail": "…" }`, `204`. `unavailable`
  means the phone no longer has the audio (aged out, deleted); the server records that honestly
  and answers the same span with it for the request time to live instead of asking again. The first answer stands;
  a late answer still replaces "expired". `400` for another status, `404` for an unknown
  request.

A follow-up or note an assistant creates is stored on the server at once (origin `assistant`,
version 0) so tools can read it back; the phone's own upsert of it replaces that row. If the
phone answers `failed` or `unavailable` to a `*.create`, or never answers, the unconfirmed row
is removed again.

A request expires after the *How long requests wait for the phone* setting (24 hours by
default); the server answers tools with "requested, waiting for the phone" until then, then
"the phone did not deliver". `pendingRequests` in every batch response lets the phone pull
immediately after a push. The server never queues a clip request for a conversation the phone
has expired: it answers that the audio is gone.

Ready clips are served at `GET /clips/{clipId}.m4a?exp=…&sig=…` (no token: the signature is
the authorization), `audio/mp4`, with byte ranges for seeking. A link lasts the *How long a clip
link works* setting (an hour by default). `403` for a wrong or expired signature, `404` while
the clip is not ready or once it is gone. A clip is kept for the *How long clips are kept*
setting (7 days by default) after it is ready, failed, or answered `unavailable`; then it goes
with its request and its file, and asking for that span again asks the phone again.

## 5. Account-level endpoints (device token)

- `POST /sync/wipe` `{ "confirm": "wipe" }`: deletes every row and file for the user on the
  server (the app's *Delete all* calls this after wiping locally): every entity, the version
  ledger (so what the phone sends next is taken as new), requests, clips and their jobs, and the
  AI-read log. It keeps what lets the phone go on syncing: the linked phones, their preferences,
  and the assistants' access. `200 { "serverTime": "…" }`; `400` without the confirmation.
- `GET /sync/status` → counts per kind, `lastBatchAt`, `pendingRequests`, `serverTime`,
  `aiReads` (the last 20 tool calls by assistants: when, which client, which tool, which ids), and
  `access`, so the app's status row, its "what AI read" line and the privacy screen are truthful:

  ```json
  {
    "serverTime": "…",
    "lastBatchAt": "…",
    "pendingRequests": 0,
    "counts": { "conversation": 812, "transcript": 809, "recap": 40, "brief": 6, "followUp": 120, "note": 9, "person": 14, "coverage": 41 },
    "aiReads": [ { "at": "…", "client": "Claude", "tool": "search", "ids": ["conv-…"] } ],
    "access": [ … ]
  }
  ```

  `lastBatchAt` is this phone's last batch (null before its first). The phone also accepts
  `when` for `at` and `entityIds` for `ids`; the server sends `at` and `ids`.

  For the Mac's backup import (`ios/Tools/ArchiveImport`, which links with `appBuild`
  `archive-import`), the answer also carries `phoneSince`, the start of the earliest conversation
  the server holds from a phone (an import's own do not count; null before the first), and
  `wipedAt`, when the archive was last deleted by `POST /sync/wipe` or unlinking (null if never).
  The import sends only what is dated before the first and after the second.

  ```json
  "access": [
    { "kind": "oauth", "id": "…", "name": "ChatGPT", "scopes": ["archive:read"], "connectedAt": "…", "lastUsedAt": "…" },
    { "kind": "oauth", "id": "…", "name": "Claude", "scopes": ["archive:read", "archive:write"], "connectedAt": "…", "lastUsedAt": null },
    { "kind": "token", "id": "…", "name": "Codex on Mac", "scopes": ["archive:read"], "connectedAt": "…", "lastUsedAt": "…" }
  ]
  ```

  One entry per assistant that can read the archive right now: every OAuth client with a live
  grant (named from its client metadata: ChatGPT, Claude, …) and every unrevoked personal token
  (named by its owner in the admin area). Revoked or expired access is not listed. `scopes` tells
  the phone whether that assistant can also write (create follow-ups and notes).
- `DELETE /sync/access/{kind}/{id}` (device token): revokes one assistant's access from the
  phone. `204`; `404` when there is no such live access.
- `PUT /sync/preferences` (device token) `{ "clips": false, "edits": false }`: what the person
  allowed on the phone. Sent once after linking and whenever a choice changes; both default to
  `false` until the phone says otherwise. With `clips: false` the server never queues a clip
  request (the audio tool answers that the person has not allowed clips), and a `PUT` with
  `clips: false` deletes every clip it holds for the account, files and requests included; with `edits: false` it
  refuses the follow-up and note write tools (they answer that the person has not allowed
  assistants to add to their archive). The phone also refuses such requests itself, so a stale
  server preference can never move audio or write anything the person did not allow.
  `GET /sync/preferences` returns the stored value. `PUT` answers with it too; a key left out
  keeps its stored value. Preferences are per account and survive a wipe.

  The same body carries the **sharing scope**, which decides which conversations the server may
  hold at all:

  ```json
  { "clips": false, "edits": false, "scope": { "kind": "all" } }
  { "scope": { "kind": "since", "since": "2026-10-21T00:00:00Z" } }
  { "scope": { "kind": "lastDays", "days": 90 } }
  ```

  - `all` (the default): everything the phone sends, kept even after the phone's own retention
    ages it out.
  - `since`: "from today on"; the phone sends nothing that started before `since`, and the server
    drops any item dated before it.
  - `lastDays`: a rolling window relative to now, every day. The phone sends nothing older than
    `days` days; the server removes everything older than that once a day (a job at 03:30 in the
    account's time zone) and immediately when the window shrinks, and no tool ever returns
    anything outside it even between runs (every query filters by the window). Removed means
    deleted: conversations, their transcripts and notes, recaps for those days, briefs whose
    period ends before the window, follow-ups whose source time is before it, and clip files.
  - "Dated" means a conversation's `startedAt`, a recap's day, a brief's `endDay`, a follow-up's
    `sourceAt` (else `createdAt`), a note's conversation (else its `createdAt`), a transcript's
    conversation (else its first item). A transcript the server holds without its conversation is
    therefore kept while its first item is inside the window, even when its conversation (which
    the server ignored as outside) started before it: every word in it is inside the window, no
    tool shows it without its conversation, and the sweep removes it once its first item falls
    out. A day is inside
    when it is on or after the logical day the window's start falls on. Widening the window does
    not bring anything back by itself; the phone re-sends what now falls inside it (it watches
    for a widened scope and marks those items pending). The server forgets the versions of what it
    removed, so those resends are taken as new.
  - `GET` and `PUT` answer with the scope as stored, in the same shape:
    `{ "clips": true, "edits": false, "scope": { "kind": "lastDays", "days": 90 } }` (`since` only
    for `since`, `days` only for `lastDays`). `400` for an unknown `kind`, a `since` scope without
    a time or with one more than an hour after the server's clock, or `days` outside 1 to 36,500.
    The account's time zone is the one of the latest
    conversation the phone sent (UTC before the first).

## 6. What the server derives and never asks the phone for

Full-text search (`tsvector` over title, summary, tags and transcript text), day listings
(`list_days`), signed clip links, the AI-read log, OAuth and bearer tokens, event
subscriptions. Deleting a conversation on the phone removes all of these for it.

## 7. Versioning

`X-Sync-Protocol: 1` on every request to `/link` and `/sync/*`; the server answers `426` with
`{ "minimum": n }` when the header is missing or older than it speaks. Additive payload fields
never bump the version; a changed meaning does.

One change of meaning did not, because the server reads both forms: from the phone's export
version 2 (`ArchiveExport.transcriptExportVersion`, which re-sends every conversation and
transcript once), a conversation's `gaps` are the app's rows rather than one per gap record
(§2.1). A row carries `label`; a record never did, and that is how the server tells them apart.
