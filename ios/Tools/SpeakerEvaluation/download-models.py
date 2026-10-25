#!/usr/bin/env python3
"""Explicit public model download for the local developer harness; no audio input/upload."""
import hashlib
import json
import pathlib
import sys
import urllib.request
import zipfile

root = pathlib.Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
EMBEDDING_URL = "https://huggingface.co/Cactus-Compute/wespeaker-voxceleb-resnet34-LM/resolve/f145212639b5cea874482e70002935daa987fe44/weights/wespeaker-voxceleb-resnet34-lm-int8.zip"
EMBEDDING_SHA256 = "cc6fc908455c77f08a4fa2d6090649b13e13c7f865ba01c3d6ff8d82e31b1c71"
SEGMENTATION_URL = "https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/7eab74f3463c736418d0eb10296261ae581146c9/Segmentation.mlmodelc/"
FILES = {'analytics/coremldata.bin': '64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb', 'coremldata.bin': 'ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc', 'metadata.json': '88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124', 'model.mil': 'd37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f', 'weights/weight.bin': 'c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2'}

def fetch(url, path, digest):
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + '.download')
        urllib.request.urlretrieve(url, temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
            temporary.unlink()
            raise ValueError('Model checksum mismatch: ' + url)
        temporary.replace(path)

archive = root / 'wespeaker.zip'
fetch(EMBEDDING_URL, archive, EMBEDDING_SHA256)
with zipfile.ZipFile(archive) as package:
    for name in package.namelist():
        if pathlib.PurePosixPath(name).is_absolute() or '..' in pathlib.PurePosixPath(name).parts:
            raise ValueError('Unsafe archive path')
    package.extractall(root / 'model')
for name, digest in FILES.items():
    fetch(SEGMENTATION_URL + name, root / 'Segmentation.mlmodelc' / name, digest)
print(json.dumps(dict(embedding=str(root / 'model'), segmentation=str(root / 'Segmentation.mlmodelc')), indent=2))
