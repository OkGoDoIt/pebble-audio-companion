# Pebble Audio sync protocol (phone ↔ server), version 1

The iPhone app is the system of record. The server holds a mirror of the text (and clips on
request) so assistants can read it while the phone is in a pocket. This file is the contract
both halves are built against; change it here first, then both sides.

Base URL: `https://pebbleaudio.okgodoit.com`. JSON everywhere except clip bodies. All wall-clock
times are RFC 3339 strings in UTC (`2026-10-14T13:05:09.754Z`); media offsets and durations
are integer milliseconds. Every request from the phone carries `Authorization: Bearer <device
token>`. Tokens are opaque, prefixed `pad_`, stored hashed on the server.

## 1. Linking a phone

1. The person opens the admin area on the server (passkey login) and taps *Link a phone*. The
   server shows a one-time code (8 characters, valid 10 minutes) and a QR code of
   `pebbleaudio://link?code=…&origin=https://pebbleaudio.okgodoit.com`.
2. The app calls `POST /link` with `{ "code": "…", "deviceName": "Roger's iPhone", "appVersion": "…", "appBuild": "…" }`.
3. Response `201 { "deviceId": "…", "deviceToken": "pad_…", "userId": "…", "serverTime": "…" }`.
   The app stores the token in the Keychain. `409` if the code is used or expired.

`DELETE /link` (device token) unlinks: the server keeps the data, revokes the token.

## 2. Entities

Each entity is identified by `(kind, id)` and carries a `version`: a 64-bit integer that only
increases for that entity (the app uses its own `updatedAtMs`). The server stores the highest
version it has seen; a batch item with a lower or equal version is accepted and ignored
(idempotent replays), so the phone can resend freely.

Ops: `upsert` (payload present), `delete` (the person deleted it in the app; the server deletes
it and everything derived from it), `expire` (the app's retention aged it out; the server keeps
it and marks `expiredOnPhone`). A whole-account wipe is a separate endpoint (§4).

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

`origin` is `ai`, `user` or `assistant` (created through an MCP write tool, see §3).

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
the body is the file. Items are applied in order inside one database transaction per batch.

Response `200`:

```json
{ "serverTime": "…", "accepted": [ { "kind": "…", "id": "…", "version": 1 } ], "ignored": [ { "kind": "…", "id": "…", "version": 1, "reason": "stale" } ], "rejected": [ { "kind": "…", "id": "…", "reason": "payload: pieces missing" } ], "pendingRequests": 2 }
```

`rejected` items are the phone's bug to fix; the rest of the batch still applies. `401` means
the token is gone (unlinked); the app stops syncing and tells the person. `413` means the batch
is over the limit; the app halves it.

Ordering rule: a `transcript` may arrive before its `conversation`; the server stores it and
links it when the conversation arrives. A `delete` for a conversation also deletes its
transcript, notes and server-side derived rows; follow-ups whose source was that conversation
keep their text but lose the source link.

## 4. Requests from the server to the phone

The phone pulls on every sync pass (every 30 s while the app is active, on each background
pass otherwise).

`GET /sync/requests` → `200 { "requests": [ { "id": "…", "kind": "clip", "createdAt": "…", "expiresAt": "…", "payload": { … } } ] }`

| kind | payload | the phone does |
| --- | --- | --- |
| `clip` | `{ "conversationId": "conv-…", "startAt": "…", "endAt": "…", "maxMs": 1200000 }` | resolves wall → media across the conversation's pieces, remuxes the span to Ogg Speex (no decoding), and uploads it |
| `followUp.create` | a §2.5 payload with `origin: "assistant"` and a server-assigned `id` | inserts it into the local store (which then syncs it back as an `upsert`, closing the loop) |
| `followUp.update` | `{ "id": "…", "done": true, "completedAt": "…" }` or edits to `text`, `dueAt`, `snoozedUntil`, `archivedAt` | applies the change |
| `note.create` | a §2.6 payload with `origin: "assistant"` and a server-assigned `id` | inserts it |

Results:

- Clips: `PUT /sync/clips/{requestId}` with `Content-Type: audio/ogg`, the Ogg Speex file as the
  body, and headers `X-Clip-Start-At`, `X-Clip-End-At` (the span actually covered, which may be
  shorter than asked when audio was lost) and `X-Clip-Gaps` (JSON array of lost spans inside it).
  `201` when stored. The server queues a transcode job and then serves the clip.
- Everything else: `POST /sync/requests/{requestId}/result` with
  `{ "status": "done" | "failed" | "unavailable", "detail": "…" }`. `unavailable` means the phone
  no longer has the audio (aged out, deleted); the server records that honestly.

A request expires after 24 hours; the server answers tools with "requested, waiting for the
phone" until then, then "the phone did not deliver". `pendingRequests` in every batch response
lets the phone pull immediately after a push.

## 5. Account-level endpoints (device token)

- `POST /sync/wipe` `{ "confirm": "wipe" }`: deletes every row and file for the user on the
  server (the app's *Delete all* calls this after wiping locally).
- `GET /sync/status` → counts per kind, `lastBatchAt`, `pendingRequests`, `serverTime`,
  `aiReads` (the last 20 tool calls by assistants: when, which client, which tool, which ids), and
  `access`, so the app's status row, its "what AI read" line and the privacy screen are truthful:

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
  phone. `204`.
- `PUT /sync/preferences` (device token) `{ "clips": false, "edits": false }`: what the person
  allowed on the phone. Sent once after linking and whenever a choice changes; both default to
  `false` until the phone says otherwise. With `clips: false` the server never queues a clip
  request (the audio tool answers that the person has not allowed clips); with `edits: false` it
  refuses the follow-up and note write tools (they answer that the person has not allowed
  assistants to add to their archive). The phone also refuses such requests itself, so a stale
  server preference can never move audio or write anything the person did not allow.
  `GET /sync/preferences` returns the stored value.

## 6. What the server derives and never asks the phone for

Full-text search (`tsvector` over title, summary, tags and transcript text), day listings
(`list_days`), signed clip links, the AI-read log, OAuth and bearer tokens, event
subscriptions. Deleting a conversation on the phone removes all of these for it.

## 7. Versioning

`X-Sync-Protocol: 1` on every request; the server answers `426` with `{ "minimum": n }` when the
app is too old. Additive payload fields never bump the version; a changed meaning does.
