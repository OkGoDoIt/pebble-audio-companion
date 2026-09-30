# Audio with no conversation in it — classification

Status (2026-09-30): **method 1 shipped** (conversation / no conversation from the transcript,
per minute). **Method 2 (music, TV, announcements, from a model reading the words) is designed
and waiting on measurement** — it needs an OpenAI key on the Mac to be scored before it ships.

The product rule this serves (Roger): a descriptor such as "music" or "TV or video" is shown only
when it can be determined accurately; otherwise the stretch is "No conversation", styled like
quiet. A false claim is worse than no claim. Nothing is ever deleted or hidden: the audio stays
playable, the transcript readable, and a person can overrule any verdict.

## 1. What exists and where it runs

| Piece | File |
|---|---|
| Method 1 (pure) | `PebbleAudioKit/Sources/Transcription/AudioContentClassifier.swift` |
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

## 5. The contract History reads

`AudioContentStore` conforms to the History plan's `AudioContentSource` (§7.6):
`spans(overlappingMs:)` → effective, non-overlapping, time-ordered spans clipped to the window
(corrections applied, spans that say the same thing across a segment seam merged);
`digest(overlappingMs:)` → changes when any span or correction in the window changes, and does
NOT change when a segment is rewritten with the same verdicts (tested: an observer must not
republish nothing). Each span: `startMs`, `endMs` (wall), `kind`, `descriptor?`, `confidence`
(the measured precision of the rule, 1 for a person), `decidedBy`, `version` (the method version
— change detection is `digest`), and `wordCount` (added: lets the UI say how much was said).

Descriptors shipped: **`fewWords` only.** No `music`, `tvOrVideo` or scene descriptor meets the
bar (§6).

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
  with tags is never regenerated (`EnrichmentWorker`), so a correction does not yet retitle an
  old conversation; that needs an annotation reopen and lands with method 2.
- **Conversation boundaries:** turns inside loop spans and person-marked no-conversation spans
  are not speech evidence (they used to keep a conversation open straight through a looped
  quiet stretch). Stray words are real speech and stay evidence.
- **Search and Spotlight: unchanged, deliberately.** Lyrics and TV dialogue stay searchable. A
  person may search for a line they heard, the label can be wrong, and "never hidden" includes
  "never unfindable". The screen a result opens is where the label is shown.
- **Ask:** unchanged in method 1 (nothing substantive is withheld). With method 2, excerpts from
  media stretches should be labelled as background media in the Ask context, not dropped.
- **Coverage (`CoverageKind`): unchanged, deliberately.** Coverage says whether audio was
  recorded; this says what it held. Folding one into the other would shrink "recorded" hours and
  misstate the recorder's reliability. History overlays the two.
- **Delete cascade and retention:** a segment's spans go with it.

## 7. Method 2 (designed, not shipped): what the words are

The only signal that separates TV dialogue, announcements and lyrics from conversation is what
is said. Plan, to be measured before anything ships:

1. **Candidates:** every conversation minute (method 1 cannot narrow further for TV). One call
   per segment, lines numbered by minute, with Apple's per-minute music score as a hint
   ("music was heard in 80% of this minute"). Output per minute range: `conversation`,
   `media: music | tvOrVideo | announcement | other`, `unclear`.
2. **Provider:** the person's configured AI (cloud first: `gpt-5.6-luna`), through
   `AiModeRouter`, with the on-device model (small context: 5-minute chunks) as the local path.
3. **Measurement first:** run it over the 320 labelled windows (and a second, targeted round of
   ~150 lyric/TV/announcement-heavy windows so each descriptor has 30+ held-back examples),
   report precision per class. To avoid grading the model against labels made the same way,
   the descriptor labels for wordless or ambiguous minutes use an independent audio judgement
   (an audio-capable OpenAI model listening to the clip) — **which sends audio to OpenAI and
   needs Roger's explicit yes first.**
4. **Bar:** a descriptor ships only at **≥ 95% precision on held-back windows with ≥ 30
   held-back examples** of it (with no errors in 30 the error rate could still be ~10%, so 30 is
   the floor, not a target). Calling a stretch "no conversation" from a content judgement needs
   the same 95%. Below the bar the verdict is plain "no conversation"; below 95% for the kind
   itself, method 2 does not ship.
5. **Cost:** roughly one Luna call per transcribed segment (~3k tokens in); gated like the AI
   stages (`heavy`, `aiStagesDue`, charger-only backfill, capped per pass).
6. **SoundAnalysis on the phone** only if the measured music descriptor needs it: candidate
   minutes only, ~5 s CPU per audio-hour measured on the Mac, to be re-measured on the phone with
   `phone-cost-report.sh` before it stays.

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
