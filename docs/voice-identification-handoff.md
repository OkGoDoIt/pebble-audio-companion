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

- G17 runs companion build with watch samples + transcript selection (installed 2026-10-26
  ~15:45 +07 from main after `00fb6edc`). Previous build passed its ten-minute check (PASS,
  charging, no new crash reports). **Run the ten-minute cost check for this install** and diff
  systemCrashLogs against `crashes-before` (4 historical Pebble Audio reports; none new so far).
- Server (archive) runs `b04ab212`, healthy; no server change since.

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
1. **Learning follows naming by default** when recognition is on: the toggle defaults on; a
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
