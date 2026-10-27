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

## Phone-side work still in progress

1. Recording status and confirmation, paused-until/connection/blocked reason; saved moment id,
   list/get/note edit/delete, and context links.
2. Health source timezone, freshness, missing-day coverage, and distinct unsupported/no-data
   outcomes. Firmware heart-rate day boundaries now follow local midnights across DST.
3. Calendar ids/calendars, get/edit/delete with explicit recurring-event scope, calendar selection,
   all-day dates, location/timezone, recurrence, and pagination. Update disclosure/consent and tests.
4. Reminder pagination, stable list/account selection, priority, and recurrence. Keep app-home
   day-only/no-notes limitations explicit instead of silently dropping unsupported fields.
5. Conversation ids/detail/deep links, paginated excerpts, exact time scope and truncation/coverage.
   Continue reading conversation pieces, never whole segments.
6. Follow-up pagination, edits while accepting into a chosen reminder list, and undo/reopen.
   Suggestions remain separate from commitments and existing reminders.

## Validation and deployment evidence

The initial clean companion cdc6c619 was installed on G17 at 18:09:16+07, with recording and Muse
reconnected. The ten-minute cost check passed while charging; it does not establish battery use.
No new app crash was found. Backup/live database integrity and retained counts matched (1,498
conversations, 591 follow-ups, nine speaker corrections, two people); processing jobs advanced.

Native timer and PFS/wakeup work passed 14 host suites. The next watch-control extension passed
six focused host suites, 121 Muse runtime tests, 14 wire tests, golden fixtures, and Kotlin protocol
and transport tests. 150 protocol fixtures match across C, Swift, and Kotlin. Target builds and
physical verification remain separate gates.

The coordinated Focus chat owns the current committed firmware package build and phone install
attempt. App 5b5f28e3 contains Focus plus ab98002b native timer/invocation changes; a new Focus
App Group provisioning profile requires an Xcode account. Firmware target-build corrections
are dabfb63bc (redundant uint8 bound) and 869094768 (real worker metadata API), after cc3cb79f5.
The newer watch controls are not in that earlier deployment candidate.
