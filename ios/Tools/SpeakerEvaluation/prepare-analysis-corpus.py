#!/usr/bin/env python3
"""Join actual analyzer output to explicit PUBLIC dataset labels; never infer private identities.

Usage: prepare-analysis-corpus.py PUBLIC_METADATA.json ANALYSIS.json OUTPUT.json
The generated corpus is scored by the production Swift evaluator, evaluate-embeddings.sh.
"""
import collections
import json
import pathlib
import sys

metadata = {r['id']: r for r in json.loads(pathlib.Path(sys.argv[1]).read_text())}
analysis = json.loads(pathlib.Path(sys.argv[2]).read_text())
output = pathlib.Path(sys.argv[3])
corpus = dict(enrollment=[], probes=[], selfPersonID=None)
coverage = collections.Counter()
for result in analysis:
    row = metadata[result['id']]
    if row.get('labelSource') != 'openslr/librispeech_asr clean test official speaker_id/chapter_id':
        raise ValueError('This helper accepts only the explicitly labeled public corpus')
    coverage[row['partition'] + 'Clips'] += 1
    turns = result.get('analysis', {}).get('turns', [])
    if 'error' in result:
        raise ValueError('Analyze failed: ' + result['id'])
    eligible = [t for t in turns if t.get('embedding')]
    coverage[row['partition'] + 'ClipsWithoutEmbedding'] += not bool(eligible)
    coverage[row['partition'] + 'TurnsWithoutEmbedding'] += len(turns) - len(eligible)
    for turn in eligible:
        identifier = f"{row['id']}:{turn['startSample']}:{turn['endSample']}"
        sample = dict(id=identifier, sessionID=row['sessionID'], personID=row['personID'], embedding=turn['embedding'])
        if row['partition'] == 'enrollment':
            if row['personID'] is None:
                raise ValueError('Enrollment requires an explicit person')
            sample['confirmationID'] = 'official-librispeech:' + row['id']
            corpus['enrollment'].append(sample)
        else:
            sample['labelConfirmationID'] = 'official-librispeech:' + row['id']
            sample['condition'] = 'public-read-speech-through-production-segmentation'
            corpus['probes'].append(sample)
policy = dict(minimumSimilarity=.55, minimumMargin=.10, minimumExamples=2,
              calibrationID='public-read-speech-cactus-f145212-v1')
output.write_text(json.dumps(dict(policy=policy, corpus=corpus, analysisCoverage=dict(coverage)), indent=2))
print(json.dumps(dict(coverage=coverage, enrollmentEmbeddings=len(corpus['enrollment']), probes=len(corpus['probes'])), indent=2))
