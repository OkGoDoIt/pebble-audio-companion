# Marked moments

2026-10-24. A mark means “I want to return to this.” It is useful without AI, without a
transcript, and even when recording is paused. It never starts recording or changes consent.

## The experience

- Hold the assigned watch button, feel one short tap, and carry on. The mark is the instant of
  the press; context normally starts shortly before it, because people mark something they
  have just heard.
- Today has a permanent **Marked moments** entry, including before the first recording. History
  has the same entry. It opens the collection, newest first, with a time and nearby words.
- Open a moment to see the surrounding transcript, add a note, or open the conversation cued
  to that context. Navigation uses the conversation's pieces and the recording's media clock.
- Every mark queues an AI review of nearby speech under the existing AI/privacy settings.
  Review explains what may be worth keeping and suggests up to three useful next steps (a
  reminder, an idea to explore, or information to look up). No actionable content is valid.
  **Make a reminder** is an explicit action with editable wording; other suggestions open Ask.
  Spoken “remind me…” requests continue to work independently.
- A mark with no recording stays visible. Missing audio, no speech, and a transcript still
  being prepared have distinct descriptions. Never jump to an unrelated nearest recording.
- Deleting a mark deletes only the mark. Audio follows the existing retention policy; a mark
  does not promise permanent preservation of its recording. This is stated in the detail.
- Muse's mark action creates the same kind of moment and saves its optional label as a note.

## Engineering contract

Marks are authoritative user data, independent of conversation IDs (grouping can change).
Existing timestamps are retained. New marks also retain whether recording was active; unknown
legacy values stay unknown. Notes are local text, not AI-generated paraphrases. Context is
quoted from the conversation's own transcript, within 45 seconds before / 15 seconds after the
mark; it is not cached permanently outside the source recording.

Visible surfaces observe only while on screen, cancel on background, and publish only changed
values. Reviews use the existing AI stage, at most two calls per pass, with persisted results
and a 30-minute failure backoff. A review waits for durable transcription and does not read the
whole conversation. Deleting its source clears derived AI text and rejects in-flight results.

## Delivery and compatibility

The original watch sent once from an eight-item RAM queue. The updated firmware persists up to
eight marks and removes each only after the phone confirms its database commit. Retries preserve
the same identity. A full queue or failed flash write is an explicit failure, not a success tap.
Deleting a mark leaves an identity-only tombstone so a delayed retry cannot resurrect it.

The new receipt is capability-gated and mirrored in firmware, Swift, Kotlin and fixtures. Install
the new phone app before the new firmware. Older firmware remains compatible with the app, with
its existing delivery limits. Kotlin transport exposes the durable-storage callback; the new
collection and AI review are in the actively developed native iOS companion.

Marks and notes currently live in the phone database and its backups; they do not sync to the
archive server. Deleting a recording clears its derived review while keeping the explicitly
saved mark and note. Deleting a mark does not remove a reminder the person already chose to add.

## Evidence

A fresh read of G17 on 2026-10-24 found three marks, at 00:49:52, 00:49:56 and 00:51:42 +07 on
the recording's clock. The flight recorder confirms all three were received. The previous
screen had no collection or entry point, only pin rows deep inside a conversation transcript.

## Verification and rollout (2026-10-24)

The full Swift package suite (2,515 tests, two existing known issues), Kotlin protocol/transport
(41 tests), 117 wire fixtures, and 24 firmware targets passed. The native release app and both
firmware slots build. Migrating a copy of the phone database preserved all three existing marks.
Simulator tests reported 723 passing tests and the final moment checks passed, but Xcode hung
before finalizing its result bundle. Component renders were reviewed; physical interaction and
post-install battery checks remain pending.

G17 disconnected before installation. The app has **not** been installed. Firmware
`v4.41.0-668-gb2221949f` is prepared in Desktop/iCloud, **not flashed**. Install the new companion
first, then the firmware. Marks saved by the existing firmware are already readable by the new app.
