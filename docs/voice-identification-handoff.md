# Voice identification — working handoff

Living notes for whichever agent continues this. Newest state first. The design of record is
`docs/voice-identification-plan.md`; the journal is the workspace progress log
(`UPSTREAM_THIRD_PARTY_BACKGROUND_AUDIO_IMPLEMENTATION_PLAN.md`). This file is the in-flight plan.

## Roger's directions (2026-10-26, verbatim intent)

1. **No manual clip picker.** "Identify a voice" (pick section/start/length) was rejected as too
   manual. Speaker changes happen *in the transcript*: select a section, then assign it to a
   different speaker, clear the automatic speaker, etc. — DONE (`1e66f6b5`, `60062654`).
2. **Train self through the watch.** The watch mic sounds very different from the phone mic.
   Several samples in different environments and different microphones — DONE (`de80c543`).
3. **Deploy continuously.** Every change goes to G17 (`./scripts/deploy-ios-rebuild.sh --device
   G17 --replace --skip-tests` after tests pass), then the ten-minute cost check
   (`./scripts/phone-cost-report.sh --minutes 11`) and a systemCrashLogs comparison.
4. **A sample of only Roger was refused as "More than one voice was detected"** (he turned his
   head toward/away from the mic). Must not happen — fix written, see "In flight".
5. **The watch mic is poor; one person often sounds like several people to the model.** Support
   manually labelling many clips as the same person and learning from all of them, robust to
   low, inconsistent quality. Think through every edge case and the labelling UX. — PLANNED below.

## State of the phone

- 15:45 +07 install of `e15ab431` (one-voice fix); its ten-minute check runs at 15:56 (report in session
  scratch `cost-3.txt` — rerun `./scripts/phone-cost-report.sh --minutes 11` if lost).
- 16:00 install of `cc929a84` (watch-clock calibration, detector gain, no Remember toggle) is running;
  ten-minute check PASS (charging), no new crash reports. Next-morning `phone-cost-report.sh` still due.
- Ask Roger to retry a watch sample (Quiet room) on this build; if it still fails, pull the open
  segment + sidecar (`devicectl device copy from … segments/<id>.meta.json|.spxlog`) and check the lag:
  sidecar mtime − (startTimeMs + lastSampleIndexExclusive/16).
- Server (archive) runs `b04ab212`, healthy; no server change since.

## Done since the plan below was written

- `1b27dd0b` watch sample window on the watch's clock (lag-calibrated, 45 s arrival wait);
  `DetectionGain` (speech detector input only, target −26 dBFS, ≤ +36 dB, soft limiter); crop floor
  −60 → −75 dBFS. Embedding recipe untouched (level-independent; saved voices stay valid).
- `cc929a84` plan step 1: naming always learns when recognition is on (≤ 5 longest paragraphs, > 30 s
  trimmed to first 30 s), never blocks the name; snackbar line when nothing could be learned or part
  sounded like someone else (`VoiceEnrollmentOutcome.otherVoiceSeconds`).
- Known wrinkle: `LiveVoiceSource.enrollPassage` starts a history run after every learned passage once
  ≥ 2 examples exist; with up to 5 passages per save that is up to 5 runs. Start it once per save.

## Root cause: watch sample said "not enough speech" (2026-10-26 15:42)

Pulled the open recording `seg-1793003836340-c1fe4e09-2` and metas of stream 3254668809 off G17
(copies in the session scratchpad only). **The watch's sample clock is not wall-clock time.**
`receivedAtMs − (startTimeMs + firstSampleIndex/16)` per recording: a steady ~27–30 s from 10-23 to
10-25 14:09Z, then growing ~1 min/hour overnight to ~910 s (15 min) by 10-26 05:26Z, stable since.
The sample counter evidently stops while the mic is off (overnight) without the stream restarting.
`WatchVoiceSampleReader.audio(fromWallMs:toWallMs:)` mapped the phone's start/stop through
`sampleClockAnchorMs + sampleIndex/16`, so a 20 s window pointed at audio 27 s–15 min in the future:
nothing → "not enough speech". Never worked on device; the kit test used a fixture whose clocks agree.
Fix: calibrate against arrival — the open recording's sidecar mtime vs its `lastSampleIndexExclusive`
gives (watch-clock lag + delivery delay); translate the phone window by it, pad the end, wait up to
~45 s for arrival. **Wider bug to raise with Roger:** `SegmentMeta.startWallMs` = min(anchored,
receivedAt) puts this recording 15 min early; transcripts/History/moments placement inherit it.

## In flight

**One-voice enrollment fix** (not yet committed when this was written): in
`VoiceRecognitionService.enrollmentTurns` stop throwing `.multipleSpeakers`. Instead: drop turns
flagged `overlap`; the cluster with the most usable speech is the sample; turns from other
clusters are kept only if their embedding's best cosine to any dominant-cluster turn is ≥
`policy.minimumSimilarity` (0.55); overlapping turns keep the earlier one; only "no usable
speech" throws (`.notEnoughSpeech`). Replace the test
`enrollmentRejectsOverlapAndDifferentAcousticVoicesEvenWithOneHumanLabel` with one proving a
second cluster that sounds like the first is kept and a dissimilar one is dropped. Then deploy.

## Plan: learning one person from many messy clips

Facts from the code (verify before relying on them):
- Matching (`SpeakerMatching.match`) is already exemplar-based: per example it takes the max
  cosine over the primary embedding and its codec variants, then requires ≥ `minimumExamples`
  (2) examples above `minimumSimilarity` (0.55) and a `minimumMargin` (0.10) over the next
  person. Exemplars (not a centroid) are the right shape for a voice with several "modes"
  (near/far, facing/turned, quiet/noisy). Profiles cap at 32 examples (`profileFull`).
- Naming and learning are separate today: the "Remember this voice" toggle in Who's speaking? is
  off by default and only shown for a 2–30 s passage when recognition is on.

Steps, in order:
1. (DONE `cc929a84`) **Learning follows naming by default** when recognition is on: the toggle defaults on; a
   selection of several paragraphs learns from each clean 2–30 s paragraph (cap per save ~5),
   not just the longest three. Unusable paragraphs are skipped silently (never an error that
   discards the saved name).
2. **Whole-speaker labelling.** The provider already groups a conversation into Speaker 1/2…:
   offer "All of Speaker 2 in this conversation" when one paragraph of a provider label is
   selected (one tap names every paragraph with that label in this conversation's pieces). Most
   real labelling is "this whole speaker is Dana".
3. **Profile capacity for many modes.** Replace the hard 32-example cap with pruning: keep the
   most diverse exemplars (farthest-point / drop the most redundant by cosine to its nearest
   sibling), never dropping the last exemplar of a recording session or microphone. Count
   distinct *sessions* (recordings) as independent evidence; crops from one session are not
   independent (already true for codec variants via confirmationID).
4. **Mislabel guard (inconsistent quality cuts both ways).** When a new labelled clip is far
   from every exemplar of the chosen person (best cosine < ~0.3) *and* matches another person
   (passes their threshold + margin), don't silently learn it: save the name, skip learning, and
   say one line ("Saved. This clip sounds more like Sam, so it wasn't used to learn Dana's voice").
   Far from everyone → learn it (a new mode of this person), that is the case Roger describes.
5. **Quality weighting.** Store per-exemplar quality (speech confidence, duration, an SNR
   estimate from the decoded PCM). Low-quality exemplars may support a match but not create one
   alone: a match needs at least one supporting exemplar above a quality floor.
6. **Negative evidence.** "Clear name" / a correction from Sam→Dana on an automatic match should
   suppress that exemplar pairing (there is a `voice_suppressions` table — check what it does) so
   the same wrong match isn't repeated; and the corrected clip becomes a Dana exemplar (step 1).
7. **Propagation with honesty.** After learning, re-run recognition on the current conversation
   immediately and on recent history in the bounded queue (existing `recognizeHistory`, undoable).
   Never overwrite manual names. Report "Found Dana in 4 more places" via the snackbar.
8. **Per-person calibration (later).** With ≥ 6 exemplars from ≥ 3 sessions, leave-one-session-out
   scores give a per-person threshold; until then the global 0.55/0.10 stands.

### Labelling UX for messy audio (design notes, not built)

The watch makes one person look like several "voices" to the model, so labelling has to be cheap,
repeatable, and forgiving — and every answer should teach.

- **Confirm, not just correct.** A recognized name gets a one-tap "That's Dana" (positive training,
  explicit, so it doesn't break "predictions never train"), next to "Change speaker". Confirmations
  are the cheapest high-value labels.
- **Who is this? queue.** After recognition, recurring *unnamed* voices across recent conversations
  are grouped conservatively by embedding (agglomerative, strict threshold, ≥ 2 conversations) and
  offered one group at a time: three 4-second snippets from different conversations, a person picker
  (known people + new), "Not one person" (splits the group), "Skip". Naming a group labels its
  members as suggestions applied after the answer, and teaches from each member.
- **Same person as…** Because one person splits into groups, the queue and the voices list allow
  "This is also Dana" merges; the people picker shows each person's snippet so the user can listen.
- **Not the wearer's mic only.** The wearer is usually loudest and closest; level can be a weak prior
  for "you" when choosing which group to ask about first, never as identity proof.
- **Pseudo-people.** "TV / radio" as a label that is excluded from participants, Ask, and follow-ups,
  so a news anchor stops being asked about.
- **Provider merged two people into one Speaker 1.** Selecting the run yields mixed audio; the
  one-voice filter learns only the dominant voice and the snackbar says part was left out. Offer
  "Split this speaker" later (needs acoustic sub-clustering of the run).
- **Low-margin names** render with a subtle uncertainty mark and sort first in review.

Edge cases to cover with tests: one person split into two clusters in one clip; two real people
in one selection (the minority voice is dropped, not learned); a selection mixing named and
unnamed paragraphs; untimed paragraphs in a selection (sheet refuses whole selection today —
reconsider: skip them instead?); a label made on an open (still recording) segment (now copied
out as `watch-enrollment:`); the same clip labelled twice (dedupe by source range); relabelling a
clip from Dana to Sam (remove the Dana exemplar from that range — check `SpeakerCorrectionStore`
deletes intersecting examples of other people: line ~244 does `DELETE FROM voice_examples WHERE
segmentId = ? AND … AND personId IS NOT ?`); deleting the source recording (exemplars are kept by
design); profile full; recognition off (naming still works, nothing learned); two people with the
same display name (ids, not names).

## Verification habits

- Kit: `cd ios/PebbleAudioKit && swift test` (2,621 tests 2026-10-25; 2 known SearchKit issues).
- App: `xcodebuild test … -scheme App -destination 'platform=iOS Simulator,id=<iOS 26.5 iPhone 17>'`;
  read `xcresulttool get test-results summary`. 800 passed / 8 skipped at `60062654`.
- Real model E2E: `TEST_RUNNER_PEBBLE_VOICE_NATIVE_CORPUS=/tmp/pebble-speaker-evaluation`
  `-only-testing:AppTests/VoiceNativeEndToEndTests`.
- Running the App tests rewrites `docs/mockups/moments/built/*.png` and `ios/App/Generated/BuildInfo.swift`;
  `git checkout` them before committing. Never `git add -A`.
- Demo review in the simulator: `xcrun simctl launch <udid> dev.audiocompanion.app.dev -demo-data
  -onboarding.skip -route conversation/coffee-dana` (sample voice clips on Coffee with Dana); the real
  app with `-onboarding.skip -route settings/voices` shows setup.
- Don't edit sources while `deploy-ios-rebuild.sh` is compiling; it builds the working tree.
