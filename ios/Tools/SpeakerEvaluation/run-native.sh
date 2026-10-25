#!/bin/bash
# Build the real package adapter as a simulator command-line tool. No app install/deploy,
# model download, private audio upload, or changes to the app's settings/container.
set -euo pipefail
if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "usage: $0 SIMULATOR_UDID smoke|evaluate MODEL_DIR PCM_OR_MANIFEST; or SIMULATOR_UDID analyze|analyze-corpus EMBEDDING_DIR SEGMENTATION_DIR PCM_OR_MANIFEST" >&2
    exit 2
fi
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kit="$(cd "$tool_dir/../../PebbleAudioKit" && pwd)"
work="$(mktemp -d /tmp/pebble-speaker-native.XXXXXX)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
flags=(-sdk "$sdk" -target arm64-apple-ios26.0-simulator -swift-version 6)
# The adapter normally imports Transcription just for this privacy guard. Compile that exact
# source into a tiny temporary module, avoiding a whole-app build for this developer harness.
xcrun --sdk iphonesimulator swiftc "${flags[@]}" -parse-as-library -emit-object -emit-module \
    -module-name Transcription \
    -emit-module-path "$work/Transcription.swiftmodule" \
    "$kit/Sources/Transcription/Local/CactusPrivacyConfiguration.swift" -o "$work/privacy.o"
sources=()
for source in "$kit"/Sources/SpeakerRecognition/*.swift; do
    [[ "$source" == */SpeakerModelStore.swift ]] || sources+=("$source")
done
xcrun --sdk iphonesimulator swiftc "${flags[@]}" -parse-as-library -O \
    -I "$work" -I "$kit/Sources/CCactus/include" \
    "${sources[@]}" "$tool_dir/NativeMain.swift" "$work/privacy.o" \
    "$kit/Frameworks/CactusBinary.xcframework/ios-arm64-simulator/libCactusBinary.a" \
    -framework Foundation -framework Accelerate -framework CoreML -framework Security \
    -framework SystemConfiguration -framework CFNetwork -lc++ -lz -o "$work/speaker-native"
simulator="$1"
shift
xcrun simctl spawn "$simulator" "$work/speaker-native" "$@"
