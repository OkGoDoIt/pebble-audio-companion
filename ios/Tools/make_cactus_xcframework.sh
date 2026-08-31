#!/bin/bash
# Rebuilds ios/PebbleAudioKit/Frameworks/CactusBinary.xcframework from the vendored Cactus
# static libraries in the (read-only) KMP tree.
#
# SPM cannot link loose `.a` files, so each platform slice is merged into ONE library —
# libcactus.a + libcurl.a via `libtool -static` — and the two slices are packed into an
# xcframework declared as a `.binaryTarget`. Headers are NOT shipped here: the `CCactus`
# source target owns `cactus_ffi.h` + its module map so `import CCactus` also resolves on
# macOS (where `swift test` runs and no Cactus binary exists).
#
# Usage: ios/Tools/make_cactus_xcframework.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$repo_root/cactus/src/commonMain/resources/ios/lib"
out="$repo_root/ios/PebbleAudioKit/Frameworks/CactusBinary.xcframework"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for slice in ios-arm64 ios-arm64-simulator; do
    for lib in libcactus.a libcurl.a; do
        [ -f "$src/$slice/$lib" ] || { echo "missing $src/$slice/$lib" >&2; exit 1; }
    done
    mkdir -p "$work/$slice"
    # One archive per slice: an xcframework slice may declare exactly one library.
    libtool -static -o "$work/$slice/libCactusBinary.a" \
        "$src/$slice/libcactus.a" "$src/$slice/libcurl.a" 2>/dev/null
done

rm -rf "$out"
mkdir -p "$(dirname "$out")"
xcodebuild -create-xcframework \
    -library "$work/ios-arm64/libCactusBinary.a" \
    -library "$work/ios-arm64-simulator/libCactusBinary.a" \
    -output "$out" >/dev/null

echo "built $out"
find "$out" -name '*.a' -exec sh -c 'echo "  $1: $(lipo -info "$1" | sed "s/.*architecture: //")"' _ {} \;
