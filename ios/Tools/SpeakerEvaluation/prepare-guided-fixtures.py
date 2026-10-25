#!/usr/bin/env python3
"""Fetch continuous labeled public utterances for the 20-second enrollment gate.

Usage: prepare-guided-fixtures.py PUBLIC_HELDOUT_DIR OUTPUT_DIR
Uses the saved official metadata from prepare-public-corpus.py --held-out.
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import urllib.request

source = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=True)
rows = {}
for path in source.glob('rows-*.json'):
    for wrapper in json.loads(path.read_text())['rows']:
        rows[wrapper['row']['id']] = wrapper['row']
manifest = []
for identifier in ['6930-75918-0003', '1320-122617-0007', '260-123288-0015']:
    row = rows[identifier]
    compressed = output / (identifier + '.flac')
    urllib.request.urlretrieve(row['audio'][0]['src'], compressed)
    pcm = output / (identifier + '.pcm')
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(compressed), '-t', '20',
                    '-ac', '1', '-ar', '16000', '-f', 's16le', str(pcm)], check=True)
    data = pcm.read_bytes()
    manifest.append(dict(id=identifier, pcmPath=str(pcm), sourceID=identifier,
                         sourceRevision=hashlib.sha256(data).hexdigest(),
                         sessionID='continuous-public-' + identifier, sourceStartSample=0))
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
print(output / 'manifest.json')
