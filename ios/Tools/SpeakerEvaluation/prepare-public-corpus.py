#!/usr/bin/env python3
"""Download a small, explicitly speaker-labeled LibriSpeech benchmark. Public data only.

Requires ffmpeg for the dataset's FLAC files. Writes only below the given output directory.
Speaker/chapter labels come from official dataset metadata, never a guessed voice identity.
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.request
import uuid
from collections import defaultdict

output = Path(sys.argv[1]).resolve()
held_out = len(sys.argv) > 2 and sys.argv[2] == "--held-out"
output.mkdir(parents=True, exist_ok=True)
groups = defaultdict(lambda: defaultdict(list))
for offset in ([0, 100, 200, 300, 400, 500] if held_out else [0, 100, 200, 300]):
    url = ("https://datasets-server.huggingface.co/rows?dataset=openslr/librispeech_asr"
           f"&config=clean&split=test&offset={offset}&length=100")
    rows = json.load(urllib.request.urlopen(url, timeout=60))
    (output / f"rows-{offset}.json").write_text(json.dumps(rows))
    for wrapper in rows["rows"]:
        row = wrapper["row"]
        groups[row["speaker_id"]][row["chapter_id"]].append(row)

selected = []
for speaker in [6930, 1320, 260]:
    chapters = sorted(groups[speaker])
    person = str(uuid.uuid5(uuid.NAMESPACE_URL, f"librispeech-speaker-{speaker}"))
    for partition, chapter, count in [("enrollment", chapters[0], 3), ("probe", chapters[1], 5)]:
        rows = groups[speaker][chapter]
        chosen = rows[5:11] if held_out and partition == "probe" else rows[:count]
        for row in chosen:
            selected.append((partition, row, person))
unknown_speakers = ([speaker for speaker in sorted(groups) if speaker not in [6930, 1320, 260, 5639, 7729, 2094, 3575]][:3]
                    if held_out else [5639, 7729, 2094, 3575])
for speaker in unknown_speakers:
    for row in next(iter(groups[speaker].values()))[:4]:
        selected.append(("probe", row, None))


def fetch(entry):
    partition, row, person = entry
    identifier = row["id"]
    compressed = output / f"{identifier}.flac"
    urllib.request.urlretrieve(row["audio"][0]["src"], compressed)
    pcm_path = output / f"{identifier}.pcm"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(compressed), "-t", "8",
                    "-ac", "1", "-ar", "16000", "-f", "s16le", str(pcm_path)], check=True)
    pcm = pcm_path.read_bytes()
    if len(pcm) < 64000:
        return None
    return dict(id=identifier, pcmPath=str(pcm_path), sourceID=identifier,
                sourceRevision=hashlib.sha256(pcm).hexdigest(),
                sessionID=f"librispeech-{row['speaker_id']}-{row['chapter_id']}", sourceStartSample=0,
                partition=partition, personID=person, actualSpeakerID=row["speaker_id"],
                chapterID=row["chapter_id"], durationSeconds=len(pcm) / 32000,
                labelSource="openslr/librispeech_asr clean test official speaker_id/chapter_id")


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    records = [row for row in pool.map(fetch, selected) if row]
(output / "metadata.json").write_text(json.dumps(records, indent=2))
samples = []
for row in records:
    samples.append(dict(id=row["id"], pcmPath=row["pcmPath"], partition=row["partition"],
                        personID=row["personID"], confirmationID="official-librispeech:" + row["id"],
                        condition="public-librispeech-read-english", evidence=dict(
                            sourceID=row["sourceID"], sourceRevision=row["sourceRevision"],
                            sessionID=row["sessionID"], startSample=0,
                            endSample=int(row["durationSeconds"] * 16000), speechOnly=True,
                            singleSpeaker=True, containsDiscontinuity=False)))
# Low threshold exports score distributions for a subsequent tuning/held-out split. It is
# intentionally unsuitable for app recognition; do not interpret its raw naming error rate
# as the app's operating point.
manifest = dict(policy=dict(minimumSimilarity=0.55 if held_out else -1,
                            minimumMargin=0.10 if held_out else 0, minimumExamples=2,
                            calibrationID="public-read-speech-cactus-f145212-v1" if held_out else "public-score-distribution-only"),
                selfPersonID=None, samples=samples)
(output / "manifest.json").write_text(json.dumps(manifest, indent=2))
print(json.dumps(dict(clips=len(records), enrolled=sum(r["partition"] == "enrollment" for r in records),
                     knownProbes=sum(r["partition"] == "probe" and r["personID"] is not None for r in records),
                     unknownProbes=sum(r["personID"] is None for r in records))))
