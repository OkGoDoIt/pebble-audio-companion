# Marked moments

2026-10-24. A mark means “I want to return to this.” It is useful without AI, without a
transcript, and even when recording is paused. It never starts recording or changes consent.

## The experience

- Hold the assigned watch button, feel one short tap, and carry on. The mark is the instant of
  the press; context normally starts shortly before it, because people mark something they
  have just heard.
- Today has a permanent **Marked moments** entry, including before the first recording. History
  has the same entry. It opens the collection, newest first, with a time and nearby words.
- Today conversation rows show their marks as timestamped pin links. History places the same
  links under the conversation or quiet interval on the day, and counts them on the week and
  month rows. Marks without any recording still keep their day reachable. All use the existing
  logical day (5 AM to 5 AM), including marks shortly after midnight.
- Live and saved transcripts show tappable pins among the words; they appear as soon as a mark
  is saved, before AI review or durable transcription. The same detail opens from every pin.
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
post-install battery checks for that build are recorded below.

On 2026-10-25 at 00:09 +07 the collection/review build (`70943f16-dirty`, built
2026-10-24T17:08:11Z) was installed over the main app after a verified 3.5 GB backup. The wearer
confirmed all three existing marks appeared. Two completed their nearby AI review with no
suggestions; the third had no nearby speech. A fourth mark arrived and was saved live at 00:10:59.
The ten-minute report passed, settling near 1 CPU-second per background minute, with no new app
crash reports. All ten-minute samples were charging. The October 25 morning check also passed,
with 11 eligible on-battery samples averaging 0.755 CPU-second/minute and no new app crash
reports. Most of the night was plugged in, so this does not establish overnight battery drain.

The contextual Today/History/live-transcript follow-up passes 47 simulator tests (clean
xcresult on iOS 26.5), 45 focused package tests, and state-initialization checks. The final
accessibility adjustment passes all six moment tests. Real SwiftUI renders were inspected at
375, 820 and 1024 points in light/dark and at accessibility3. The existing medium History card
also now wraps its time line at accessibility sizes instead of extending off the card.

On October 25 at approximately 11:15 +07, G17 received the contextual update after a fresh
3.5 GB backup. The installed Release build is `e6c1f97d-dirty`, built `2026-10-25T04:14:18Z`,
including feature commit `3fe45ed0`; codesign verification passed. A post-install database read
confirmed all four moments and all 15 notes exactly match the backup. The phone locked during
the build, so iOS refused the final automatic launch. Opening Pebble Audio once is still needed
before recording-resumption, physical UI and +10-minute CPU checks can be completed. The
next-morning check is scheduled for 08:00 +07 October 26 and must verify the actual running build.

Firmware `v4.41.0-668-gb2221949f` is prepared in Desktop/iCloud, **not flashed**. The installed phone
app supports it; marks saved by the existing firmware remain readable, with its old delivery limits.
