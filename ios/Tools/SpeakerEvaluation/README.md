# Local speaker embedding evaluation

This is an opt-in developer harness for the `SpeakerRecognition` package module. It uses the
existing Cactus binary and privacy configuration, with no app installation, background worker,
network inference, settings change, or private audio upload. The provider defaults to off.
Its source is compiled directly for the simulator so this tool exercises the real adapter,
including model hash verification, PCM validation, JSON decoding and normalization.

The current implementation extracts embeddings from **already isolated speech crops**. It does
not find speaker turns, identify overlap, populate the app's people database, or enable automatic
recognition. The caller must provide evidence that a crop contains one speaker without gaps.
Energy/clipping checks cannot establish that evidence. The 2–30 second duration, −60 dBFS floor
and 1% clipping ceiling are initial engineering gates; they are not calibrated quality scores.

## Reproduce native inference

Run from the companion repository. These downloads are public model/sample files only. Keep
all artifacts outside the repository; the app does not download a speaker model automatically.

```sh
mkdir -p /tmp/pebble-speaker-evaluation/model
curl -fL 'https://huggingface.co/Cactus-Compute/wespeaker-voxceleb-resnet34-LM/resolve/f145212639b5cea874482e70002935daa987fe44/weights/wespeaker-voxceleb-resnet34-lm-int8.zip' \
  -o /tmp/pebble-speaker-evaluation/wespeaker.zip
shasum -a 256 /tmp/pebble-speaker-evaluation/wespeaker.zip
unzip -n /tmp/pebble-speaker-evaluation/wespeaker.zip -d /tmp/pebble-speaker-evaluation/model
curl -fL 'https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb/resolve/0f99f2d0ebe89ac095bcc5903c4dd8f72b367286/example1.wav' \
  -o /tmp/pebble-speaker-evaluation/public-speech.wav
python3 - <<'PY'
import wave
with wave.open('/tmp/pebble-speaker-evaluation/public-speech.wav') as wav:
    assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 16000)
    with open('/tmp/pebble-speaker-evaluation/public-speech.pcm', 'wb') as out:
        out.write(wav.readframes(wav.getnframes()))
PY
xcrun simctl list devices booted
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID smoke \
  /tmp/pebble-speaker-evaluation/model /tmp/pebble-speaker-evaluation/public-speech.pcm
```

Expected archive SHA256: `cc6fc908455c77f08a4fa2d6090649b13e13c7f865ba01c3d6ff8d82e31b1c71`.
Expected WAV SHA256: `bf2dde5cb516939ff619d62fc07d4f4bec5b5d521aee3d07ae51828c9d93be0b`.
Expected PCM SHA256: `a381b00d9136048e4e97670b92686b0e68d0fc338b383cf552257d952cc59df3`.
The adapter verifies all 75 extracted files against pinned hashes before initializing Cactus.
`config.txt` is already in the archive; no other config download is needed.

Despite their filenames, this revision's published int4 and int8 ZIPs are byte-identical and
their internal configuration says `precision=FP16`. The recipe records FP16 and exact artifact,
runtime and preprocessing identities. Changing any of those creates a different embedding
space. Unit tests pin both bundled runtime slices to detect unversioned binary replacements.

Observed on 2026-10-25, iPhone 17 / iOS 27 simulator: 3.2608125 seconds of public speech produced
256 finite dimensions, normalized norm 1.0000000012 and repeat cosine 1.0. First and second
native inference took 534.37 ms and 507.20 ms; total time including verification/load and two
calls was 1.067 seconds. These are simulator smoke measurements, **not recognition accuracy,
phone performance, battery measurements or evidence of robustness on watch Speex audio**.

## Evaluate a real, explicitly labeled corpus

Create a local JSON manifest with `policy`, optional `selfPersonID`, and `samples`. Every sample
needs an explicit confirmation identifier and immutable media-range provenance. Each PCM file
is an already decoded/cropped 16 kHz mono PCM16LE file, 2–30 seconds long. Paths are relative to
the manifest directory or absolute; none is uploaded.

The following illustrates one enrollment row. Fill in real reviewed labels and add held-out
`"probe"` rows before running. The threshold numbers below are **illustrative only**, not a
recommended operating point. Use separate tuning and test files; choose thresholds on tuning
data and freeze them before examining test outcomes.

```json
{
  "policy": {
    "minimumSimilarity": 0.8,
    "minimumMargin": 0.1,
    "minimumExamples": 2,
    "calibrationID": "replace-with-your-tuning-experiment"
  },
  "selfPersonID": "00000000-0000-0000-0000-000000000001",
  "samples": [{
    "id": "replace-with-unique-crop-id",
    "pcmPath": "reviewed-crop.pcm",
    "partition": "enrollment",
    "personID": "00000000-0000-0000-0000-000000000001",
    "confirmationID": "replace-with-review-event-id",
    "condition": "watch-speex-quiet-room",
    "evidence": {
      "sourceID": "replace-with-source-id",
      "sourceRevision": "replace-with-audio-revision",
      "sessionID": "replace-with-recording-session",
      "startSample": 16000,
      "endSample": 96000,
      "speechOnly": true,
      "singleSpeaker": true,
      "containsDiscontinuity": false
    }
  }]
}
```

For a probe from a reviewed, unenrolled person set `personID` to `null`. This means a confirmed
unknown, **not an unlabeled sample**. A known probe's UUID must appear in enrollment. Use distinct
recording sessions/days for enrollment and probes; the harness refuses overlapping sessions,
duplicate crop paths and repeated IDs. Provenance still needs honest human review; differing
filenames/session strings cannot prove that two crops are independent.

```sh
bash ios/Tools/SpeakerEvaluation/run-native.sh SIMULATOR_UDID evaluate \
  /tmp/pebble-speaker-evaluation/model /absolute/path/to/reviewed-manifest.json
```

The JSON report contains the exact recipe and policy, per-crop decisions, total/known/unknown
counts, correct names, incorrect names, known abstentions, rejected unknowns, false-self matches,
named count and counts by condition. Coverage is `named / total` (also available as the Swift
`counts.coverage` property). An absent runner-up margin means only one eligible person remains;
the absolute threshold still applies. No threshold is shipped as a production default.

Include substantial unknown-speaker trials, similar voices, short turns, quiet/noisy watch
recordings, different microphones, illness, playback, and enrollment on phone followed by watch
evaluation. Preserve the decoded watch signal and source range; don't boost it with the optional
transcription gain. Reject overlaps/discontinuities rather than inventing a ground-truth label.
Report errors and abstention together. A small friendly-room corpus cannot establish a safe
false-self rate for real conversations.

For precomputed embeddings, `evaluate-embeddings.sh INPUT.json` runs on macOS without Cactus.
Its input is `{"policy": ..., "corpus": {"enrollment": [...], "probes": [...],
"selfPersonID": ...}}`, matching the Codable `SpeakerEvaluationCorpus` types. It rejects mixed
recipes and session leakage. It does not infer labels or quietly retune thresholds.

Focused package verification:

```sh
cd ios/PebbleAudioKit
swift test --filter 'SpeakerRecognitionTests|SpeakerMatchingTests'
```

No labeled watch corpus has been evaluated yet. The remaining product gate is explicit consent
and confirmed enrollment, then measured false naming/false-self and abstention on held-out watch
sessions, before wiring any automated identity assignment into the app.
