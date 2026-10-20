# Pebble Audio sync protocol (phone ↔ server), version 1

The iPhone app is the system of record. The server holds a mirror of the text (and clips on
request) so assistants can read it while the phone is in a pocket. This file is the contract
both halves are built against; change it here first, then both sides.

Base URL: `https://pebbleaudio.okgodoit.com`. JSON everywhere except clip bodies. All wall-clock
times are RFC 3339 strings in UTC (`2026-10-14T13:05:09.754Z`); media offsets and durations
are integer milliseconds. Every request from the phone carries `Authorization: Bearer <device
token>`. Tokens are opaque, prefixed `pad_`, stored hashed on the server. A device token opens
`/link` and `/sync/*` only; the `pat_` tokens assistants use open `/mcp` only, and neither works
on the other's endpoints.

Optional fields are sent as an explicit `null`, never left out. An error answer carries
`{ "error": "…" }`, which the phone logs and never shows.

## 1. Linking a phone

1. The person opens the admin area on the server (passkey login), *Phones*, and taps *Link a
   phone*. The server shows a one-time code (8 characters from `A–Z` and `2–9` without `I`, `L`,
   `O`, valid 10 minutes, shown as `K7QM-3XWD`) and a QR code of
   `pebbleaudio://link?code=K7QM3XWD&origin=https%3A%2F%2Fpebbleaudio.okgodoit.com`. Showing a
   new code ends the previous unused one.
2. The app calls `POST /link` (no token) with `{ "code": "…", "deviceName": "Roger's iPhone", "appVersion": "…", "appBuild": "…" }`.
   Case, spaces and dashes in the code do not matter.
3. Response `201 { "deviceId": "…", "deviceToken": "pad_…", "userId": "…", "serverTime": "…" }`.
   The app stores the token in the Keychain. `409` if the code is wrong, used or expired. After
   ten wrong codes from one address in ten minutes the server answers `429` until the window
   turns (right codes are not counted).

`DELETE /link` (device token) unlinks and deletes: the server deletes everything it holds for
the account (as `POST /sync/wipe` does), ends every assistant's access (every OAuth connection
and every personal token), then revokes this device token, all in one transaction, `204`. The
person asked for this (2026-10-21): unlinking must clear the server, never leave a copy behind.
The phone says so in its confirmation before calling it. `DELETE /link?keepData=true` exists
only for the admin area's "Unlink this phone" when another phone stays linked; the app never
sends it.
The admin area can rename and unlink a phone too.

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
  "pieces": [
    { "ordinal": 0, "segmentId": "seg-1791997844787-ed737f28-63", "startMediaMs": 83010, "endMediaMs": null, "startedAt": "…", "endedAt": "…" }
  ],
  "people": [ { "label": "1", "personId": "…", "name": "Roger" } ],
  "gaps": [
    { "startedAt": "…", "endedAt": "…", "kind": "lost", "origin": "watch" },
    { "startedAt": "…", "endedAt": "…", "kind": "quiet" }
  ]
}
```

`state` is `live` or `closed`; `provisional` is true while the segmenter may still move the
boundary. `dayKey` is the app's logical day (5 AM boundary, in `timeZone`). `gaps` lists every
stretch inside the conversation with no stored audio, `quiet` (skipped on purpose) kept
distinct from `lost` (genuinely missing). `recordedMs` is stored audio inside the conversation.
A conversation whose `contentKind` is `noConversation` (music, TV, announcements) is synced too,
so days add up, but is flagged.

What the phone actually sends, and the server accepts:

- A piece that is a whole segment has `startMediaMs: 0` and `endMediaMs: null`; `startMediaMs`
  is never null.
- A `lost` gap's `origin` is `watch` (the watch never recorded it), `link` (recorded, but it
  never reached the phone), or `unknown` (a hole between pieces that no record explains). A
  `quiet` gap has no `origin`.
- A `quiet` gap may carry `"reason": "watchPause"`: the watch's own power-save pause, as opposed
  to its silence suppression. The server stores the reason.
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
    { "kind": "quiet", "at": "…", "endAt": "…" },
    { "kind": "lost", "at": "…", "endAt": "…", "origin": "watch" },
    { "kind": "masked", "at": "…", "endAt": "…", "descriptor": "music" }
  ]
}
```

`text` is the plain joined form the server indexes; `items` is what tools return as turns. A
transcript's version increases whenever any piece's transcript changes (re-transcription,
speaker naming, a boundary move). Size: a two-hour conversation is under 1 MB.

The phone sends `language: null` today (it does not know the language yet). `conversationId`
must equal the item's `id`. A `lost` item carries the same origins as a lost gap.

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
{ "text": "…", "quote": "…", "why": "…", "dueAt": null, "priority": 1, "done": false, "completedAt": null, "archivedAt": null, "snoozedUntil": null, "origin": "ai", "sourceConversationId": "conv-…", "sourceAt": "…", "sourceEndAt": "…", "sourceApproximate": false, "createdAt": "…", "editedAt": null }
```

`origin` is `ai`, `user` or `assistant` (created through an MCP write tool, see §4).
`priority` is `0` (low), `1` (normal) or `2` (high).

### 2.6 `note`

```json
{ "conversationId": "conv-…", "templateId": "meeting-notes", "title": "…", "body": "…", "citations": [ { "conversationId": "…", "at": "…", "endAt": "…" } ], "origin": "user", "provider": "…", "model": "…", "createdAt": "…", "editedAt": null }
```

### 2.7 `coverage`

```json
{ "dayKey": "2026-10-14", "timeZone": "…", "spans": [ { "startedAt": "…", "endedAt": "…", "kind": "recorded" }, { "…": "…", "kind": "quiet" }, { "kind": "missing" }, { "kind": "paused" }, { "kind": "off" } ], "recordedMs": 31200000, "quietMs": 9000000, "missingMs": 120000 }
```

## 3. Batches

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
version; a replay), and `outsideScope` (dated before the sharing scope, §5: not stored and not
recorded, so the same version is taken when the phone sends it again after the scope widens).
The phone treats all three as held. `rejected` items are the phone's bug to fix;
the rest of the batch still applies. A reason names the field (`payload: pieces missing`,
`payload: gaps[2].kind 'x' is not known`, `kind: 'gadget' is not known`); `server: could not
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
| `followUp.create` | a §2.5 payload with `origin: "assistant"` and a server-assigned `id` | inserts it into the local store (which then syncs it back as an `upsert`, closing the loop) |
| `followUp.update` | `{ "id": "…", "done": true, "completedAt": "…" }` or edits to `text`, `dueAt`, `snoozedUntil`, `archivedAt`; a key left out is left alone, `null` clears it | applies the change |
| `note.create` | a §2.6 payload with `origin: "assistant"` and a server-assigned `id` | inserts it |

Results:

- Clips: `PUT /sync/clips/{requestId}` with `Content-Type: audio/ogg`, the Ogg Speex file as the
  body, and headers `X-Clip-Start-At`, `X-Clip-End-At` (the span actually covered, which may be
  shorter than asked when audio was lost) and `X-Clip-Gaps` (JSON array of lost spans inside it,
  `[{ "startedAt": "…", "endedAt": "…" }]`). `201 { "clipId": "…" }` when stored, and again for
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
the clip is not ready.

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
  request (the audio tool answers that the person has not allowed clips); with `edits: false` it
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
    conversation (else its first item). A day is inside
    when it is on or after the logical day the window's start falls on. Widening the window does
    not bring anything back by itself; the phone re-sends what now falls inside it (it watches
    for a widened scope and marks those items pending). The server forgets the versions of what it
    removed, so those resends are taken as new.
  - `GET` and `PUT` answer with the scope as stored, in the same shape:
    `{ "clips": true, "edits": false, "scope": { "kind": "lastDays", "days": 90 } }` (`since` only
    for `since`, `days` only for `lastDays`). `400` for an unknown `kind`, a `since` scope without
    a time, or `days` outside 1 to 36,500. The account's time zone is the one of the latest
    conversation the phone sent (UTC before the first).

## 6. What the server derives and never asks the phone for

Full-text search (`tsvector` over title, summary, tags and transcript text), day listings
(`list_days`), signed clip links, the AI-read log, OAuth and bearer tokens, event
subscriptions. Deleting a conversation on the phone removes all of these for it.

## 7. Versioning

`X-Sync-Protocol: 1` on every request to `/link` and `/sync/*`; the server answers `426` with
`{ "minimum": n }` when the header is missing or older than it speaks. Additive payload fields
never bump the version; a changed meaning does.
