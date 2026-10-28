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

- **2026-10-28, noise suggestions:** "Who is this?" now has **Ignore All Clips** below "More than
  one person", plus **Ignore Clip** in each clip menu. Both save audio-range dismissals, never
  embedding-based negative evidence. All includes the group's crops beyond the three previews.
  Reanalysis, changed models, and recognition off/on preserve dismissals; deletion/retention
  clears them with the source. The existing queue context-menu dismissal uses the same durable
  path. G17 was freshly checked and **unavailable**; this change has not been installed.
  Kit: 2,697 tests passed (two pre-existing known segmentation issues); App: 823 passed / 8 skipped.
  The simulator interaction test covers individual dismissal, whole-group dismissal including
  hidden previews, and leaving an unrelated suggestion intact. DB tests cover reopen, reanalysis,
  adjacent/similar audio staying eligible, no training/naming, and stale naming after dismissal.

- On G17: `f69a8623` (installed 2026-10-27 18:32 +07): background recognition while charging, voice
  key after-first-unlock, queue cap removed, recent-first claims, faster pace, Play Longer / Open
  Conversation on clips, quotes from paragraph text. Its ten-minute check never ran: G17 left the Mac
  at 18:44 and did not return overnight (waiter gave up 06:44 10-28).
- On G17 since 2026-10-28 10:10: `6edbfc14` (fallback; launch waited on unlock). NOT on G17: the other agent's Muse/Focus commits up to
  `c90ffbd7`. Main tip installs on the next reconnect (waiter `scratchpad/deploy-then-check.sh`,
  deploying `scratchpad/bg` = main).
- Measured before the queue fix (18:20 DB): 512 pending jobs (the cap), 53 done, 5 recognized,
  506 unmatched crops; background slices ~0.3 s per 20 s of audio; no deviceLocked after the key move.
- Overnight cost report 10-26→27 passed (+2.5 %/h, charging). Server (archive) runs `b04ab212`.

## Done since the plan below was written

- `1b27dd0b` watch sample window on the watch's clock (lag-calibrated, 45 s arrival wait);
  `DetectionGain` (speech detector input only, target −26 dBFS, ≤ +36 dB, soft limiter); crop floor
  −60 → −75 dBFS. Embedding recipe untouched (level-independent; saved voices stay valid).
- `cc929a84` plan step 1: naming always learns when recognition is on (≤ 5 longest paragraphs, > 30 s
  trimmed to first 30 s), never blocks the name; snackbar line when nothing could be learned or part
  sounded like someone else (`VoiceEnrollmentOutcome.otherVoiceSeconds`).
- `9004844d` one recent-history recheck per save (past week, back to the labelled conversation) via
  `recognizeAfterLearning`, instead of a whole-archive run per learned paragraph.
- `0458f7f1` plan step 2: "All by this speaker (N)" in the selection bar — same provider label, same
  recording (labels restart per recording), same current name (never overwrites a decision).
- `21a580f9` "That's Dana" / "That's you" one-tap confirmation when everything selected was recognized
  as one person: becomes a manual name and teaches.
- `5962e12b` plan step 3: profiles no longer fill. ≤ 4 least-alike crops per passage (`diverse`); a full
  profile retires its most redundant crop (`retirements`), sparing each sample's last crop and guided
  samples while possible. Retirement deletes in the same write; the archive revocation trigger now has
  `WHEN OLD.retiredAtMs IS NULL` (migration `voice-example-retirement-v1`), so pruning neither withdraws
  archived names nor clears automatic ones. Real-model E2E still passes.
- **Step 4 (mislabel guard) dropped on purpose:** its main trigger — the model confidently says Sam, the
  person says Dana — is exactly the correction that must teach. Poisoning is bounded: the matcher averages
  each person's best two crops and abstains when two people are within the 0.10 margin, so a mislabel
  degrades to "unnamed", not a confident wrong name. Revisit only with evidence (e.g. a person whose
  crops sit inside another person's cluster → offer "Dana and Sam sound alike in some clips").

- `acaaf214` "who is this?" backend: unmatched crops kept sealed in `voice_unmatched_crops` (migration
  `voice-unmatched-crops-v1`; triggers drop them with the source's generation bump, source delete, and
  recognition off; cap 2,000), `SpeakerGrouping` (average linkage, threshold 0.6, ≥ 3 crops, ≥ 2 recordings),
  `VoiceRecognitionService.unknownVoiceGroups/nameUnknownVoice/dismissUnknownVoice`. **No UI yet.**
- `666b450a` "Who is this?" built per Roger's pick (A + C, B's picker, not on Today): People & voices
  "Voices to name" queue; quiet "· heard before" after an unnamed speaker's time in a conversation; both
  open `WhoIsThisSheet` (clips with quotes, single-choice checkmark people list, "Not Now" top-left,
  primary "Name in N recordings", full-size "More than one person" → checkbox page of every recording
  to name only the ticked ones; unticked stay unnamed and may regroup). Context menu "Don't Ask About
  This Voice". Speaker sheet switched to single-choice checkmarks too. Filled buttons dim when disabled.
  `DemoVoiceSource` (DEBUG, `-demo-data`) for review. Roger's reasoning on selection: one voice = one
  person; multi-select only for "which recordings are this person".
- `620867b5` grouping reads gated by a one-row fingerprint (an open conversation reloads per DB tick).
- `17a0049a` naming a group names each clip's transcript paragraph (≥ half the clip inside it), because a
  correction over part of a paragraph resolves `.partial` and leaves it unnamed.
- `575f3037` (not voice) archive sync reads its saved `state.json` in `init`: a pass at launch ran before
  `start()` loaded it, re-sent the preferences, re-marked every conversation for the transcript export,
  and saved that over the real state — every launch since 10-22. Test `aPassBeforeStartWorksFromTheSavedState`.
- `b2a557af` **voice prints: a new sample no longer restarts the history scan.** Every analysed
  turn keeps its print (`voice_turn_prints`, sealed half-precision vector; `voice_print_sources` holds the
  merged analysed ranges and the corpus revision its names were matched against; migration
  `voice-turn-prints-v1`; triggers drop them with the source's generation bump and recognition off).
  A corpus change no longer cancels jobs or resets history plans (`reconcileCorpus` is gone, jobs are
  valid across corpus revisions via `VoiceWorkToken.sameWork`). `renameFromPrints` runs first in every
  allowed slice: ≤ 2,000 prints, diffed so an unchanged name is never rewritten (no archive churn), a
  stopped run keeps its names, an undone one gives them up. A job over audio already analysed adopts it
  (`adoptAnalyzed`, no model time) and an explicit rerun no longer deletes names on analysed audio.
  `clearAutomatic` freezes prints (`frozenCorpus`) until a history run asks again. `SpeakerMatchRoster`
  prepares the roster once; a test checks it decides exactly as `SpeakerMatcher.match`. Names are always
  matched from the saved half-precision print, so a re-read decides as the first reading did.
  `pendingRecordings` counts recordings waiting to be re-matched. Recent run IDs drop the corpus revision.
- **Level research (2026-10-28, offline on the 10:05 backup; reports in the session scratchpad,
  `research/voice-id-level.md` and `research/transcript-level.md`).** Roger asked whether boosting the
  recording would help voice ID or transcripts.
  - *Voice ID: no.* The Cactus front end is log-mel then per-crop mean subtraction, so gain cancels
    exactly (re-embedded crops: cosine 0.99997 to the raw crop). The segmentation's second instance
    norm makes the detector level-invariant down to about −65 dBFS; DetectionGain measurably does
    nothing (keep it: removing it would bump the recipe and orphan every example). The low naming rate
    (68 named vs 1,327 unnamed on G17) is the 0.55 threshold: the wearer's own cross-recording score is
    median 0.43 (95% CI 0.385–0.452) and rises with examples (0.25 → 0.43 for 2 → 12). A lower
    threshold can't be checked yet: only 9 turns of two other labelled people.
  - *Local Parakeet: yes, small.* `2fc07485` levels every ≤ 45 s chunk with `VoiceNoteLevel` before the
    engine (−2.5 WER points, 60 better / 7 worse of 90 segments); `ParakeetQuietAudioBoost` and its Debug
    row are gone; `LocalEngineComparison` has a `PEBBLE_ENGINE_COMPARE_UNLEVELED` arm to confirm it on the
    real Core AI bundle (the research used the same weights in PyTorch).
  - *Soniox: unknown.* 1,248 of 1,256 transcripts since 10-01. Uploads are the watch's Speex frames
    (4% of WAV); a boosted upload means FLAC (15×) or AAC (3.1×, loses most of the gain), and a Speex
    re-encode is worse than none. A public-audio A/B (LibriSpeech through the simulated watch channel,
    18 uploads, about $0.32) is built in `research/soniox-ab/` with its decision rule; needs Roger's OK.
  - *Never at arrival:* re-encoding stored Speex with gain costs 3.7–4.1 points.
- (superseded) three directions for the question UI — A queue in People & voices, B one question on
  Today, C a hint inside the conversation with per-recording Yes/No — in
  `docs/redesign/voice-naming-mockups/who-is-this.html`, published at
  https://claude.ai/artifact/1b6rnKKQptb4HULsoUYLWc. Build only the chosen parts.

## Shared checkout warning (2026-10-26)

Session "Fix recording times drifting with the watch clock" (local_463214db…) shares this `main`
checkout. Its work is now committed as `940cc75a` (recordings placed by arrival; `SegmentMeta.
headReceivedAtMs`, `sampleClockAnchorMs` = birth + least arrival lag − 2 s, migrations
`moments-paused-clock-v1` and `follow-ups-wall-replace-v1` after ours) and firmware `f64b7d5ad` (built,
not flashed). **`940cc75a` was not approved for the phone until 18:05, when Roger asked that session to
deploy it.** Once its install lands, plain HEAD deploys are fine. Before that, deploy from a scratch worktree at `666b450a` with our
later commits cherry-picked (`git checkout --detach 666b450a && git cherry-pick …`), then
`IOS_DIR=<dir>/ios ./scripts/deploy-ios-rebuild.sh --device G17 --replace --skip-tests`. Once it ships,
`WatchVoiceSample.clockLagMs` reads ~2 s instead of minutes (watch windows sit on the corrected clock).
Stage by explicit path; never `git add -A`.

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

**On G17 since 2026-10-28 16:39:** `f292fc45` = `6edbfc14` + `89670a08` (ignored clips) + `0cb4ae1e`
(voice prints) + `f292fc45` (local level stage), built from `scratchpad/voice` because main's Focus
extension can't be signed (Xcode has no account). Ten-minute check: cost report PASS (on the
charger), no new crash reports, 20 windows per 10 background slices at 3.7–6.9 s busy. DB at 16:54:
33 prints in 26 KB (~790 B each), 108 print sources, recent jobs 246 done / 108 pending, history
1,645 pending, 75 names (68 before), corpus revision 15. Still to see: the next-morning cost report,
and — once Roger names a voice — the "recordings re-matched" lines and how fast the re-match reaches
every analysed recording.

**Soniox level A/B: done 2026-10-28 20:22, on the phone with its own key (`1b9cba28`).** All 18
core bodies transcribed (public LibriSpeech through the simulated watch channel). Pooled WER: A
(today's Ogg Speex) 8.00%, B (level stage, FLAC) 7.45%, C (FLAC, no stage) 7.70%. Level effect B
against C: 0.30 points (95% CI −0.04 to +0.68), at most 0.74 on the quietest noisy variant. Under
the 0.5-point bar fixed in advance: **Soniox is level-insensitive; build nothing for the cloud.**
A against C is +0.29 points (≈0.8 in the two noisy variants at −53/−47 dBFS): Soniox reads the Ogg
Speex frames slightly worse than the same audio decoded to FLAC, not worth 15× the upload bytes.
The hook (`AppComposition+SonioxLevelTest.swift`) runs only with `PEBBLE_SONIOX_LEVEL_TEST=1` at
launch; the 18 bodies (~130 MB) are still in the app container under
`diagnostics/soniox-level-test/`. Scored with `research/tools/soniox_ab_score.py`.

**Playback leveling (`d41f4f11`, Roger asked 10-28):** everything played is brought up to a
comfortable level, nothing stored changes. Segment playback (recordings, conversations, moments)
runs each decoded piece through `PlaybackLevel` (VoiceNoteLevel's high-pass, −22 dBFS target, 30 dB
cap, limiter; gain from the last 30 s, rising ≤3 dB/s, falling ≤12 dB/s). Who-is-this clips and
watch samples use `VoiceNoteLevel` on the whole clip. Phone-mic samples are played as recorded.

**Waiting on Roger:** labelling more people across recordings so a watch-domain threshold
can be calibrated.

**Verify `f69a8623` + `6edbfc14` on the phone** once G17 is back and main is installed:
- `./scripts/phone-cost-report.sh --minutes 11`, a systemCrashLogs diff, and the next-morning report;
- "voice recognition: 10 background slices, N windows, M ms busy" lines (pace is
  `max(3 s, 10 × busy)`, 30 s when idle) against link drops ("rebuilding the link",
  "watchUnreachable", "link disconnected") and the heartbeat's `cpu=+Ns`;
- no `VoiceIdentityError` in the log; `voice_jobs` with `recent:` run ids finishing ahead of the
  history plan; `voice_auto_attributions` growing;
- on the phone: Play Longer and Open Conversation on a real clip and on a conversation sample.
If the pace costs too much or links drop, raise `VoiceBackgroundPace.gapPerBusyMs`.

**Measured 2026-10-28 10:48 (6edbfc14 since 10:18):** cost report PASS (unplugged, ~0.64 CPU-s/min
backgrounded), no new crash reports, no link drops after the launch reconnect, no VoiceIdentityError.
Attributions 5 → 68. Overnight on the charger: ~10 slices per 40–80 s, 2.4–5.4 s busy per 10, about
1,000 audio-minutes checked between 00:00 and 06:00.
**Finding:** every new human label bumps `corpusRevision`, and `reconcileCorpus` deletes an unfinished
history run's jobs and attributions and restarts it from the first recording (revisions 6, 9, 12,
13, 15 on 10-27/28; the current all-recordings plan has 370 queued, 0 done). With ~3,000 15-minute
recordings and this pace, a history run needs many nights, so with regular labelling it never
finishes. Proposed: keep each turn's embedding once per (segment, recipe, source revision); a label
change then re-matches stored vectors, with no diarization or model work. Awaiting Roger.

Later from the plan: quality weighting of exemplars (needs labelled real watch audio to measure; the
public corpus is read speech through Speex), propagation feedback ("Found Dana in N places"),
per-person calibration.

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
2. (DONE `0458f7f1`) **Whole-speaker labelling.** The provider already groups a conversation into Speaker 1/2…:
   offer "All of Speaker 2 in this conversation" when one paragraph of a provider label is
   selected (one tap names every paragraph with that label in this conversation's pieces). Most
   real labelling is "this whole speaker is Dana".
3. (DONE `5962e12b`) **Profile capacity for many modes.** Replace the hard 32-example cap with pruning: keep the
   most diverse exemplars (farthest-point / drop the most redundant by cosine to its nearest
   sibling), never dropping the last exemplar of a recording session or microphone. Count
   distinct *sessions* (recordings) as independent evidence; crops from one session are not
   independent (already true for codec variants via confirmationID).
4. (DROPPED — see above) **Mislabel guard (inconsistent quality cuts both ways).** When a new labelled clip is far
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
