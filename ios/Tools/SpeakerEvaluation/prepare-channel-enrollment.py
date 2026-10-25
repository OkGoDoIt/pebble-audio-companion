#!/usr/bin/env python3
"""Public continuous phone-enrollment controls, disjoint chapters from held-out probes.

Usage: prepare-channel-enrollment.py PUBLIC_HELDOUT_DIR OUTPUT_DIR
Each natural utterance is capped/padded to a 20-second microphone capture; padding is silence.
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import urllib.request
import uuid

source, output = map(lambda p: pathlib.Path(p).resolve(), sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
rows = {}
for path in source.glob('rows-*.json'):
    for item in json.loads(path.read_text())['rows']:
        rows[item['row']['id']] = item['row']
heldout = json.loads((source / 'metadata.json').read_text())
metadata, samples = [], []
for identifier in ['6930-75918-0003', '1320-122612-0011', '260-123440-0004']:
    row = rows[identifier]
    assert not any(p['partition'] == 'probe' and p['actualSpeakerID'] == row['speaker_id']
                   and p['chapterID'] == row['chapter_id'] for p in heldout), 'Enrollment/probe chapter leakage'
    compressed = output / (identifier + '.flac')
    if not compressed.exists():
        urllib.request.urlretrieve(row['audio'][0]['src'], compressed)
    pcm = output / (identifier + '.pcm')
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(compressed), '-t', '20',
                    '-ac', '1', '-ar', '16000', '-f', 's16le', str(pcm)], check=True)
    natural = pcm.read_bytes()
    data = natural + bytes(max(0, 640000 - len(natural)))
    pcm.write_bytes(data)
    person = str(uuid.uuid5(uuid.NAMESPACE_URL, f"librispeech-speaker-{row['speaker_id']}"))
    item = dict(id=identifier, pcmPath=str(pcm), sourceID=identifier,
                sourceRevision=hashlib.sha256(data).hexdigest(),
                sessionID=f"librispeech-{row['speaker_id']}-{row['chapter_id']}", sourceStartSample=0,
                personID=person, actualSpeakerID=row['speaker_id'], chapterID=row['chapter_id'],
                partition='enrollment', durationSeconds=20, naturalAudioSeconds=len(natural)/32000,
                labelSource='openslr/librispeech_asr clean test official speaker_id/chapter_id')
    metadata.append(item)
    samples.append(dict(id=identifier, pcmPath=str(pcm), partition='enrollment', personID=person,
        confirmationID='official-librispeech:'+identifier, condition='public-phone-continuous',
        evidence=dict(sourceID=identifier, sourceRevision=item['sourceRevision'], sessionID=item['sessionID'],
                      startSample=0, endSample=len(data)//2, speechOnly=True, singleSpeaker=True, containsDiscontinuity=False)))
policy = dict(minimumSimilarity=.55, minimumMargin=.10, minimumExamples=2,
              calibrationID='public-read-speech-cactus-f145212-codec-variants-v2')
(output / 'metadata.json').write_text(json.dumps(metadata, indent=2))
(output / 'manifest.json').write_text(json.dumps(dict(policy=policy, samples=samples), indent=2))
print(json.dumps([dict(id=r['id'], naturalAudioSeconds=r['naturalAudioSeconds']) for r in metadata]))
