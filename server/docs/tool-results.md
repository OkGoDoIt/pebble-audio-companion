# Pebble Audio MCP tool results

The exact shape of what every tool on `/mcp` returns. The MCP Apps widgets (conversation card, day
timeline, clip player) and the conversation viewer are built against this file, so it changes only
additively: a field may be added, never renamed, retyped, or given a new meaning. Change it here first,
then the code (`server/src/PebbleAudio.Server/Mcp/`), then the widgets.

The tool names, and the method assistants are taught, are in
`plugin/pebble-audio/skills/pebble-audio/SKILL.md` and `Mcp/Instructions.cs`.

## Every result

A tool result is an MCP `CallToolResult` with:

- `structuredContent`: the object described below for that tool. It matches the tool's `outputSchema`.
- `content`: two text blocks, in this order:
  1. the result's `summary` alone, one speakable sentence (for voice and AirPods, and for clients that read
     only the first block);
  2. the same JSON as `structuredContent`, serialized, which ChatGPT requires for `search` and `fetch` and
     every client that ignores `structuredContent` can parse.
- `_meta`: only on `get_audio` when a clip is ready (below). `_meta` reaches widgets, never the model.
- `isError: true` only for arguments the tool cannot use (an unknown `include`, a malformed time) or a write
  from a read-only connection; the text says what to send instead. Something that is simply not there (an
  unknown id, an empty day) is a normal result with `found: false` and, when there is something close,
  `candidates`.

Conventions inside `structuredContent`:

| Rule | Example |
| --- | --- |
| `summary` is the first key, one sentence, second person, no markup | `"On Wednesday, October 14 you had 3 conversations over 2 hours 10 minutes of recording: Tiles, teeth, and the launch."` |
| Every instant is RFC 3339 **in the local offset** of the conversation (or, for days and follow-ups without a conversation, the account's time zone), whole seconds | `"2026-10-14T10:05:00+07:00"` |
| `timeZone` is the IANA zone those offsets come from | `"Asia/Jakarta"` |
| Days are the app's logical days: `yyyy-MM-dd`, rolling over at 5 AM local, not midnight | `"2026-10-14"` |
| Durations are minutes, a number rounded to one decimal | `"minutes": 36`, `"quietMinutes": 2.3` |
| `t` is whole seconds from the conversation's start (wall clock, gaps included): the number a moment link carries | `"t": 812` |
| `url` is an absolute, token-free link to the viewer (below) | |
| A field whose value is null is left out; a list is always present, possibly empty; a boolean is always present | |
| A result that could not hold everything says `"truncated": true` and gives `next`, the exact call that continues | see Truncation |

### Viewer links (`url`)

Built from the server's public origin (`https://pebbleaudio.okgodoit.com` in production), never from a
request's host. They carry no token; the viewer asks the person to sign in.

| What | Link |
| --- | --- |
| A moment in a conversation | `/c/{conversationId}?t={secondsFromStart}` |
| A conversation | `/c/{conversationId}` |
| A day | `/d/{dayKey}` |
| A week or month brief | `/b/week/{startDay}`, `/b/month/{yyyy-MM}` |

A follow-up links to the moment it was said (or its day, when it has no source); a note links to its
conversation (or its day). People and tags have no page and no `url`.

### Truncation

Every result that can be cut has `truncated` (boolean). When it is `true`, or when a list has another page,
`next` is present:

```json
"truncated": true,
"next": { "tool": "get_conversation", "arguments": { "id": "conv-seg-…", "include": "transcript", "from_time": "2026-10-14T10:24:41+07:00", "max_chars": 30000 } }
```

Calling `next.tool` with `next.arguments` returns the following window or page. The ceiling is the
*Length of an assistant answer* setting (`ToolMaxCharacters`, 60,000 characters of JSON by default, so the
JSON in `content` plus `structuredContent` stays under Claude's ~150,000-character result limit and Claude
Code's 25,000 tokens) and the *Items per assistant answer* setting (`ToolMaxResults`, 50). A day of
transcripts is about 200,000 characters, so whole days never come back in one result. One very long text
(a recap, a single turn) is cut with `…` at the end rather than dropped.

### Candidates

When a name or a day could mean more than one thing, or an id is not found, the tool does not guess: it
answers `found: false` (or with an empty list) and `candidates`, and the `summary` asks which one. The shape
of a candidate depends on the tool and is given with it.

### Sharing scope

The phone decides which conversations the server may hold (`all`, `since` a time, or the `lastDays` N days;
sync-protocol.md §5). No tool ever returns anything outside it, even between the nightly deletions:
conversations by `startedAt`, recaps and coverage by day, briefs by `endDay`, follow-ups by their source
time (else creation), notes by their conversation. Counts and lists are counted inside the scope.

## Shared objects

### Conversation card

Used by `get_day`, `list_conversations`, and as the top of `get_conversation`.

```json
{
  "id": "conv-seg-1791997844787-ed737f28-63",
  "title": "Kitchen tiles with Sam",
  "url": "https://pebbleaudio.okgodoit.com/c/conv-seg-1791997844787-ed737f28-63",
  "day": "2026-10-14",
  "startedAt": "2026-10-14T10:05:00+07:00",
  "endedAt": "2026-10-14T10:41:00+07:00",
  "timeZone": "Asia/Jakarta",
  "minutes": 36.0,
  "recordedMinutes": 31.5,
  "overview": "Sam and you compare three tile samples for the kitchen…",
  "tags": ["kitchen renovation", "home"],
  "people": [
    { "label": "1", "name": "Roger", "personId": "person-roger" },
    { "label": "2", "name": "Sam", "personId": "person-sam" }
  ],
  "kind": "conversation",
  "state": "closed",
  "provisional": false,
  "hasTranscript": true,
  "expiredOnPhone": false,
  "quietMinutes": 2.0,
  "lostMinutes": 1.0
}
```

| Field | Meaning |
| --- | --- |
| `overview` | The app's summary of the conversation. In lists (`get_day`, `list_conversations`) at most 400 characters, ending with `…` when cut; whole in `get_conversation`. Absent while the app has not written one. |
| `people[]` | Speaker labels as the transcriber numbered them, with the person each was matched to. `name` and `personId` are absent for an unmatched speaker. |
| `kind` | `conversation`, or `noConversation` for music, TV, or announcements (kept so the day adds up); then `descriptor` says what, for example `"music"`. |
| `state` | `live` while it is still being recorded, else `closed`. |
| `provisional` | True while the app may still move its boundaries; its text may change. |
| `expiredOnPhone` | True when the phone's retention has aged it out: the text stays here, the audio is gone. |
| `quietMinutes` | Silence the watch skipped on purpose. Nothing was said. |
| `lostMinutes` | Audio that is genuinely missing. Something may have been said. |

### Gap

```json
{ "kind": "lost", "startedAt": "2026-10-14T10:09:00+07:00", "endedAt": "2026-10-14T10:10:00+07:00", "t": 240, "minutes": 1.0, "origin": "watch" }
{ "kind": "quiet", "startedAt": "…", "endedAt": "…", "t": 540, "minutes": 2.0, "reason": "watchPause" }
```

`kind` is `quiet` or `lost`, never mixed up. A lost gap's `origin` is `watch` (never recorded), `link` (recorded,
never reached the phone), or `unknown`. A quiet gap may carry `reason: "watchPause"` (the watch's power-save
pause rather than its silence skipping).

### Transcript item

In time order. Turns and markers share the list:

```json
{ "kind": "turn", "t": 12, "at": "2026-10-14T10:05:12+07:00", "speaker": "2", "name": "Sam", "text": "The matte ones hide water spots.", "confidence": 0.93 }
{ "kind": "quiet", "t": 540, "at": "…", "endAt": "…", "minutes": 2.0 }
{ "kind": "lost", "t": 240, "at": "…", "endAt": "…", "minutes": 1.0, "origin": "watch" }
{ "kind": "masked", "t": 900, "at": "…", "endAt": "…", "minutes": 1.0, "descriptor": "music" }
```

| Field | Meaning |
| --- | --- |
| `speaker` | The transcriber's label; `name` is present when the label was matched to a person. |
| `confidence` | The transcriber's confidence in the turn's words, 0 to 1. Below about 0.6, words and names are often wrong. Absent when the transcriber gave none. |
| `masked` | A stretch the app hid because it was music, TV, or another recording; `descriptor` says which. |

### Follow-up

```json
{
  "id": "fu-tiles",
  "text": "Send Sam the tile samples",
  "url": "https://pebbleaudio.okgodoit.com/c/conv-kitchen?t=1260",
  "quote": "I'll send you the samples tonight.",
  "why": "Sam needs them before ordering.",
  "dueAt": "2026-10-16T18:00:00+07:00",
  "priority": "high",
  "status": "open",
  "done": false,
  "origin": "ai",
  "createdAt": "2026-10-14T10:45:00+07:00",
  "source": { "conversationId": "conv-kitchen", "title": "Kitchen tiles with Sam", "at": "2026-10-14T10:26:00+07:00", "t": 1260, "url": "https://pebbleaudio.okgodoit.com/c/conv-kitchen?t=1260", "approximate": false },
  "waitingForPhone": false
}
```

| Field | Meaning |
| --- | --- |
| `priority` | `low`, `normal`, or `high`. |
| `status` | `open`, `done`, `snoozed` (until `snoozedUntil`, still in the future), or `archived`. `completedAt`, `snoozedUntil`, `archivedAt` are present when set. |
| `origin` | `ai` (the app found it), `user` (the person wrote it), or `assistant` (an assistant added it with `create_follow_up`). |
| `source` | Where it was said; absent when it has none (or its conversation was deleted). `approximate` means the time is the app's best guess. |
| `waitingForPhone` | True for an assistant's follow-up the phone has not confirmed yet. If the phone refuses it or never answers, it disappears. |

### Note

```json
{
  "id": "note-launch",
  "conversationId": "conv-launch",
  "title": "Launch checklist",
  "body": "Press kit by Friday; Leo owns the demo video.",
  "url": "https://pebbleaudio.okgodoit.com/c/conv-launch",
  "origin": "user",
  "createdAt": "2026-10-14T15:30:00+07:00",
  "citations": [ { "conversationId": "conv-launch", "at": "2026-10-14T14:12:00+07:00", "t": 720, "url": "https://pebbleaudio.okgodoit.com/c/conv-launch?t=720" } ],
  "waitingForPhone": false
}
```

`editedAt` is present when set. `waitingForPhone` as for follow-ups.

## Tools

Read tools are annotated `readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false`.
Write tools are `readOnlyHint: false, openWorldHint: false`, with `destructiveHint: false` for the additive
`create_follow_up` and `create_note` and `true` for `update_follow_up` (it replaces and archives), need the `archive:write`
scope, and are hidden from `tools/list` for a read-only connection. Every tool has a `title` and the ChatGPT
status strings `openai/toolInvocation/invoking` and `…/invoked` (64 characters at most) in its `_meta`. Each
`outputSchema` requires only the fields that are never null, since a null field is left out; every result in the
test suite is checked against it.

### `get_status`

No arguments.

```json
{
  "summary": "Your archive holds 4 conversations from October 13 to October 15; your phone last synced 3 minutes ago.",
  "url": "https://pebbleaudio.okgodoit.com/d/2026-10-15",
  "serverTime": "2026-10-21T09:12:00+07:00",
  "timeZone": "Asia/Jakarta",
  "firstDay": "2026-10-13",
  "lastDay": "2026-10-15",
  "lastSyncAt": "2026-10-21T09:09:00+07:00",
  "counts": { "conversations": 4, "transcripts": 4, "recaps": 1, "briefs": 2, "followUps": 3, "notes": 1, "people": 4, "coverageDays": 1 },
  "pendingRequests": 0,
  "linkedPhones": 1,
  "serverVersion": "0.1.0+abc1234",
  "sharing": { "kind": "lastDays", "days": 90, "from": "2026-07-23T09:12:00+07:00" },
  "allowed": { "clips": true, "edits": false },
  "canWrite": false
}
```

`sharing.kind` is `all`, `since` (with `since`), or `lastDays` (with `days`); `from` is the earliest instant the
archive may hold now (absent for `all`). `allowed` is what the person allowed on the phone; `canWrite` is
whether this connection has the `archive:write` scope. Both must be true for the write tools to work.
`firstDay`, `lastDay`, `lastSyncAt` are absent for an empty archive.

### `list_days`

Arguments: `from`, `to` (days, `yyyy-MM-dd`, or `today` / `yesterday`; default the 14 days ending today).
Newest first. Days the archive has nothing for are left out.

```json
{
  "summary": "3 of the 14 days from October 8 to October 21 have recordings.",
  "from": "2026-10-08",
  "to": "2026-10-21",
  "timeZone": "Asia/Jakarta",
  "days": [
    {
      "day": "2026-10-14",
      "weekday": "Wednesday",
      "url": "https://pebbleaudio.okgodoit.com/d/2026-10-14",
      "headline": "Tiles, teeth, and the launch",
      "lineSummary": "Kitchen tiles with Sam, a dentist booking, and the launch plan with Priya and Leo.",
      "conversationCount": 4,
      "recordedMinutes": 130.0,
      "quietMinutes": 150.0,
      "lostMinutes": 2.0,
      "hasRecap": true
    }
  ],
  "truncated": false
}
```

`headline` and `lineSummary` come from the day's recap and are absent without one. The minutes come from the
day's coverage when the phone sent it, else from its conversations.

### `get_day`

Argument: `date` (`yyyy-MM-dd`, `today`, or `yesterday`).

```json
{
  "summary": "On Wednesday, October 14 you had 3 conversations over 2 hours 10 minutes of recording: Tiles, teeth, and the launch.",
  "found": true,
  "day": "2026-10-14",
  "weekday": "Wednesday",
  "url": "https://pebbleaudio.okgodoit.com/d/2026-10-14",
  "timeZone": "Asia/Jakarta",
  "recap": { "headline": "Tiles, teeth, and the launch", "lineSummary": "…", "text": "…" },
  "coverage": {
    "recordedMinutes": 130.0, "quietMinutes": 150.0, "lostMinutes": 2.0,
    "spans": [ { "kind": "recorded", "startedAt": "2026-10-14T09:00:00+07:00", "endedAt": "2026-10-14T12:00:00+07:00", "minutes": 180.0 } ]
  },
  "conversations": [ { "…": "conversation card" } ],
  "followUps": [ { "…": "follow-ups said in this day's conversations" } ],
  "truncated": false
}
```

`recap` and `coverage` are absent when the phone has not sent them. Coverage span `kind` is `recorded`, `quiet`,
`missing`, `paused` (the person paused recording), or `off` (the watch was not recording). Conversations are in
time order. A day with nothing is `found: false` with `candidates`, the nearest days that have recordings; so is
an ambiguous `date` such as `wednesday` (the two most recent Wednesdays):

```json
"candidates": [ { "day": "2026-10-14", "weekday": "Wednesday", "url": "…/d/2026-10-14", "headline": "Tiles, teeth, and the launch", "conversationCount": 3 } ]
```

### `get_brief`

Arguments: `kind` (`week` or `month`, default `week`), `key` (a week's first day `2026-10-11`, any day inside
the week or month, or a month `2026-10`; default the latest).

```json
{
  "summary": "The week of October 11 to 17: a renovation taking shape and a launch on schedule.",
  "found": true,
  "kind": "week",
  "key": "week:2026-10-11",
  "startDay": "2026-10-11",
  "endDay": "2026-10-17",
  "url": "https://pebbleaudio.okgodoit.com/b/week/2026-10-11",
  "headline": "A renovation taking shape",
  "lineSummary": "…",
  "text": "…"
}
```

Not found: `found: false` and `candidates`, the nearest briefs of that kind:
`[ { "kind": "week", "key": "week:2026-10-04", "startDay": "…", "endDay": "…", "url": "…", "headline": "…" } ]`.

### `list_conversations`

Arguments, all optional: `from`, `to` (days), `tag`, `person` (a name or a person id), `query` (full-text),
`cursor` (from `next`). Newest first.

```json
{
  "summary": "2 conversations with Sam from October 1 to October 21.",
  "filters": { "from": "2026-10-01", "to": "2026-10-21", "person": "Sam", "personId": "person-sam" },
  "conversations": [ { "…": "conversation card" } ],
  "truncated": false
}
```

`filters` echoes what was applied, with `personId` / `tag` resolved to the exact value. When `person` or `tag`
matches more than one, nothing is listed: `conversations` is empty and

```json
"candidates": [
  { "kind": "person", "value": "Sam", "personId": "person-sam", "conversationCount": 2, "lastDay": "2026-10-14", "example": "Kitchen tiles with Sam" },
  { "kind": "person", "value": "Sam", "personId": "person-sam-k", "conversationCount": 1, "lastDay": "2026-10-13", "example": "Badminton on Saturday" }
]
```

(`kind: "tag"` candidates carry `value`, `conversationCount`, `lastDay`.) A further page: `truncated: true` and
`next.arguments.cursor`.

### `get_conversation`

Arguments: `id`; `include` `summary` (default), `transcript`, or `both`; `from_time`, `to_time` (instants or
seconds from the start) to read a window; `max_chars` (default the *Transcript read* setting, 30,000; at most
`ToolMaxCharacters`).

```json
{
  "summary": "Kitchen tiles with Sam, Wednesday 10:05 AM to 10:41 AM, 36 minutes, 1 minute of lost audio.",
  "found": true,
  "…": "every conversation card field, with the whole overview",
  "gaps": [ { "…": "gap" } ],
  "followUps": [ { "…": "follow-ups said in it" } ],
  "notes": [ { "…": "notes on it" } ],
  "transcript": {
    "from": "2026-10-14T10:05:00+07:00",
    "to": "2026-10-14T10:41:00+07:00",
    "itemCount": 214,
    "shownCount": 120,
    "provider": "soniox",
    "model": "stt-async-v5",
    "items": [ { "…": "transcript item" } ]
  },
  "truncated": true,
  "next": { "tool": "get_conversation", "arguments": { "id": "…", "include": "transcript", "from_time": "2026-10-14T10:24:41+07:00", "max_chars": 30000 } }
}
```

`include: "summary"` leaves out `transcript`; `include: "transcript"` leaves out `overview`, `followUps`, and
`notes`. `transcript` is absent when the conversation has none yet (`hasTranscript: false`); `itemCount` counts the
window asked for (items with `from_time` ≤ `at` ≤ `to_time`), `shownCount` what fits. A time without an offset
is read on the conversation's wall clock. `gaps` lists every lost gap and the quiet gaps of a minute or more;
shorter quiet stretches count in `quietMinutes` and appear as transcript items. An unknown id is `found: false`
with `candidates`, conversations whose title matches the id as words:
`[ { "id", "title", "url", "day", "startedAt" } ]`.

### `search`

Arguments: `query`; optional `from`, `to` (days), `kinds` (any of `conversation`, `recap`, `brief`, `followUp`,
`note`; default all). Full-text search with stemming over titles, overviews, tags, transcripts, recaps, briefs,
follow-ups, and notes, best first. ChatGPT's canonical search shape is the `results` array's `id`, `title`, and
`url`; the rest is additive.

```json
{
  "summary": "8 matches for “tiles”; the best is Kitchen tiles with Sam on October 14.",
  "query": "tiles",
  "results": [
    {
      "id": "conv-kitchen",
      "title": "Kitchen tiles with Sam",
      "url": "https://pebbleaudio.okgodoit.com/c/conv-kitchen?t=312",
      "kind": "conversation",
      "day": "2026-10-14",
      "at": "2026-10-14T10:10:12+07:00",
      "snippet": "…the matte **tiles** hide water spots, and the grout…"
    },
    { "id": "recap:2026-10-14", "title": "Wednesday, October 14: Tiles, teeth, and the launch", "url": "…/d/2026-10-14", "kind": "recap", "day": "2026-10-14", "snippet": "…" }
  ],
  "truncated": false
}
```

| Kind | `id` | `url` |
| --- | --- | --- |
| `conversation` | the conversation id | the first transcript turn that matches (`?t=`), else the conversation |
| `recap` | `recap:{day}` | the day |
| `brief` | `brief:week:{startDay}` or `brief:month:{yyyy-MM}` | the brief |
| `followUp` | `followUp:{id}` | where it was said, else its day |
| `note` | `note:{id}` | its conversation, else its day |

`snippet` marks matched words with `**`. `at` is the matching moment when there is one. `truncated: true`
means more matched than fit; the `summary` says how many, and a narrower `query`, `from`/`to`, or `kinds` finds
the rest (there is no cursor: ChatGPT's `search` takes a query only).

### `fetch`

Argument: `id` (any `id` from `search`, or a bare conversation id). ChatGPT's document shape:

```json
{
  "summary": "Kitchen tiles with Sam, Wednesday 10:05 AM to 10:41 AM, 36 minutes, 1 minute of lost audio.",
  "id": "conv-kitchen",
  "title": "Kitchen tiles with Sam",
  "text": "Kitchen tiles with Sam\nWednesday, October 14, 2026, 10:05–10:41 (Asia/Jakarta)\nPeople: Roger, Sam\nTags: kitchen renovation, home\n\nSam and you compare…\n\nTranscript:\n[10:05:12] Sam: The matte ones hide water spots.\n[10:09–10:10] (lost audio, watch)\n[10:14–10:16] (quiet)\n…",
  "url": "https://pebbleaudio.okgodoit.com/c/conv-kitchen",
  "metadata": {
    "kind": "conversation",
    "day": "2026-10-14",
    "startedAt": "2026-10-14T10:05:00+07:00",
    "endedAt": "2026-10-14T10:41:00+07:00",
    "timeZone": "Asia/Jakarta",
    "people": ["Roger", "Sam"],
    "tags": ["kitchen renovation", "home"],
    "quietMinutes": 2.0,
    "lostMinutes": 1.0,
    "truncated": false
  }
}
```

`text` is plain text: the title, the time, the overview, then the transcript one line per turn
(`[HH:mm:ss] Name: words`, with `(low confidence)` after turns below 0.6) and one per marker
(`(quiet)`, `(lost audio, watch)`, `(music)`). For a recap, brief, follow-up, or note it is that item's own text.
When cut, `metadata.truncated` is true and `metadata.next` continues with `get_conversation`. An unknown id is
an error result (ChatGPT's fetch has no "not found" shape).

### `list_follow_ups`

Arguments: `status` (`open` (default), `done`, `snoozed`, `archived`, or `all`); optional `from`, `to` (days, by
when it was said or created); `cursor` (from `next`).

```json
{
  "summary": "You have 2 open follow-ups; the next is due Friday, October 16: Send Sam the tile samples.",
  "status": "open",
  "followUps": [ { "…": "follow-up" } ],
  "truncated": false
}
```

Open ones come by due date (soonest first, undated after), then newest; the others newest first. A further page:
`truncated: true` and `next.arguments.cursor`.

### `get_people`

No arguments.

```json
{
  "summary": "4 people appear in your conversations; Sam most often.",
  "people": [ { "name": "Sam", "personId": "person-sam", "conversationCount": 2, "lastDay": "2026-10-14" } ],
  "truncated": false
}
```

Everyone who speaks, by name, in a conversation the person shares (matched to a person or only named), most
conversations first, at most *Items per assistant answer*. Two people with
the same name are two entries with different `personId`.

### `get_tags`

No arguments.

```json
{
  "summary": "6 tags; the most used is product launch.",
  "tags": [ { "tag": "product launch", "conversationCount": 2, "lastDay": "2026-10-15" } ],
  "truncated": false
}
```

### `get_audio`

Arguments: `conversation_id`; optional `start`, `end` (instants or seconds from the conversation's start;
default from its start for the *Longest audio clip* setting, 20 minutes).

```json
{
  "summary": "The clip is ready: Kitchen tiles with Sam from 10:10 to 10:15.",
  "status": "ready",
  "conversationId": "conv-kitchen",
  "title": "Kitchen tiles with Sam",
  "url": "https://pebbleaudio.okgodoit.com/c/conv-kitchen?t=300",
  "startedAt": "2026-10-14T10:10:00+07:00",
  "endedAt": "2026-10-14T10:15:00+07:00",
  "audioUrl": "https://pebbleaudio.okgodoit.com/clips/0d6c….m4a?exp=1792555200&sig=…",
  "audioExpiresAt": "2026-10-21T10:12:00+07:00",
  "coveredFrom": "2026-10-14T10:10:00+07:00",
  "coveredTo": "2026-10-14T10:15:00+07:00",
  "minutes": 5.0,
  "lost": [ { "startedAt": "…", "endedAt": "…", "minutes": 0.5 } ]
}
```

| `status` | Means | Fields |
| --- | --- | --- |
| `ready` | The clip is here. `audioUrl` plays it (`audio/mp4`, byte ranges) until `audioExpiresAt`. | `audioUrl`, `audioExpiresAt`, `coveredFrom`, `coveredTo` (what the audio really covers, shorter when some was lost), `minutes`, `lost` |
| `requested` | The phone was asked; it uploads on its next sync (usually minutes while it is recording; it may be out of reach). Ask again later. | `requestId`, `waitingUntil` (when the request stops waiting) |
| `notAllowed` | The person has not allowed clips on the phone. Nothing was asked. | |
| `unavailable` | No audio to give. | `reason`: `gone` (the phone no longer has it), `failed` (the phone or the server could not make it), `notDelivered` (the phone did not answer in time), or `notFound` (no such conversation) |

`startedAt`/`endedAt` are the span asked for, after it was kept inside the conversation and the longest-clip
setting. When ready, the same link is also in the result's `_meta` for widgets (the model never sees `_meta`):

```json
"_meta": { "pebbleaudio/audio": { "url": "https://…/clips/….m4a?exp=…&sig=…", "expiresAt": "2026-10-21T03:12:00.000Z", "mimeType": "audio/mp4", "conversationId": "conv-kitchen", "startedAt": "2026-10-14T03:10:00.000Z", "endedAt": "2026-10-14T03:15:00.000Z" } }
```

(`_meta` times are UTC.) A span outside the conversation is an error result.

### `create_follow_up` (write)

Arguments: `text`; optional `why`, `quote`, `due_at` (an instant), `priority` (`low`, `normal`, `high`),
`source_conversation_id`, `source_at` (instant or seconds from that conversation's start).

```json
{
  "summary": "Added a follow-up: Call the tile shop about grout. It reaches your phone on its next sync.",
  "status": "added",
  "followUp": { "…": "follow-up, origin assistant, waitingForPhone true" },
  "requestId": "0199f6a0-…"
}
```

### `update_follow_up` (write)

Arguments: `id`; optional `done` (boolean), `text`, `due_at`, `snoozed_until` (instants, or `none` to clear),
`archived` (boolean).

```json
{ "summary": "Marked done: Send Sam the tile samples.", "status": "updated", "followUp": { "…": "follow-up" }, "requestId": "…" }
```

### `create_note` (write)

Arguments: `conversation_id`, `body`; optional `title`, `citations` (`[{ "at": instant or seconds, "end_at"?: … }]`
in that conversation).

```json
{ "summary": "Added a note to Product launch plan. It reaches your phone on its next sync.", "status": "added", "note": { "…": "note, origin assistant, waitingForPhone true" }, "requestId": "…" }
```

Write `status` values: `added` / `updated`, `unchanged` (the change changed nothing; `update_follow_up` only),
`notAllowed` (the person has not allowed assistants to add to their archive on the phone; nothing was stored),
and `notFound` (no such follow-up or conversation in the archive). A connection without `archive:write` gets an
error result instead, saying the assistant has to be reconnected with permission to add follow-ups and notes.

## Resources and prompts

For clients that use them (Claude's composer menu, for one):

| URI template | Contents |
| --- | --- |
| `conversation://{id}` | `text/markdown`: the conversation as `fetch` renders it, capped like `fetch` |
| `day://{date}` | `text/markdown`: the day's recap, coverage, and conversation list as `get_day` gives them |

| Prompt | Arguments | Asks the assistant to |
| --- | --- | --- |
| `brief_me_on_a_day` ("Brief me on a day") | `date` (optional, default yesterday) | read `get_day`, open what matters, and brief in five lines with links |
| `what_did_i_promise_this_week` ("What did I promise this week") | none | read `list_follow_ups` for this week and the conversations behind them, and list promises with links |

Every tool call and resource read is logged to the AI-read log (client, tool, the ids it returned), which the
phone shows.
