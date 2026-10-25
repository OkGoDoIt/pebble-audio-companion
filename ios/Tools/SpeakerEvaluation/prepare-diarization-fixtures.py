#!/usr/bin/env python3
"""Construct reproducible public speaker changes/overlap; no private audio or guessed labels."""
import hashlib
import json
import pathlib
import struct
import sys

source = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=True)
metadata = json.loads((source / 'metadata.json').read_text())


def read(speaker, minimum=7):
    row = next(r for r in metadata if r['actualSpeakerID'] == speaker and r['durationSeconds'] >= minimum)
    data = pathlib.Path(row['pcmPath']).read_bytes()
    return row, list(struct.unpack('<' + 'h' * (len(data) // 2), data))


def normalize(samples):
    rms = (sum(x * x for x in samples) / len(samples)) ** .5
    return [x * 2000 / rms for x in samples]


a_row, a = read(6930)
b_row, b = read(1320)
c_row, c = read(260)
d_row, d = read(7729)
a_normal, d_normal = normalize(a), normalize(d)
fixtures = {
    'sequential': (a[:96000] + [0] * 3200 + b[:96000] + [0] * 3200 + c[:96000]
                   + [0] * 3200 + a[:96000] + [0] * 3200),
    'unbalanced-overlap': a[:48000] + [(x + y) / 2 for x, y in zip(a[48000:96000], b[:48000])] + b[48000:96000],
    'balanced-overlap': a_normal[:32000] + [(x + y) * .6 for x, y in zip(a_normal[32000:112000], d_normal[:80000])] + d_normal[80000:112000],
}
manifest = []
for name, samples in fixtures.items():
    pcm = struct.pack('<' + 'h' * len(samples), *[round(max(-32767, min(32767, x))) for x in samples])
    path = output / (name + '.pcm')
    path.write_bytes(pcm)
    manifest.append(dict(id=name, pcmPath=str(path), sourceID='public-constructed-' + name,
                         sourceRevision=hashlib.sha256(pcm).hexdigest(), sessionID='public-fixture-' + name, sourceStartSample=0))
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
(output / 'construction.json').write_text(json.dumps(dict(
    sources=[r['id'] for r in [a_row, b_row, c_row, d_row]],
    sequentialSpeakerSpans=[[0,6,6930],[6.2,12.2,1320],[12.4,18.4,260],[18.6,24.6,6930]],
    balancedMixedSpanSeconds=[2,7], unbalancedMixedSpanSeconds=[3,6],
    warning='Constructed source ranges include natural speech pauses. This is a targeted regression, not manually annotated diarization error rate.'), indent=2))
print(output / 'manifest.json')
