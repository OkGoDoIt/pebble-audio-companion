#!/bin/bash
# Pure offline scoring of explicitly labeled, precomputed embeddings; no native inference.
set -euo pipefail
[[ $# == 1 ]] || { echo "usage: $0 INPUT.json" >&2; exit 2; }
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$tool_dir/../../PebbleAudioKit/Sources/SpeakerRecognition"
work="$(mktemp -d /tmp/pebble-speaker-scores.XXXXXX)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -O \
    "$src/SpeakerEmbedding.swift" "$src/SpeakerMatching.swift" "$src/SpeakerEvaluation.swift" \
    "$tool_dir/EvaluateMain.swift" -o "$work/evaluate-embeddings"
"$work/evaluate-embeddings" "$1"
