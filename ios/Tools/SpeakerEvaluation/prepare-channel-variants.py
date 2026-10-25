#!/usr/bin/env python3
"""Prepare one codec variant per accepted real source crop, preserving whole-stream codec state.

Usage: prepare-channel-variants.py RAW_DIR CODEC_DIR OUTPUT_DIR
RAW_DIR contains metadata.json and analysis.json; CODEC_DIR contains the full Speex roundtrip PCM.
Then export-embeddings the emitted manifest using the native harness.
"""
import hashlib
import json
import pathlib
import sys

raw, codec, output = map(lambda p: pathlib.Path(p).resolve(), sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
metadata = {r['id']: r for r in json.loads((raw / 'metadata.json').read_text())}
examples, samples, rejected = [], [], []
for result in json.loads((raw / 'analysis.json').read_text()):
    row = metadata[result['id']]
    if row['partition'] != 'enrollment':
        continue
    turns = result.get('analysis', {}).get('turns', [])
    clusters = {t['clusterID'] for t in turns if t.get('clusterID')}
    if 'error' in result or any(t['overlap'] for t in turns) or len(clusters) > 1:
        rejected.append(row['id'])
        continue
    whole = (codec / (row['id'] + '.pcm')).read_bytes()
    for turn in turns:
        if not turn.get('embedding') or not turn.get('clusterID') or turn['speechConfidence'] < .7:
            continue
        start, end = turn['startSample'], turn['endSample']
        identifier = f"{row['id']}:{start}:{end}"
        path = output / (identifier.replace(':', '-') + '.pcm')
        path.write_bytes(whole[start*2:end*2])
        confirmation = 'official-librispeech:' + row['id']
        examples.append(dict(id=identifier, personID=row['personID'], confirmationID=confirmation,
                             sessionID=row['sessionID'], embedding=turn['embedding']))
        samples.append(dict(id=identifier, pcmPath=str(path), partition='enrollment', personID=row['personID'],
            confirmationID=confirmation, condition='public-phone-speex-variant',
            evidence=dict(sourceID=row['sourceID'], sourceRevision=hashlib.sha256(whole).hexdigest(),
                          sessionID=row['sessionID'], startSample=start, endSample=end,
                          speechOnly=True, singleSpeaker=True, containsDiscontinuity=False)))
policy = dict(minimumSimilarity=.55, minimumMargin=.10, minimumExamples=2,
              calibrationID='public-read-speech-cactus-f145212-codec-variants-v2')
(output / 'manifest.json').write_text(json.dumps(dict(policy=policy, samples=samples), indent=2))
(output / 'raw-examples.json').write_text(json.dumps(examples, indent=2))
(output / 'eligibility.json').write_text(json.dumps(dict(realCrops=len(examples), rejectedClips=rejected), indent=2))
print(json.dumps(dict(realCrops=len(examples), rejectedClips=rejected)))
