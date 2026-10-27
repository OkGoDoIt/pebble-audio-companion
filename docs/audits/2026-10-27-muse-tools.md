# Muse tool access audit — 2026-10-27

Scope: all tools registered by native iOS `MuseTools`, their consent/execution paths, watch
firmware actions, BLE results, and app data providers. The official Core Devices phone app is
unchanged. This is a source/test audit; prepared firmware is not physical-watch verification.

## Completed implementation

- **Actual native timers.** Muse uses Timer by Pebble/Core Devices, UUID
  `c64aae42-b822-4d6d-995b-bc7c38e843f4`: eight durable countdown records and the app's normal
  wakeup alerts. List/create/get/pause/resume/update/restart/cancel. No private background
  countdown fallback on older firmware. The native app must be installed and closed; its
  version-1 41-byte saved format is checked before access. Labels are unsupported and refused.
  IDs refresh after native UI edits. Atomic settings transactions preserve unrelated preferences,
  retain old data on failure, and recover complete writes after interrupted commit. Byte-by-byte
  power-loss tests cover the commit boundary. This replaces the initial four-slot implementation.
- **Alarms.** Native one-time, everyday, weekday, weekend, and custom-day regular/smart alarms;
  get/list/create/update/delete, enable/disable, sound, vibration, and tone. Omitted fields remain
  unchanged. New action kind 13 prevents old firmware silently ignoring options. Results read
  back the saved alarm; malformed/duplicate snapshots fail as a whole.
- **Watch status.** Fresh reachability, capability revision, local time/offset/timezone, and actual
  capture state when recording control is allowed. Watch failures distinguish unsupported,
  unavailable, not found, full, ambiguous, busy, incompatible data, and unconfirmed writes.
- **Music.** Report player state and volume only when supported, alongside title/artist. Command
  dispatch is separate from observed playback. Toggle-only players require a known state; an
  already-satisfied play/pause is a no-op. Metadata age is explicitly unavailable.
- **Quiet Time.** Read effective state, active manual/schedule/calendar/phone Focus sources, and
  temporary expiry. Expiry is invalidated by any later manual choice, even another On. Failure
  to arm expiry leaves the manual setting unchanged. The expiry itself is volatile across reboot.
- **Apps.** Page through installed app names and UUIDs; launch by UUID or unambiguous name. A
  tied best name match is refused. Success says launch requested, not startup confirmed.
- **Find watch.** Start and stop. Stop only cancels the MuseFind vibration owner, preserving alarm
  and notification vibrations. Zero duration cannot underflow the pulse count.
- **Invocation identity.** Both Muse transports pass invocation ids into tools. Same-id retries
  share results; distinct ids allow intentional identical actions. Minimal hashed receipts prevent
  duplicate writes across relaunch/reconnect, and argument reuse under one id is refused. The
  callback's old third argument was timeout; the invocation id had stopped at MuseLinkSession.
- **Permissions and validation.** Recheck question scope and revoked access after consent waits;
  refresh command registration when settings change. Calendar creation uses write consent.
  Invalid dates/ranges/numeric fields are refused, including reversed conversation ranges.
  Pause/resume describe requested intent until actual capture is observed.

## Completed phone-side implementation

- Recording returns intent, connection, observed capture (null when unknown), pause expiry,
  audio/report timestamps, and blocked watch state. Pause/resume awaits the capture request,
  then reports whether observed capture agrees instead of claiming it started or stopped.
- Saved moments return stable IDs, paginated list/detail, notes, nearby recorded context and
  links, note edits, and deletion tombstones. A mark remains separate from a reminder and can
  be saved without audio. Transcript-read grants do not authorize moment edits/deletes.
- Health uses the watch's date/offset rather than the phone's calendar. Missing days are null,
  today is partial, sample coverage is unknown, and latest heart rate includes its age.
  Disabled tracking, unsupported firmware, no samples, connection failure, and malformed data
  remain distinct. Older firmware without timezone inspection returns unknown dates.
- Calendar lists calendars/accounts and paginated event occurrences, with get/add/edit/delete,
  selected calendar, all-day exclusive end dates, location, timezone, and recurrence. IDs encode
  the exact occurrence so EventKit cannot substitute the first event in a repeating series.
  Repeating edits/deletes require occurrence/future scope; recurrence changes require future.
  Older read/add grants require fresh permission for edits/deletes. Omitted properties survive.
- Reminders support pagination, exact list IDs and account names, individual reads, priority,
  recurrence, and partial edits. Duplicate list names never silently select the default account.
  App-held reminders explicitly refuse times, notes, priority, and recurrence that they cannot
  preserve. Apple repeating reminders expose the next occurrence after completion.
- Conversations expose IDs, links, pagination, text continuation, live/processing state,
  truncation, and saved-transcript coverage. Search applies the requested wall-time window to
  turns after conversation-piece ownership and the gap-aware media clock. Untimed partial
  pieces are omitted and flagged. A turn beginning inside the range may extend past its end;
  that scope is explicit. Full detail remains available by ID. Deleted/hidden conversations
  stay excluded; search snippets are never mistaken for offsets into the full transcript.
- Follow-ups page review/skipped/decided items. Acceptance applies title, due day, and priority
  atomically, optionally choosing an Apple list when Apple is the configured reminder home.
  Edits and reopening require a separate upgrade grant. Reopen returns the suggestion to review
  and removes its linked reminder; failures retain the mapping for retry. Delivery is reported
  as pending until the real Apple identifier is saved. Concurrent sync cannot create duplicates.
- Turning a source off while a read is in progress suppresses its eventual result. Settings and
  privacy disclosures describe the new write capabilities; no upgrade enables a source.

## Supported limits

Native Timer has eight slots, no labels, and must be closed while Muse accesses its records.
Complex existing EventKit recurrence constraints are flagged and preserved on ordinary edits;
explicit rule replacement supports daily/weekly/monthly/yearly intervals, weekdays, month days,
months, and count or end date. Full-series edits before a selected occurrence are not inferred.
App-held reminders remain day-based. Physical watch/app behavior and Apple account writes are
separate from fake-provider and simulator verification.

## Validation and deployment evidence

The initial clean companion cdc6c619 was installed on G17 at 18:09:16+07, with recording and Muse
reconnected. The ten-minute cost check passed while charging; it does not establish battery use.
No new app crash was found. Backup/live database integrity and retained counts matched (1,498
conversations, 591 follow-ups, nine speaker corrections, two people); processing jobs advanced.

Native timer and PFS/wakeup work passed 14 host suites. The next watch-control extension passed
six focused host suites, 121 Muse runtime tests, 14 wire tests, golden fixtures, and Kotlin protocol
and transport tests. 150 protocol fixtures match across C, Swift, and Kotlin. Target builds and
physical verification remain separate gates.

The coordinated Focus changes are committed and included. The current firmware packages are
**v4.41.0-678-g49b06928d** (49b06928d), with native Timer, Focus, complete watch controls, and
health outcome fixes. Both target builds succeeded; Desktop and iCloud PBZ SHA-256 values match.
The watch has not been confirmed flashed.

The combined phone update remains blocked by G17 being unavailable and the new Focus extension
requiring an Xcode account/App Groups provisioning profile. No entitlement or extension was
removed to bypass this. The initial installed build is not the final implementation described
above. Final test results and the companion commit are recorded in the workspace progress log.
