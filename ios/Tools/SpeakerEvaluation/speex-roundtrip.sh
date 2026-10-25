#!/bin/bash
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 PUBLIC_DIR OUTPUT_DIR" >&2; exit 2; }
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kit="$(cd "$tool_dir/../../PebbleAudioKit" && pwd)"
work="$(mktemp -d /tmp/pebble-speaker-codec.XXXXXX)"
trap 'rm -rf "$work"' EXIT
objects=()
for source in "$kit"/Sources/CSpeex/*.c; do
    object="$work/$(basename "${source%.c}").o"
    xcrun clang -c -O2 -I "$kit/Sources/CSpeex/include" -DEXPORT= -DFIXED_POINT \
        -DDISABLE_FLOAT_API -DDISABLE_VBR -DVAR_ARRAYS -DDISABLE_WARNINGS -DDISABLE_NOTIFICATIONS \
        "$source" -o "$object"
    objects+=("$object")
done
xcrun swiftc -swift-version 6 -parse-as-library -O -I "$kit/Sources/CSpeex/include" \
    "$kit/Sources/AudioCodec/SpeexFrameDecoder.swift" "$kit/Sources/AudioCodec/SpeexFrameEncoder.swift" \
    "$tool_dir/SpeexRoundTrip.swift" "${objects[@]}" -o "$work/speex-roundtrip"
"$work/speex-roundtrip" "$@"
