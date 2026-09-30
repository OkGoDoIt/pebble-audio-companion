# Audio with no conversation in it — classification

Status (2026-09-30, `AudioContentMethod.version = 3`): **method 1 shipped** (conversation / no
conversation from the transcript, per minute, plus the stray-remark rule of version 2).
**Method 2 shipped** (an AI reading of the words: lyrics, TV and announcements become "no
conversation" at 0.9 or more; only lyrics are named, "music"). Measured in two rounds, the
second blind (§7). Version 2 is on Roger's phone; version 3 is built but not yet installed
(§7.6).

The product rule this serves (Roger): a descriptor such as "music" or "TV or video" is shown only
when it can be determined accurately; otherwise the stretch is "No conversation", styled like
quiet. A false claim is worse than no claim. Nothing is ever deleted or hidden: the audio stays
playable, the transcript readable, and a person can overrule any verdict.

## 1. What exists and where it runs

| Piece | File |
|---|---|
| Method 1 (pure), and applying method 2's answers | `PebbleAudioKit/Sources/Transcription/AudioContentClassifier.swift` |
| Method 2 prompt and parsing | `PebbleAudioKit/Sources/Intelligence/AudioContentJudge.swift` (table `audio_content_judgements`) |
| On-phone measurement channel | `PebbleAudioKit/Sources/CompanionRuntime/Services/AnalysisJobRunner.swift` |
| Store, History contract, corrections | `PebbleAudioKit/Sources/AppDB/AudioContentStore.swift` (migration `v14-audio-content`) |
| Stage, masks, backfill, cascade | `PebbleAudioKit/Sources/CompanionRuntime/Services/AudioContentService.swift` |
| Model-input view | `SegmentTranscript.withStretchesWithheld` in `Intelligence/TranscriptCleanup.swift` |
| Media → wall ranges | `SegmentMediaClock.wallRanges(fromMedia:)` |
| Measurement harness | `Tests/TranscriptionTests/NonConversationMeasurement.swift` |

Pipeline: new stage `.classifyAudio`, after `.retention` and before `.regroup`, so the boundary
evidence and every AI stage in the same pass read verdicts about the transcripts they are about
to use. It is not `heavy` (no model): a segment is one pass over its turn timings, milliseconds of
CPU. It runs for a segment only when its transcription state, closedness or transcript file
changed, or the method version moved; in steady state a pass compares an in-memory dictionary and
reads nothing (tested). The backfill of an existing library is 40 segments per pass, newest
first, and like every stage it only runs when the pass runs (foreground, or backgrounded on a
cool charger). Over both backups (2,289 segments, 1,752 classifiable) reading and classifying
took **1.8 s** on the Mac (`shippedClassifierOverLibrary`); the phone backfill is that spread
over ~45 passes.

What it produced on that library: **197 h conversation; 109 h no conversation** (86 h by word
rate, 22 h NoSpeech segments, 1.9 h loops); 169 "few words" spans; **37 segments contain a loop
span**, which is the one place method 1 changes existing behaviour — those loops stop counting as
speech for conversation boundaries, so a conversation that a looped quiet stretch used to hold
open can now end there.

## 2. The data and the labels

Two backups (`audio-companion-20260918-121203`, `…-20260930-011408`): 1,616 segments with audio
and a transcript or a NoSpeech verdict, **306 hours**, cut into **18,651 one-minute windows**.
Transcripts: 1,311 Soniox (turn timings, speakers, per-turn confidence), 61 local (turn timings
and text only — **the local engines give no speakers and no confidence**, so nothing shipped may
depend on those).

**Labels.** Roger asked me to label rather than listen, so the labels are mine: 320 one-minute
windows read with two minutes of transcript either side and the minute's loudness shape (level
percentiles, share of "dips", bucket-to-bucket flux), with Apple's sound classifier HIDDEN while
labelling so it could be graded against labels it did not inform. Classes: **C** conversation
(includes dictation, calls, talking to a child — anything worth a summary), **L** a lull of a
minute or two inside a conversation, **B** a brief real exchange, **N** no conversation (with
what: music, tv, pa (announcements), media (a live show), loop (transcriber stutter), fewWords,
quiet, sound), **U** can't tell. Result: 176 C, 30 L, 5 B, 101 N, 8 U.

Sampling was stratified (no-words-but-sound, few words, classifier-says-music, odd text,
classifier-says-scene, ordinary talk, quiet), each stratum's size recorded so precision can be
**re-weighted to the library's real mix**; 40% of each stratum was held back until the rules
were fixed. Labels, windows and all derived data live outside the repo
(`~/Desktop/PebbleAudioAnalysis/nonconversation/`).

**The honest limit of these labels.** They come from reading, so rules that also read text are
graded against a reader — that flatters them. Wordless windows could only be labelled "sound" or
"quiet"; what the sound WAS (music without vocals, a fan, a café) is not knowable from a
transcript, which is exactly why no such descriptor ships.

Estimated composition (weighted): about 34% of recorded time has no words at all (quiet 18%,
sound 16%); of transcribed words, roughly TV 2.3%, transcriber loops 2.1%, announcements 1.9%,
lyrics 0.9%, unclear 1.4% — **about 8% of all transcribed words are not conversation**. The
TV/announcement shares rest on 2–3 labelled windows each and are very uncertain.

## 3. Signals, measured

Positive class = no conversation. "Talk" false positives are C/B windows (real content hidden);
"lull" false positives are pauses inside a conversation (at most two words hidden).

| Signal | Held-back precision (raw / weighted) | Recall (raw / weighted) | Notes |
|---|---|---|---|
| No words in the minute | 0.93 / 0.98 | 0.72 / 0.91 | all misses lulls |
| **Under 2 words a minute** | **0.83 / 0.96** | **0.74 / 0.92** | **0 talk misses; hides ≤2 words a minute by construction** |
| Under 5 words a minute | 0.70 / 0.93 | 0.77 / 0.92 | 3 talk misses |
| Under 10 words a minute | 0.64 / 0.91 | 0.82 / 0.93 | 4 talk misses (dictated one-liners, a mic test) |
| Transcriber loop | 1.0 on 3 | — | the display-side artefact rule is conservative |
| Apple SoundAnalysis "music" ≥ 50%, "speech" < 20% | 0.71 (5 of 7) | 0.13 | fires on conversations with music behind them |
| Two or more words a minute ⇒ conversation | 0.86 / 0.90 | — | the rest is TV, lyrics, announcements, loops |

**Apple's sound classifier** (`SNClassifySoundRequest`, built-in `version1`, 303 classes, 3 s
windows, run on the Mac over every minute; decoded audio is 16 kHz mono PCM16 from Speex at
9.8 kbps). Findings:
- There is **no television or radio class**. TV can only be inferred.
- On the wordless "sound" windows it reports essentially nothing: mean music, crowd, fan, traffic
  scores 0.00–0.01. The wrist microphone through a 9.8 kbps speech codec does not give it enough
  to name a café or a fan, so **no scene descriptor (café, street, fan) is possible from it.**
- Music WITH vocals it does see: of the 13 lyric windows, music ≥ 30% caught 12. But at the
  same setting 6 of 21 flagged windows were conversations with music playing. Music is a
  presence detector, not a "no conversation" detector.
- Cost on the Mac: 0.3 s to decode and 0.9 s to classify 15 minutes (≈1,000× real time,
  ≈5 s per audio-hour). Not deployed; see §6.

**Smoothing** (absorbing short no-conversation runs next to conversation, 1–5 minutes, one- or
both-sided) was measured and **rejected**: at 3 minutes it kept precision flat (0.83) and cut
recall from 0.79 to 0.40, because a no-conversation minute's "conversation" neighbours are often
lyrics or TV themselves. Lulls are harmless as they are: they hold at most two words, and the
History drawing rule already absorbs short gaps.

**Loops.** Two extra rules catch the loops the display-side rule (`TranscriptArtefacts`, tuned
never to hide a real line) passes: a minute over **320 words** (faster than anyone speaks; all 51
such minutes repeat ≥ 77% of their word trigrams) **and** ≥ 60% repeated trigrams; or ≥ 20 words
with **≥ 85% repeated trigrams** at any speed (26 minutes, every one read is a loop; the most
repetitive real conversation found is 0.80). Slower, less literal loops (0.82) are left to
method 2.

**Soniox audio events.** The provider decodes `is_audio_event` and drops those tokens, but
Soniox's current documentation does not describe audio-event tokens for speech-to-text at all,
and nothing stored shows one ever arrived. Soniox does document per-token language labels
(`enable_language_identification`). Real conversations can be in other languages, so
language is not a media signal on its own. The account is empty; a probe (≈20 labelled clips,
raw responses kept outside the repo) waits on a top-up.

**Per-turn confidence** (Soniox only): median 0.76 on windows under 30 words vs 0.82 over 300 —
some signal, but local transcripts do not have it, so it cannot carry a shipped rule.

## 4. Method 1 (shipped, `AudioContentMethod.version = 1`)

Per minute of stored audio (a trailing piece under 30 s joins the minute before), words spread
evenly over each turn's own time:

1. Loop: the minute's words are mostly the transcriber's echoes, or the two rules above → **no
   conversation**, `decidedBy: loop`, no descriptor.
2. **2 or more words a minute → conversation**, `decidedBy: wordRate`, confidence 0.90.
3. Otherwise **no conversation**, `decidedBy: wordRate`, confidence 0.96, descriptor
   **`fewWords`** when any word was said. "A few words" is a fact about the transcript, not a
   guess about the room, so it meets the accuracy bar by construction.
4. A `NoSpeech` segment is one no-conversation span, `decidedBy: noSpeech`, confidence 0.95
   (such verdicts have been wrong before when an engine failed; they are attributed and
   re-queued now, but not treated as certain).
5. Pending, running, failed, disabled, open, or `Complete` with no file → **unclassified** (no
   span). Unclassified is distinct from both kinds, so the UI can render it honestly.

Adjacent equal verdicts merge. Placement on the wall clock goes through the segment's own gap
records (`SegmentMediaClock.wallRanges(fromMedia:)`): a minute that straddles a quiet or lost gap
is two spans with the gap left out. Where the records do not add up (`isExact == false`), spans
sit at their stored-audio offsets and are not stretched across unexplained wall time; the rest
of such a segment stays unclassified (the same refusal the boundary detector makes).

Shipped classifier scored by the harness against the labels
(`NonConversationMeasurement.scoreShippedClassifierAgainstLabels`):

```
test (held back): tp=29 fp=6 (talk 0, lull 6) fn=10  prec=0.829 rec=0.744 | weighted prec=0.959 rec=0.917
all:              tp=68 fp=14 (talk 1, lull 13) fn=33 prec=0.829 rec=0.673 | weighted prec=0.954 rec=0.892
```

What it cannot do: every lyric, TV, announcement and slow-loop minute (33 labelled) is still
"conversation". That is today's behaviour everywhere in the app, not a new error, and it is what
method 2 is for.

### Version 2: stray remarks

Roger pointed at three titled "conversations" that were nothing of the kind: an empty
"Conversation", "Brief Mention of Weather" (five words after a long quiet stretch) and "Unclear
Conversation About a Lamp" (fragments). A stretch of talk (conversation minutes joined across
pauses of up to 2 minutes) with **fewer than 13 words in total**, and nothing said within 2
minutes either side — counting the neighbouring recordings, whose ids, states and transcript
versions go into the input key so a neighbour settling reclassifies this one — is
`decidedBy: isolatedWords`, `fewWords`, confidence 0.9. An edge whose neighbour is not settled
yet is not judged. Across the library it relabels 30 of 18,651 minutes; every one sampled was a
remark, a mic test or an announcement, and no hand-labelled minute changes. The rate floor also
became "never less than a minute", so a 12-second recording with five words in it is five words
a minute, not twenty-five.

A conversation whose every member holds no conversation is not the AI's to title: it gets a
plain stand-in annotation, "No conversation" (`providerId: audioContent`, no tags), with a
summary that names what was heard only when every worded stretch agrees ("Music was playing,
but no conversation was heard."; "A few words were heard, but no conversation."; otherwise "Sound
was recorded, but it holds no conversation."). It is left out of titling and follow-ups, and
withdrawn the moment the conversation turns out to hold talk.

"A Lamp" is the case nothing catches: 60+ words a minute of fragments that read like garbled
real speech. Whether a stretch is garbled talk or distant chatter cannot be read from the words
(§7.3), so it stays a conversation until a person says otherwise.

## 5. The contract History reads

`AudioContentStore` conforms to the History plan's `AudioContentSource` (§7.6):
`spans(overlappingMs:)` → effective, non-overlapping, time-ordered spans clipped to the window
(corrections applied, spans that say the same thing across a segment seam merged);
`digest(overlappingMs:)` → changes when any span or correction in the window changes, and does
NOT change when a segment is rewritten with the same verdicts (tested: an observer must not
republish nothing). Each span: `startMs`, `endMs` (wall), `kind`, `descriptor?`, `confidence`
(the measured precision of the rule, 1 for a person), `decidedBy`, `version` (the method version
— change detection is `digest`), and `wordCount` (added: lets the UI say how much was said).

Descriptors shipped: **`fewWords`** (a fact about the transcript) and **`music`** (an AI reading
called the minute lyrics at 0.9 or more; §7). No `tvOrVideo`, announcement or scene descriptor
meets the bar: those stretches are plain "no conversation".

**Corrections.** `AudioContentService.correct(startMs:endMs:kind:)` records a person's
"this was a conversation" (or was not) by wall-clock range, in an authoritative table that no
rebuild drops. The later correction wins; a correction relabels only classified time (never a
gap or audio still being transcribed); `undoCorrection` reverses it. A delete takes a correction
with it only when it lay wholly inside the deleted audio. The UI for this is the History /
conversation screens' to build.

## 6. What else respects the classification (and what deliberately does not)

- **Model input** (titles, summaries, tags, follow-ups, boundary review, daily recap): stretches
  a content judgement or a person marks as no conversation are withheld from what the models
  read, with a note in their place (`withStretchesWithheld`). The word-rate verdicts withhold
  nothing (there is nothing to withhold) and loops are already collapsed for models. The AI
  workers' memo key includes the mask generation, so a new verdict re-runs what was built from
  that text and nothing else. **Known gap:** a conversation whose annotation is already FINAL
  with tags is never regenerated (`EnrichmentWorker`), and an AI title cannot be told from a
  person's rename, so a correction or a new judgement does not retitle an old conversation. The
  one exception is a conversation left with no conversation at all: it gets the stand-in
  (§4, version 2). Reopening the rest needs the annotation to record who wrote the title.
- **Conversation boundaries:** turns inside loop spans, judged spans and person-marked
  no-conversation spans are not speech evidence (they used to keep a conversation open straight through a looped
  quiet stretch). Stray words are real speech and stay evidence.
- **Search and Spotlight: unchanged, deliberately.** Lyrics and TV dialogue stay searchable. A
  person may search for a line they heard, the label can be wrong, and "never hidden" includes
  "never unfindable". The screen a result opens is where the label is shown.
- **Ask:** unchanged. It reads the whole in-scope archive through the search index, which keeps
  the full text. Labelling judged stretches as background media in the Ask context (not
  dropping them) is the natural next step, not built.
- **Coverage (`CoverageKind`): unchanged, deliberately.** Coverage says whether audio was
  recorded; this says what it held. Folding one into the other would shrink "recorded" hours and
  misstate the recorder's reliability. History overlays the two.
- **Delete cascade and retention:** a segment's spans go with it.

## 7. Method 2 (shipped): what the words are

The only signal that separates TV dialogue, announcements and lyrics from conversation is what
is said. `AudioContentJudge` asks the person's configured AI (cloud first, `gpt-5.6-luna`,
through `AiModeRouter`) to read one segment at a time, lines grouped by minute of stored audio,
and say for every minute what it mostly is: conversation, music, tvOrVideo, announcement,
performance, loop, gibberish, fewWords or unclear, with a confidence. The answer is stored raw
(`audio_content_judgements`), keyed by prompt version and transcript version, and the pure
classifier applies it: a minute method 1 called conversation becomes no conversation when the
reading says **music, tvOrVideo or announcement at 0.9 or more** (`decidedBy: contentJudge`,
confidence 0.95). The reading can take talk away, never add it. Only lyrics are named.

### 7.1 Measuring without the keys leaving the phone

The keys live in the phone's Keychain and were not copied anywhere. The app gained a developer
channel, `AnalysisJobRunner`: a JSON job dropped into the app container over `devicectl`
(`analysis/inbox/`) is run with the app's own provider configuration, OpenAI's host only, at most
six requests at once, charger-gated when asked, and the raw replies are written to
`analysis/outbox/` for the Mac to pull. Every measurement below ran that way. Transcript text
and, for the listening model, short clips went to OpenAI; nothing else left the phone.

### 7.2 Round 1: 250 labelled minutes

The §2 labels, minutes with words. Three prompts: per-minute with Luna and with Terra, and the
shipped per-segment prompt with Luna. Per-segment calls read the minutes around each one, which
is what the per-minute prompts lacked.

| Judged (per segment, Luna) | n | What the labels say |
|---|---|---|
| music | 12 | 12 lyrics |
| loop | 3 | 3 loops |
| announcement | 4 | 3 announcements, 1 lull |
| tvOrVideo | 2 | 2 TV |
| fewWords | 32 | 17 lulls, 9 few words, 5 conversations, 1 fragment |
| gibberish | 3 | 2 few words, 1 conversation |
| conversation | 192 | 166 conversations; 2 TV, 1 lyric, 1 loop and 14 few-word or fragment minutes among the rest |

So music, TV, announcements and loops were right every time they were said (22/22), but TV was
also missed (2 of 4 TV minutes read as conversation), and "fewWords" and "gibberish" land on
real talk. Only the first four were candidates for acting.

**A listening model** (`gpt-audio-1.5`, the 320 minute clips) was run as an independent check
on labels made by reading. It agreed on lyrics (12 minutes it called music, all of them no
conversation, 10 labelled lyrics) and announcements, but it is not a detector for this audio: it
called 6 real conversations "TV or video" (16 TV calls in all, 3 of them TV) and 6 more "quiet"
(the wrist often hears the other side of a conversation faintly). It cannot vouch for a TV label.

**Gibberish ("A Lamp").** An early per-minute prompt quoted Roger's example in its text, so its
gibberish results were contaminated and are discarded. The per-segment prompt, which has no
examples, called the "Lamp" minutes conversation (0.76) and once called garbled real dictation
gibberish. Garbled talk and distant chatter read the same; nothing ships for it.

### 7.3 Round 2: 142 minutes it would act on, labelled blind

Round 1 had too few examples of each kind to clear the bar. The per-segment judge was run over
the library on the phone (1,340 segments, 1,324 answered, 2.6 M tokens in, 0.26 M out). While
it was still running, from the minutes it had by then marked for action (≥ 0.8, method 1 said
conversation, not in round 1: 95 music, 94 TV, 47 loop, 12 announcement), a sample was drawn per
kind (up to 60 music, 40 TV, 30 loop, all 12 announcements). I labelled them from
reading sheets with two minutes of context either side, **with the judge's verdict hidden**.
The sheets did not show the kind, but I knew every minute was one the judge would act on, which
biases towards agreeing; the unclear label was used freely to counter that.

| Judged | n | No conversation | Unclear | Real talk | Named right |
|---|---|---|---|---|---|
| music | 60 | 58 | 2 | 0 | 58 (96.7%) |
| tvOrVideo | 40 | 36 | 2 | 2 | 35 (87.5%) |
| announcement | 12 | 12 | 0 | 0 | 11 |
| loop | 30 | 22 | 4 | 4 | 19 |

- **Loops are not the reading's to call.** The 4 real-talk misses were people talking (a card
  game, two people talking quietly in another room, a conversation about recipes) whose transcript
  looped in places. Method 1's loop rules already catch the real loops at their measured
  precision, so the reading's "loop" is not acted on.
- **Confidence separates the rest.** Every talk minute among music, TV and announcements was
  under 0.85 (both were TV verdicts at 0.80 and 0.82: someone demonstrating an app while a TV
  line repeated). At **0.9**, music was 57/57, TV 28/29 and announcements 11/11 no
  conversation (96/97; 98.6% weighted to the counts at sampling time, 99.3% to the finished
  library's), the one other unclear. The threshold was chosen on this round, so the stored
  confidence is 0.95.
- **Music clears the naming bar; nothing else does.** Lyrics were named right 58/60 at 0.8 and
  57/57 at 0.9: at least 30 examples at 95% or better. TV was named right 87.5% (93% at 0.9),
  below the bar; announcements have only 12 examples. Both are plain "no conversation".

What it moves: of the 11,955 minutes method 1 calls conversation in the finished library run
(11,703 of them answered), the shipped rule takes **363 (3%, about 6 hours)**: 169 lyrics, 120
announcements, 74 TV. The loop verdicts it no longer acts on would have taken 103 more. The
announcement figure rests on 11 checked minutes standing for 120, most from segments answered
after the sample was drawn (a quiet day); that is the thinnest number here.

### 7.4 How it runs

- Stage `.judgeAudio`, after `.regroup`, `heavy`, only when the AI stages are due
  (`aiStagesDue`); 3 segments a pass; the last 24 hours first, the backlog only on the charger.
- One call per transcribed segment (a 15-minute segment is about 2,000 tokens in, 200 out).
  Minute text is capped at 2,500 characters so a looping minute cannot swamp a call.
- A failed call backs off and is tried at most 4 times; no AI configured means nothing is owed.
- A new transcript version or prompt version asks again; a classifier version bump (like v3)
  re-applies stored answers without asking again.

### 7.5 What a judged stretch changes

Everything in §6 that respects "no conversation" respects it: withheld from titles, follow-ups,
recap and boundary review with a note in its place ("about N minutes of background audio with no
conversation in it (such as TV or music) left out"), not speech evidence for boundaries, still
searchable, still playable, still overrulable.

### 7.6 On the phone

Version 2 with the judge stage (main@236f975) went on the phone at 15:36 on 2026-09-30.
**Version 3 is built but not installed**: the phone was unplugged during the install (CoreDevice
4016). Until it is, the phone's judge stage acts on "loop" at 0.8, the rule round 2 rejected;
its stored answers are re-applied by version 3 without asking again, but an AI title written
in between from a masked transcript stays (§6's known gap).

At 15:52 the phone had reclassified 78 of 666 classified segments under version 2 (7
stray-remark spans), written no stand-ins and made no judgements: the pass was behind a
transcription backlog, and the watch link was dropping. The measurement jobs ran through the
analysis channel meanwhile. Still to check on the phone: that the "Weather" and empty
"Conversation" conversations now read "No conversation", that judgements land and cost what
§7.4 says, and the battery gate (`phone-cost-report.sh`), which has not been run for either
build.

## 8. Rejected

- Any gate that skips transcription or discards audio on a guess (history: a loudness gate lost
  17% of real words; wrong NoSpeech verdicts hid whole conversations).
- Smoothing / absorbing short no-conversation runs (§3).
- Loudness as a conversation detector: real conversations sit below −60 dBFS on the wrist at
  times (a quiet breakfast at a median −69 dBFS, 168 words a minute).
- SoundAnalysis scene descriptors (café, street, fan): it sees nothing on this audio.
- Language as a media signal: real conversations can be in other languages.
- Per-turn confidence as a rule: local transcripts do not have it.
- A `noConversation` coverage kind (§6).
