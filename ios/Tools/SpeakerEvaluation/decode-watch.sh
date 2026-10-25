#!/bin/bash
set -euo pipefail
[[ $# == 3 ]] || { echo "usage: $0 BACKUP REQUESTS.json OUTPUT_DIR" >&2; exit 2; }
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kit="$(cd "$tool_dir/../../PebbleAudioKit" && pwd)"
work="$(mktemp -d /tmp/pebble-speaker-decode.XXXXXX)"
trap 'rm -rf "$work"' EXIT
# Compile the exact vendored fixed-point Speex sources, independent of a mutable build cache.
objects=()
for source in "$kit"/Sources/CSpeex/*.c; do
    object="$work/$(basename "${source%.c}").o"
    xcrun clang -c -O2 -I "$kit/Sources/CSpeex/include" -DEXPORT= -DFIXED_POINT \
        -DDISABLE_FLOAT_API -DDISABLE_VBR -DVAR_ARRAYS -DDISABLE_WARNINGS -DDISABLE_NOTIFICATIONS \
        "$source" -o "$object"
    objects+=("$object")
done
xcrun swiftc -swift-version 6 -parse-as-library -O -I "$kit/Sources/CSpeex/include" \
    "$kit/Sources/AudioCodec/SpeexFrameDecoder.swift" "$tool_dir/DecodeWatchCorpus.swift" \
    "${objects[@]}" -o "$work/decode-watch"
"$work/decode-watch" "$@"
