# Muse tool access audit — 2026-10-27

Scope: every command registered by the native iOS companion (`MuseTools.commands`), its execution
and permission path, the watch-action firmware, the BLE result path, and the app data providers.
The official Core Devices app is reference only and is unchanged. This is a source/test audit;
real Muse and watch behavior needs the updated app and firmware installed together.

## Native Timer correction and follow-through (in progress)

Roger clarified that timers must appear in **Timer by Pebble/Core Devices**, rather than a
separate background store. The original four-slot timer implementation below was insufficient.
The replacement uses the native app's eight durable timer records and normal wakeup alerts.
The native app must be installed and closed while Muse manages it. Incompatible data is refused;
list/read failures never become an empty list. Native labels are unsupported and explicitly refused.
New callers require action kind 12 and never fall back to hidden countdowns on older firmware.
Existing native preferences and unrelated records are preserved in an atomic storage rewrite.

The callback's formerly discarded third argument was timeout, not invocation id. Invocation
ids actually stopped at MuseLinkSession. Both incoming transports now carry them to the tool
executor. Different ids allow intentional identical actions; a repeated id shares its pending
or completed result. Minimal hashed receipts prevent replay after relaunch, and argument reuse
under the same id is refused. Consent waits recheck question scope and revoked access. An open
conversation's command registration refreshes when tool settings change.

Deployed the first tested app cdc6c619 to G17 at 18:09:16+07. Recording and Muse reconnected.
Charging-only post-install cost check passes; no new app crash logs. Backup/live database integrity
passes with 1,498 conversations, 591 follow-ups, nine speaker corrections, and two people preserved;
voice job processing advanced from 603 to 617. Native Timer replacement is not yet installed or
physically verified. The remaining inventory below is still being implemented.

## Implemented in this change

- Full watch countdown lifecycle through `watch.timers`: list, create, get, pause, resume,
  update, restart, cancel. `watch.set_timer` uses the same implementation. A result includes the
  watch-issued id, label, running/paused/finished state, time remaining and restart duration.
  Updating a label preserves time; updating seconds sets time remaining and restart duration,
  preserving paused state. No slot numbers are exposed as stable ids.
- Four live/paused timers; finished records remain available until reused. Old kind-1 timers
  are in the same store. Timers run without the phone, but do not survive a watch reboot.
  Paused timers do not consume a running timer callback. No polling or flash writes added.
- Timer callbacks cannot ring a cancelled/replaced record. Rescheduling fails rather than
  waiting for a callback holding the same lock. A finished timer requires explicit restart.
- Concurrent identical writes share one result. Timer creation aliases share a duplicate key.
  Duplicate history is cleared for a new user question, so an intentional second timer works.
  Revoking a tool beats cached success. Timer edits invalidate earlier cached timer outcomes.
- An unconfirmed timer write returns `outcome_unknown`; repeating it in the same question does
  not issue another write. Read timer state to resolve it. Older firmware fallback occurs only
  after definitive Unsupported, only for creation, and explicitly says management is unavailable.
- Calendar additions now use the change-consent path rather than read consent. Reading once
  cannot silently authorize writing. The prompt asks specifically about adding calendar events.
- Invalid calendar dates/ranges and reversed conversation ranges fail explicitly. The latter
  previously reached a provider that constructs a Swift Range and could trap on reversed bounds.
  Recap dates/periods and health/find/Quiet Time/recording numeric limits no longer silently default
  or clamp malformed supplied values.
- Recording pause/resume results describe the requested capture intent. The provider enqueues a
  watch update; returning `recording: true` previously claimed actual capture before confirmation.
- Mirrored C/Swift/Kotlin timer wire contract and eight generated golden fixtures. Restored the
  previously missing alarm-management contract in the app's protocol document from the firmware copy.

## Complete inventory and remaining gaps

| Tool | What it can do after this change | What should be added or corrected next |
|---|---|---|
| `watch.set_timer`, `watch.timers` | Full countdown lifecycle, status and labels | Optional durable timers across reboot; wearer-facing list/control screen; distinguish unavailable management before a call through capability discovery. Keep reboot persistence explicit until implemented. |
| `watch.set_alarm`, `watch.alarms` | Create regular/smart one-time alarms; list, edit time/mode/enabled, delete; preserve recurrence | Create/edit repeat days; expose sound/vibration controls if native platform supports them; return verified resulting alarm after update. Existing list decoder drops malformed rows and defaults bad numeric fields to zero: make it reject the whole malformed snapshot. |
| `watch.music` | Play/pause/next/previous, volume steps, title/artist | Actual playback state, volume where available, distinguish command dispatched from confirmed playback. Rapid repeated next/volume commands need invocation-id duplicate handling, not argument-only caching. |
| `watch.quiet_time` | On/off, optional temporary duration | Read actual effective state, scheduled/manual causes and expiry; avoid timer-based expiry undoing a later manual wearer change. |
| `watch.open_app` | Open by best name match | List installed apps and stable ids; refuse ties instead of choosing the first equally ranked name. Report launch requested until the app actually opens. |
| `watch.find` | Buzz/light for 1–30 seconds | Stop finding early; precise unavailable/unsupported/queued result. |
| `recording` | Request pause/resume; persist a marked moment with optional note | Read actual capture state, paused-until, connection and reason blocked; return a saved moment id; list/get/rename/delete moments and link their context. Confirm actual capture after a requested transition. |
| `health.read` | Steps, distance, active minutes/calories, sleep, latest and daily heart rate | Include source timezone and freshness/missing-day coverage. Latest heart rate is not a history. Surface unsupported/disconnected separately from no data. Preserve current read permission. |
| `calendar` | List up to 40 events and add to the default calendar | Stable event/calendar ids; get/edit/delete with recurring-event scope; choose a calendar; all-day semantics, location/timezone and recurrence. Pagination/truncation marker. These expand the documented add-only contract and need matching disclosure/consent and tests. |
| `reminders` | Lists, read, create, edit/complete/reopen/move, delete; Apple and app home | Pagination beyond 60 (currently reports not_shown but offers no next page); list ids/account disambiguation for identical names; priority/recurrence. App-home reminders are day-only and lack notes: preserve the current explicit refusal, don't promise Apple feature parity. |
| `conversations` | Search bounded transcript excerpts, ask own AI, day/calendar-week recap | Stable conversation ids, get detail and deep link, pagination/coverage/truncation and exact matched time scope. Provider uses conversation pieces correctly. Query matches and source attribution should remain distinguishable from full-library coverage. |
| `followups` | Read 40 suggestions, accept into reminder or skip | Pagination; edit title/due/list while accepting; undo/reopen. Match the app's editable suggestion cards. A suggestion remains distinct from an existing reminder. |

## Recommended order

1. **Status and result honesty.** Add a small capability/status read covering connected watch,
   supported action revisions, local time/timezone, actual capture and Quiet Time. Don't expose
   secrets/device identifiers or extra health data. Use structured result codes for unsupported,
   disconnected, not found, full, permission denied and unconfirmed. Fix malformed alarm lists
   and ambiguous app matches before broadening those write tools.
2. **Finish existing management surfaces.** Recurring alarms, calendar get/edit/delete and calendar
   selection, follow-up edits at acceptance, reminder pagination/list identity. Each write should
   preserve omitted fields and return the resulting entity. Recurring-calendar deletes must name
   the instance/series scope.
3. **Make saved information retrievable.** Marked-moment lifecycle, conversation ids/detail links,
   page cursors and explicit coverage. A successful mark should immediately be addressable by id.
4. **Harden execution identity.** Carry Muse's invocation id (currently discarded by the connector
   callback) through dispatch, and track definitive/unknown outcomes independently of tool params.
   This allows intentional repeated commands within one question without allowing transport retries
   to duplicate them. Persist only the minimum required journal; don't replay uncertain writes on
   reconnect/relaunch. Re-check permission and question scope after long consent waits. Verify tool
   registration refresh after settings change on an already-open conversation.
5. **Optional watch-native improvements.** Timer list/control UI and reboot recovery, stop-find,
   richer player controls. These need watch UX and hardware validation, not just another tool schema.

## Verification and release boundary

Tests exercise timer creation/status, pause-time freezing, label-only edits, changed durations,
capacity with paused timers, disconnect survival, expiry/restart, stale ids and cancelled alerts;
app tests exercise request validation, complete list decoding, unknown outcomes, duplicate writes,
new questions, disabled tools, older firmware, calendar consent and invalid dates.

Final validation: 173 focused Swift tests plus the golden-fixture round-trip test; 12 Kotlin
protocol and 30 transport tests; all 125 generated fixtures; ten focused firmware suites; six
analytics heartbeat guards. All passed. The final unsigned iOS Release device build passed with
one known existing Sendable warning in SettingsRemindersScreen. Both PT2 firmware slots built as
`v4.41.0-671-g696dced85` and were mirrored to the usual Desktop/iCloud filenames. App source commit
`9a4c70db`; firmware commits `29c6f27e1` and `696dced85`. Nothing was installed or flashed.
Detailed evidence is recorded in the workspace implementation progress log.
No source-level pass establishes physical watch behavior, phone battery cost, or deployment.
Install matching app and watch firmware, then ask Muse to create two labelled timers, list them,
pause one, change its label/duration, resume, cancel the other, let one ring, and restart it.
Repeat across a BLE disconnect; verify an intentional repeated timer request and an older-firmware
failure. After any phone install, run the documented ten-minute and next-morning cost gates.
