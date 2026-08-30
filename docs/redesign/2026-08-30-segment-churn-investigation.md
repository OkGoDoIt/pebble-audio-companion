# Segment Churn Investigation — 2026-08-30 (Q8)

Why Roger's phone shows runs of 10–25-second segments during active use. Verdict first:

**RESUME reattachment is structurally impossible in the shipped pair, so every transport hiccup
mints a new segment.** The watch does the right thing on reconnect — same stream id, RESUME
flag, spool rewound — but the two sides disagree about what "the same stream" means, and the
phone additionally disqualifies the reattach candidate before checking it. VAD/silence, mic
conflicts, low battery, and power save are all ruled out (they pause or gap; they never end a
stream).

## The root-cause chain

1. **Firmware sends fresh timestamps on RESUME.** `prv_send_stream_start_locked()`
   (`PebbleOS/src/fw/services/audio_companion/audio_companion.c:774-775`) recomputes
   `start_time_ms` / `start_monotonic_ms` **at send time**, not at stream birth. A RESUME
   re-announcement therefore carries different start timestamps than the original STREAM_START
   for the same stream id.
2. **The app requires those timestamps to match.** `SegmentStore.canContinue()`
   (`core/storage/.../SegmentStore.kt:139-156`) demands exact equality on nine fields including
   `startTimeMs` and `startMonotonicMs`. With (1), this is false on every reconnect →
   continuation silently fails → new segment. Nothing logs why.
3. **The app also disqualifies the candidate by ordering.** `SegmentStore.openSegment()`
   (`SegmentStore.kt:103-107`) closes any open segment as `Superseded` *before* trying
   continuation, and only `Interrupted` segments are eligible. So a RESUME start arriving while
   the phone never noticed the link drop can never reattach even with matching fields.
4. **The firmware's disconnect handler is unreachable on real hardware.** NimBLE tears down
   CCCDs before dispatching disconnect, which clears the service's conn handle, so
   `bt_driver_audio_companion_handle_disconnect` hits its early-return
   (`src/bluetooth-fw/nimble/audio_companion_service.c:213-221`). Consequences: `authorized`
   latches across disconnects (contradicting `PROTOCOL.md` "any disconnect ends the session");
   on a bonded reconnect the persisted-CCCD restore marks the session ready **before** the app
   re-auths, so the watch spends its one re-announce early and can then stream data the app
   never saw a start for; a stranded `PausedPolicy` can survive reconnects; and the
   offline-overflow baseline is never re-snapshotted, so after the first overflow the
   brief-disconnect capture bridge parks the mic on the first offline frame of every later drop.
   Every host test drives the disconnect handler directly, so the suite can't see this.
5. **The cadence fits the receiver-liveness watchdog.** 15 s timeout
   (`audio_companion.c:66,878-892`); trips if ~3 consecutive 5 s keepalive writes are lost
   (two silent drop paths exist on the control-write ingest: an unchecked
   `system_task_add_callback` and a malloc failure path, `audio_companion.c:1443-1452`). Each
   trip stops capture; each revival re-announces with RESUME → with (1)+(2), one new segment
   per cycle, right in the observed 10–25 s band.

Also real but secondary: phone `PAUSE_REQUEST(reason=User)` is the one in-session path that
intentionally mints a new stream id per pause/resume pair; watch reboots always mint a fresh id
(check Settings → Audio Companion → Status reboot trace to rule in/out); connection-parameter
thrash from silence-mode enter/exit (Light mode: 5 s in, one loud frame out) can drop marginal
links.

**Ruled out:** silence suppression (gaps only, never ends streams), mic conflict / low battery /
power save / policy pause (pause + gap, same stream), spool overflow (gap only), stationary
power save (30-min timescale), `StopReasonError` (dead code — never sent).

## On-device confirmation (cheap)

- Settings → Detailed logs: "Recent segments" prints `state=stopped/interrupted/superseded` for
  the last 8 segments. Expected signature of this diagnosis: runs of `interrupted` (and/or
  `superseded`) with **no** reattached continuations, not `stopped`.
- Watch Settings → Audio Companion → Status: reboot-trace counters rule watch resets in or out.

## Fixes for the current pair (small, high daily value)

1. App: drop `startTimeMs`/`startMonotonicMs` from `canContinue()` equality (keep streamId +
   protocol/codec fields + provenance). The meta keeps the original start time, which is what
   the timeline anchors on anyway.
2. App: in `openSegment()`, treat a RESUME start whose `streamId` matches the open segment as a
   continuation in place (no supersede-close), and log the reason whenever continuation fails.
3. Firmware: capture `start_time_ms`/`start_monotonic_ms` once in `prv_begin_stream_locked()`
   and resend the stored values on re-announce (belt-and-braces with fix 1; also makes the
   re-announce truthful).
4. Firmware: make the disconnect path reachable (clear session state from the subscribe-TERM
   path or keep the conn handle until the disconnect event has been dispatched), and re-snapshot
   the offline overflow baseline.
5. Docs: PROTOCOL.md must document the RESUME flag, the 15 s liveness watchdog, and the actual
   session-survives-disconnect behavior.

## Requirements this bakes into the Swift rewrite (Q4)

- Reattach identity = stream id + codec/protocol params + provenance; **never** wall/monotonic
  start timestamps.
- A STREAM_START for the already-open stream id is idempotent/continuation, never supersede.
- Log every continuation failure with the failing field.
- The golden fixtures should gain RESUME re-announce cases (including fresh-timestamp ones).

## Design consequence for the redesign (independent of the fixes)

Segments are a storage/transport unit, not a UX unit. Even with all fixes, 15-minute rotation
and genuine interruptions will split one conversation across several segments. The new Today and
Library must group segments into **sessions/conversations** (time-adjacent, same context) and
render one card per session, with segment boundaries visible only inside detail (as part of the
honest gap story). The churn bug made this obvious, but it's true regardless.
