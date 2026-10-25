#!/usr/bin/env python3
"""Offline alternative-encoder experiment; never uploads the provided corpus.

Usage: python compare-onnx.py MODEL.onnx PUBLIC_DIR WATCH_DIR OUTPUT.json
Requires sherpa-onnx and numpy. The watch provider labels are comparison metadata, NOT truth.
"""
import hashlib
import itertools
import json
from pathlib import Path
import sys
import time
import numpy as np
import sherpa_onnx

model, public, watch, output = map(Path, sys.argv[1:])
config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model), num_threads=2, provider="cpu", debug=False)
extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)


def embedding(pcm):
    waveform = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768
    stream = extractor.create_stream()
    stream.accept_waveform(sample_rate=16000, waveform=np.ascontiguousarray(waveform))
    stream.input_finished()
    if not extractor.is_ready(stream):
        raise ValueError("Insufficient audio")
    value = np.asarray(extractor.compute(stream), dtype=float)
    return value / np.linalg.norm(value)


started = time.monotonic()
public_meta = json.loads((public / "metadata.json").read_text())
vectors = {item["id"]: embedding(Path(item["pcmPath"]).read_bytes()) for item in public_meta}
enrolled = {}
for item in public_meta:
    if item["partition"] == "enrollment":
        enrolled.setdefault(item["personID"], []).append(vectors[item["id"]])
public_results = []
for item in public_meta:
    if item["partition"] == "enrollment":
        continue
    vector = vectors[item["id"]]
    scores = [(person, float(np.mean(sorted([float(vector @ v) for v in examples], reverse=True)[:2])))
              for person, examples in enrolled.items()]
    scores.sort(key=lambda pair: pair[1], reverse=True)
    public_results.append(dict(id=item["id"], truth=item["personID"], winner=scores[0][0],
                               score=scores[0][1], margin=scores[0][1] - scores[1][1]))

watch_meta = {item["id"]: item for item in json.loads((watch / "metadata.json").read_text())}
watch_inputs = {item["id"]: item for item in json.loads((watch / "analyze-manifest.json").read_text())}
watch_vectors = {}
for result in json.loads((watch / "analysis-results.json").read_text()):
    item = watch_inputs[result["id"]]
    pcm = Path(item["pcmPath"]).read_bytes()
    values = []
    for turn in result["analysis"]["turns"]:
        if not turn.get("embedding"):
            continue
        start = turn["startSample"] - item["sourceStartSample"]
        end = turn["endSample"] - item["sourceStartSample"]
        values.append(embedding(pcm[start * 2:end * 2]))
    if values:
        value = np.sum(values, axis=0)
        watch_vectors[item["id"]] = value / np.linalg.norm(value)
same, different = [], []
for (a, av), (b, bv) in itertools.combinations(watch_vectors.items(), 2):
    if watch_meta[a]["sessionID"] != watch_meta[b]["sessionID"]:
        continue
    score = float(av @ bv)
    (same if watch_meta[a]["providerSpeaker"] == watch_meta[b]["providerSpeaker"] else different).append(score)
report = dict(modelSHA256=hashlib.sha256(model.read_bytes()).hexdigest(), model=model.name,
              runtime="sherpa-onnx-" + sherpa_onnx.__version__, seconds=time.monotonic() - started,
              public=public_results, watchSameProviderScores=same, watchDifferentProviderScores=different,
              watchLabelStatus="provider consistency, not confirmed identity accuracy")
output.write_text(json.dumps(report, indent=2))
for title, scores in [("known-public", [r["score"] for r in public_results if r["truth"]]),
                      ("unknown-public", [r["score"] for r in public_results if not r["truth"]]),
                      ("watch-same-provider", same), ("watch-different-provider", different)]:
    print(title, "n", len(scores), "min/median/max", np.round([min(scores), np.median(scores), max(scores)], 3).tolist())
