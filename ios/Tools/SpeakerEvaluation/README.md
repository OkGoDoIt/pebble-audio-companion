# Local voice model evaluation

These opt-in developer tools run the production `SpeakerRecognition` adapters on local files.
They do not install the app, change app settings, enroll real people, or upload audio/voiceprints.
Public model/dataset downloads are explicit. Put all downloaded audio/models and private outputs
outside the repository. The production analyzer defaults to off and requires installed models.

The app combines a pinned Cactus WeSpeaker embedding model with a pinned Core ML pyannote
community-1 segmentation conversion. Segmentation finds speech, local speaker slots and overlap
independently of ASR; embeddings compare bounded clean intervals across windows/recordings.
Anonymous slots are not people. Only explicitly confirmed examples train a person's profile.
Phone enrollment keeps a raw embedding and one watch-codec variant of each confirmed crop.
A variant is another rendering of the same evidence, never a second sample or confirmation.

## Exact models and runtime

- Embedding: [Cactus WeSpeaker](https://huggingface.co/Cactus-Compute/wespeaker-voxceleb-resnet34-LM/tree/f145212639b5cea874482e70002935daa987fe44), revision `f145212639b5cea874482e70002935daa987fe44`, published `wespeaker-voxceleb-resnet34-lm-int8.zip`, 12,336,866 bytes, SHA256 `cc6fc908455c77f08a4fa2d6090649b13e13c7f865ba01c3d6ff8d82e31b1c71`. Despite the filename, its internal configuration says **FP16**; published int4/int8 ZIPs at this revision are byte-identical. All 75 extracted files are pinned in `CactusSpeakerModel.swift`.
- Segmentation: [Fluid Inference's pyannote community-1 Core ML conversion](https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/7eab74f3463c736418d0eb10296261ae581146c9/Segmentation.mlmodelc), revision `7eab74f3463c736418d0eb10296261ae581146c9`, five files totaling 6,006,888 bytes. `CoreMLSegmentationModel.swift` pins every size/SHA256. The model metadata credits pyannote community-1 and Fluid Inference, CC-BY-4.0. It accepts `[1,1,160000]` Float32 audio and returns `[1,589,7]` log probabilities for silence, three single-speaker slots and three two-speaker combinations.
- Combined download: **18,343,754 bytes**. Installation verifies/stages the complete pair before publishing, uses the existing Wi-Fi-only downloader, excludes reproducible model files from iCloud backup, and caches successful verification for status reads. Native engines verify again when loading.
- Embedding recipe includes the exact device/simulator Cactus binary hashes, preprocessing and 256 dimensions. Its PCM input is mono16kHz, no transcription gain. Core ML uses Apple's existing runtime, CPU only, one ten-second window at a time. Neither model makes network requests during inference.

Cactus's segmentation conversion was evaluated and rejected: it missed the first six-second
speaker in a controlled sequence that the Core ML model detected. Its artifact is not shipped.
The public WeSpeaker ONNX and CAMPPlus alternatives were also tested; their different score
spaces require different thresholds, and neither improved the small public open-set benchmark.

## Reproduce model and native smoke

From the companion repository (Xcode and a booted arm64 iOS simulator required):

```sh
python3 ios/Tools/SpeakerEvaluation/download-models.py /tmp/pebble-speaker-evaluation
xcrun simctl list devices booted
curl -fL 'https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb/resolve/0f99f2d0ebe89ac095bcc5903c4dd8f72b367286/example1.wav' \
  -o /tmp/pebble-speaker-evaluation/public-speech.wav
ffmpeg -v error -y -i /tmp/pebble-speaker-evaluation/public-speech.wav -ac 1 -ar 16000 -f s16le \
  /tmp/pebble-speaker-evaluation/public-speech.pcm
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID smoke \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/public-speech.pcm
```

`run-native.sh` compiles the actual package source and existing privacy configuration, then
executes it in the simulator without installing an app. Models and PCM are read locally.
The 3.2608125-second public WAV SHA256 is `bf2dde5cb516939ff619d62fc07d4f4bec5b5d521aee3d07ae51828c9d93be0b`;
PCM SHA256 is `a381b00d9136048e4e97670b92686b0e68d0fc338b383cf552257d952cc59df3`.
On 2026-10-25, iPhone17/iOS27 simulator: 256 finite dimensions, normalized norm1.0000000012,
repeat cosine1.0; native calls534.37/507.20ms,1.067s total including model verification/load.
These are simulator measurements, not phone performance or battery results.

## Phone enrollment → watch codec: current operating point

The codec mismatch mattered in the actual service test: raw phone enrollment often abstained
on correctly labeled Speex speech. The production fix augments each confirmed phone crop with
one rendering through the **exact watch Speex encoder/decoder**. Encoding happens once over
the whole phone recording; each variant is cut at its original confirmed crop's sample range.
Watch passage enrollment is already decoded Speex and is not encoded again. The matcher takes
the better channel score **within each real crop**, then averages the best two distinct crops.
Two variants of one crop cannot satisfy the two-example minimum. Recipe compatibility, overlap
checks, unknown rejection and the 0.55 cosine/0.10 margin thresholds remain enforced.

The latest controlled comparison used three separate public enrollment chapters, each captured
as20s:20s/13.695s/12.02s natural speech followed by silence where needed. All three were accepted,
yielding16 real crops and16 optional codec variants. One earlier enrollment attempt was falsely
rejected as multiple clusters; the next substantial utterance was used, and that failure remains
in the report. Probe chapters are disjoint for every person. A preliminary long-utterance test
had chapter overlap and was **excluded** from recognition results (it remains a valid purity-only
regression). No matching threshold was lowered to make the comparison pass.

| Enrollment view → Speex probes | Known turns correctly named | Known turns unnamed | Wrong names | Unknown turns rejected | Known clips with a correct name |
|---|---:|---:|---:|---:|---:|
| Raw phone only | 0/36 | 36 | 0 | 25/25 | 0/18 |
| Codec view only | 20/36 | 16 | 0 | 25/25 | 13/18 |
| Raw + codec variants (production) | 20/36 | 16 | 0 | 25/25 | 13/18 |

There were18 known and12 unknown probe clips. One known and one unknown clip produced no
eligible two-second speech crop; they remain in the clip denominator. All12 unknown clips
stayed unnamed. This is a small English read-speech codec experiment, **not measured real
phone-to-watch microphone transfer**, and known-speaker abstention remains substantial.
The raw view preserves compatibility with raw recordings; it did not add recall in this
particular codec condition. The machine-readable report separates this result from earlier
same-condition embedding baselines below.

The actual `VoiceNativeEndToEndTests` service test also passed:20s continuous phone enrollment,
codec variants sealed in the database, an independently labeled held-out Speex recording named,
a new person's Speex recording left unnamed, manual correction precedence, and undo. The known
control's accepted score was0.6546; the unknown control's maximum was0.1621. Device energy and
unreviewed watch identity accuracy are separate, unmeasured claims.

Reproduce after preparing the public held-out corpus below. Dataset audio URLs can expire;
regenerate the metadata or retain the downloaded FLAC files if a later download returns403.

```sh
python3 ios/Tools/SpeakerEvaluation/prepare-channel-enrollment.py \
  /tmp/pebble-speaker-evaluation/public-heldout /tmp/pebble-speaker-evaluation/channel-enrollment
bash ios/Tools/SpeakerEvaluation/speex-roundtrip.sh \
  /tmp/pebble-speaker-evaluation/channel-enrollment /tmp/pebble-speaker-evaluation/channel-codec
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID analyze-corpus \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/Segmentation.mlmodelc \
  /tmp/pebble-speaker-evaluation/channel-enrollment/metadata.json \
  > /tmp/pebble-speaker-evaluation/channel-enrollment/analysis.json
python3 ios/Tools/SpeakerEvaluation/prepare-channel-variants.py \
  /tmp/pebble-speaker-evaluation/channel-enrollment /tmp/pebble-speaker-evaluation/channel-codec/speex \
  /tmp/pebble-speaker-evaluation/channel-variants
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID export-embeddings \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/channel-variants/manifest.json \
  > /tmp/pebble-speaker-evaluation/channel-variants/embeddings.json
bash ios/Tools/SpeakerEvaluation/speex-roundtrip.sh \
  /tmp/pebble-speaker-evaluation/public-heldout /tmp/pebble-speaker-evaluation/heldout-codec
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID analyze-corpus \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/Segmentation.mlmodelc \
  /tmp/pebble-speaker-evaluation/heldout-codec/speex/metadata.json \
  > /tmp/pebble-speaker-evaluation/heldout-codec/speex/analysis.json
python3 ios/Tools/SpeakerEvaluation/prepare-channel-evaluation.py \
  /tmp/pebble-speaker-evaluation/channel-variants \
  /tmp/pebble-speaker-evaluation/public-heldout/metadata.json \
  /tmp/pebble-speaker-evaluation/heldout-codec/speex/analysis.json \
  /tmp/pebble-speaker-evaluation/channel-results
bash ios/Tools/SpeakerEvaluation/evaluate-embeddings.sh /tmp/pebble-speaker-evaluation/channel-results/augmented.json
# raw.json and codec.json reproduce the two comparison rows with the same evidence counts.
```

## Public known/unknown evaluation

The [OpenSLR LibriSpeech test-clean corpus](https://www.openslr.org/12) supplies explicit speaker
and chapter labels via [the dataset metadata](https://huggingface.co/datasets/openslr/librispeech_asr).
`prepare-public-corpus.py` saves metadata responses and immutable decoded-audio hashes. It takes
up to eight seconds per utterance and rejects files shorter than two seconds. It never guesses
who spoke. Each known person has three enrollment utterances from one chapter; known probes
come from another chapter. Unknown probes belong to people absent from enrollment.

```sh
python3 ios/Tools/SpeakerEvaluation/prepare-public-corpus.py /tmp/pebble-speaker-evaluation/public-corpus
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID evaluate \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/public-corpus/manifest.json \
  > /tmp/pebble-speaker-evaluation/public-corpus/results.json
python3 ios/Tools/SpeakerEvaluation/summarize-scores.py \
  /tmp/pebble-speaker-evaluation/public-corpus/results.json \
  /tmp/pebble-speaker-evaluation/public-corpus/metadata.json 0.55 0.10
# New known utterances and three new unknown people; policy was frozen before downloading these.
python3 ios/Tools/SpeakerEvaluation/prepare-public-corpus.py /tmp/pebble-speaker-evaluation/public-heldout --held-out
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID evaluate \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/public-heldout/manifest.json \
  > /tmp/pebble-speaker-evaluation/public-heldout/results.json
```

The tuning manifest deliberately exports every best score with threshold−1/margin0; its raw
`incorrectlyNamed` counter is **not the application policy's result**. `summarize-scores.py`
applies the selected minimum cosine0.55/margin0.10/minimum two confirmed examples. The held-out
manifest uses that frozen policy directly, calibrationID `public-read-speech-cactus-f145212-v1`.
The baseline score is the mean of the two most similar confirmed examples per person. One incomplete
profile still competes as a runner-up; incompatible recipes never match.

Results on 2026-10-25 (machine-readable companion: `public-results-2026-10-25.json`):

| Condition | Known probes | Correct names | Known abstentions | Wrong names | Unknowns rejected |
|---|---:|---:|---:|---:|---:|
| Tuning, original public PCM | 15 | 14 | 1 | 0 | 16/16 |
| Held-out, new utterances/new unknown speakers | 18 | 18 | 0 | 0 | 12/12 |
| Tuning through exact app Speex encoder/decoder | 15 | 13 | 2 | 0 | 16/16 |
| Quiet input×0.05 then Speex | 14 eligible | 12 | 2 | 0 | 16/16 |
| Quiet Speex then gain×20 after decoding | 15 | 13 | 2 | 0 | 16/16 |

The quiet condition additionally rejects one known probe at the −60dBFS engineering floor
(measured−61.36dBFS), reported separately rather than silently counted as recognition success.
The codec uses the exact app fixed-point Speex, wideband16kHz, quality6, complexity1,9800bps.
Both enrollment and probes pass through the selected condition; these rows do **not** establish
phone-enrollment→watch-microphone accuracy. Gain restoration did not justify changing production
preprocessing. The fresh test has only three known and three unknown speakers. Zero observed
wrong names in this sample does not establish a population error rate or false-self guarantee.

```sh
bash ios/Tools/SpeakerEvaluation/speex-roundtrip.sh \
  /tmp/pebble-speaker-evaluation/public-corpus /tmp/pebble-speaker-evaluation/public-codec
# Each output condition has manifest.json. The quiet condition may need a separately recorded
# eligible manifest if the production quality gate rejects a file; never erase that rejection.
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID evaluate \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/public-codec/speex/manifest.json
```

The **raw-PCM baseline segmentation→subwindow embedding→Swift matcher** path was also run on
all39 held-out/enrollment clips using the same frozen policy **and the service's enrollment
purity/≥0.7 speech-confidence gates**. Eight of nine enrollment clips were accepted, producing18
examples. One known single-person enrollment clip was conservatively rejected because a0.4s
fragment received a spurious second cluster. The65 eligible probe turns produced34/38 correct
known names,4 known abstentions,0 wrong names, and27/27 unknown turns rejected. Seventeen of18
known probe clips received at least one correct name; one stayed unnamed. All12 unknown clips
stayed unnamed. No probe clip was omitted; two probe turns were too short for embedding.
Turns from the same utterance are correlated, so these are not65 independent identity trials.

```sh
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID analyze-corpus \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/Segmentation.mlmodelc \
  /tmp/pebble-speaker-evaluation/public-heldout/metadata.json \
  > /tmp/pebble-speaker-evaluation/public-heldout/analysis-results.json
python3 ios/Tools/SpeakerEvaluation/prepare-analysis-corpus.py \
  /tmp/pebble-speaker-evaluation/public-heldout/metadata.json \
  /tmp/pebble-speaker-evaluation/public-heldout/analysis-results.json \
  /tmp/pebble-speaker-evaluation/public-heldout/pipeline-corpus.json
bash ios/Tools/SpeakerEvaluation/evaluate-embeddings.sh \
  /tmp/pebble-speaker-evaluation/public-heldout/pipeline-corpus.json
```

`compare-onnx.py MODEL.onnx PUBLIC_DIR WATCH_DIR OUTPUT.json` requires Python `sherpa-onnx`
and NumPy; it loads official sherpa-onnx WeSpeaker/CAMPPlus artifacts locally. It uses the same
public labels and treats watch-provider labels strictly as unverified comparison metadata.

## Actual segmentation and overlap regression

```sh
python3 ios/Tools/SpeakerEvaluation/prepare-diarization-fixtures.py \
  /tmp/pebble-speaker-evaluation/public-corpus /tmp/pebble-speaker-evaluation/public-diarization
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID analyze-corpus \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/Segmentation.mlmodelc \
  /tmp/pebble-speaker-evaluation/public-diarization/manifest.json \
  > /tmp/pebble-speaker-evaluation/public-diarization/results.json
```

The fixtures construct A/B/C/A turns from labeled public sources, a balanced mixture and an
unbalanced mixture. Source-span labels include natural speech pauses: this is a targeted
regression, **not a measured diarization error rate**. The production analyzer:

- Detected the initial speaker and reunited the last A turn with the first A cluster.
- Detected balanced overlap2.27–7.23s against constructed mixture2–7s, returning no embedding
  for that span. Mixed/single boundaries are approximate and can include ~0.3s edge uncertainty.
- Missed much of the quieter speaker in the unbalanced mixture. Standard Core ML and Cactus
  both did so; overlap detection cannot guarantee purity or distinguish playback from people.
- Conservatively split similar voices into extra anonymous clusters. Speaker slots are window
  local, and their permutation is never treated as global identity. Even a single slot is split
  into disjoint2–3.34s observations for spans≥4s, compared independently. This bounds missed-change
  contamination and lets a four-second clean enrollment provide two distinct observations.

Measured final adapter times on the same simulator: sequential24.8s→3.353s, unbalanced9s→1.373s,
balanced9s→0.359s (the latter extracts only one eligible embedding). Core ML alone measured
~8–12ms per ten-second window on the Apple M5 Pro host CPU; embedding inference dominates. Model loading,
verification and concurrent host activity affect totals. No phone energy claim follows.

A service integration test exposed an early aggregation bug: taking the minimum frame
probability made one uncertain speech boundary reject an otherwise clean eight-second sample.
The analyzer now reports each emitted crop's duration-weighted mean speech probability. The
per-frame speech/overlap gates are unchanged; that public sample produces three consistent
embeddings with mean confidences0.9793/1.0000/0.9933. The benchmark above includes this fix.

A final short window with no eligible embedding is left unknown instead of being assigned a
new global speaker. That absence of evidence previously caused false multi-speaker enrollment
refusals after otherwise clean speech. A distinct short slot alongside embedded speech in the
same window still remains a separate local voice; detected overlap still blocks enrollment.

Continuous long public utterances were also tested through the enrollment eligibility gate:
20.0s/18.525s/20.0s from three known people each yielded exactly one cluster, no overlap, and
8/7/7 usable examples. Artificially concatenating independent same-person recordings instead
introduced extra clusters at edit boundaries; continuous recordings are the relevant setup test.

```sh
python3 ios/Tools/SpeakerEvaluation/prepare-guided-fixtures.py \
  /tmp/pebble-speaker-evaluation/public-heldout /tmp/pebble-speaker-evaluation/guided-public-continuous
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID analyze-corpus \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/Segmentation.mlmodelc \
  /tmp/pebble-speaker-evaluation/guided-public-continuous/manifest.json
```

The 2–30s embedding duration, −60dBFS RMS floor,1% clipping ceiling,0.55 single-class confidence,
0.35 overlap sum and clustering margin are engineering policies, not calibrated quality scores.
They can abstain on useful speech and miss faint interference. Automatic predictions never
become training labels; people confirm an audible passage before examples are saved.

## Private watch evaluation without invented truth

A read-only inspection of immutable backups on2026-10-25 found2,895 raw Speex logs and1,827
transcripts. Most used Soniox, with additional on-device Parakeet and SpeechAnalyzer examples.
The sole legacy person assignment was orphaned in the newest and five checked historical native
DBs; there was no surviving trustworthy person-to-media range. It cannot establish the wearer's
voice, so no private person label or false-self accuracy was invented.

Forty gap-free3–8s crops (212.56s total) were selected across ten chronologically stratified
multi-speaker Soniox segments. Both local models were executed; provider label agreement was
measured only as a consistency diagnostic. Same/different provider labels strongly overlapped
for Cactus, WeSpeaker ONNX and CAMPPlus, so those labels are unsuitable ground truth.
The final Core ML analyzer processed all40 clips with0 errors:90 turns,56 eligible embeddings,
eight clips with detected overlap and four with no detected speech;31.04s total simulator time.
No backup was modified and no private audio was uploaded. Private filenames, transcripts and
embeddings are excluded from the committed summary. Watch identity accuracy remains unmeasured.

To evaluate authorized local backup crops, create a JSON array of
`{ "id": "local-crop", "segmentID": "existing-segment-id", "startSample": 16000, "endSample": 96000 }`:

```sh
bash ios/Tools/SpeakerEvaluation/decode-watch.sh BACKUP_ROOT REQUESTS.json OUTPUT_DIR
```

The decoder uses the exact app Speex decoder, reconstructs raw-log order, carries codec state
from the start, preserves sample coordinates and rejects gaps/truncation. It never joins across
loss or writes into the input backup. Create an analyze manifest from successful outputs with
`id`, `pcmPath`, `sourceID`, `sourceRevision`, `sessionID`, `sourceStartSample`; each crop must be
0.1–30s mono16kHz PCM16LE. Analyze output includes absolute source coordinates and provenance
must stay attached when storing any result.

For a formally labeled corpus, use `evaluate` with a JSON `policy`, optional `selfPersonID`, and
`samples` containing `id`, `pcmPath`, `partition` (`enrollment`/`probe`), `personID`,
`confirmationID`, `condition`, and `evidence`. Evidence contains sourceID/revision/sessionID,
startSample/endSample and speechOnly/singleSpeaker/containsDiscontinuity. Set personID null only
for a reviewed unenrolled person, never for an unlabeled clip. Distinct sessions for enrollment
and probes are enforced; honest provenance and review remain essential. For precomputed vectors,
`evaluate-embeddings.sh INPUT.json` accepts `{policy,corpus:{enrollment,probes,selfPersonID}}`.

## Focused verification

```sh
PEBBLE_SPEAKER_MODEL_FIXTURES=/tmp/pebble-speaker-evaluation \
  swift test --package-path ios/PebbleAudioKit \
  --filter 'SpeakerRecognitionTests|SpeakerMatchingTests|SpeakerDiarizerTests|SpeakerModelStoreTests'
```

The optional fixture test installs/uninstalls the actual pinned public artifacts through the
production store using a local-file transport; corruption is tested without network. Pure tests
cover disabled/cancelled work, malformed outputs, PCM gates, recipe compatibility, open-set
abstention, source coordinates, local-slot permutations and missed changes within one model slot.
