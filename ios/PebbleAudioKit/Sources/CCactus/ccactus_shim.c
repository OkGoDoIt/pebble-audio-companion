// `CCactus` is a headers-only view of the vendored Cactus C FFI (`include/cactus_ffi.h`,
// copied verbatim from `cactus/src/nativeInterop/cinterop/`). The implementations live in the
// `CactusBinary` xcframework, which is linked on iOS only — so the module still imports on
// macOS, where `swift test` runs and no Cactus slice exists. Swift call sites are therefore
// guarded with `#if os(iOS)`; on macOS nothing references a `cactus_*` symbol.
//
// SwiftPM rejects a target with no sources, hence this anchor translation unit.

int ccactus_module_anchor(void);

int ccactus_module_anchor(void) { return 0; }
