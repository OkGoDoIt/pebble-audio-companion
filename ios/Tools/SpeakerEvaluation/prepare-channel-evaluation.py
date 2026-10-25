#!/usr/bin/env python3
"""Generate raw/codec/augmented corpora for the actual Swift matcher; no invented labels.

Usage: prepare-channel-evaluation.py VARIANTS_DIR PROBE_METADATA.json PROBE_ANALYSIS.json OUTPUT_DIR
Run evaluate-embeddings.sh on each emitted mode.json. Real evidence IDs/counts stay identical.
"""
import copy
import json
import pathlib
import sys

variants, metadata_path, analysis_path, output = map(pathlib.Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
raw = json.loads((variants / 'raw-examples.json').read_text())
encoded = {r['id']: r['embedding'] for r in json.loads((variants / 'embeddings.json').read_text())['corpus']['enrollment']}
metadata = {r['id']: r for r in json.loads(metadata_path.read_text())}
sessions = {e['sessionID'] for e in raw}
probes, without = [], []
for result in json.loads(analysis_path.read_text()):
    row = metadata[result['id']]
    if row['partition'] != 'probe':
        continue
    assert row['sessionID'] not in sessions, 'Enrollment/probe session leakage'
    if 'error' in result:
        raise ValueError('Analyzer error: ' + row['id'])
    eligible = [t for t in result['analysis']['turns'] if t.get('embedding') and not t['overlap']
                and t['speechConfidence'] >= .7 and t['endSample'] - t['startSample'] >= 32000]
    if not eligible:
        without.append(dict(id=row['id'], personID=row['personID']))
    for turn in eligible:
        probes.append(dict(id=f"{row['id']}:{turn['startSample']}:{turn['endSample']}",
            sessionID=row['sessionID'], personID=row['personID'], labelConfirmationID='official-librispeech:'+row['id'],
            condition='public-raw-phone-enrollment-to-speex-probe', embedding=turn['embedding']))
policy = dict(minimumSimilarity=.55, minimumMargin=.10, minimumExamples=2,
              calibrationID='public-read-speech-cactus-f145212-codec-variants-v2')
for mode in ['raw', 'codec', 'augmented']:
    examples = copy.deepcopy(raw)
    for example in examples:
        if mode == 'codec':
            example['embedding'] = encoded[example['id']]
        elif mode == 'augmented':
            example['embeddingVariants'] = [encoded[example['id']]]
    (output / (mode+'.json')).write_text(json.dumps(dict(policy=policy,
        corpus=dict(enrollment=examples, probes=probes)), indent=2))
(output / 'eligibility.json').write_text(json.dumps(dict(realEnrollmentCrops=len(raw),
    eligibleProbeTurns=len(probes), probeClipsWithoutEligibleTurns=without), indent=2))
print(json.dumps(dict(realEnrollmentCrops=len(raw), eligibleProbeTurns=len(probes),
                     probeClipsWithoutEligibleTurns=without)))
