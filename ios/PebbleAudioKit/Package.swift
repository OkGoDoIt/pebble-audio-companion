// swift-tools-version: 6.0
// PebbleAudioKit — the no-UI core of the native iOS rebuild.
// Module boundaries mirror the implementation plan (Part 3): the KMP modules and their
// test suites are the behavioral spec; spec/fixtures are the wire contract.
import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "PebbleAudioKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(
            name: "PebbleAudioKit",
            targets: [
                "WireProtocol", "SegmentStore", "Receiver", "StatusUI", "AppDB",
                "Transcription", "Intelligence", "LiveAudio", "SearchKit", "Migration",
                "CompanionRuntime", "AudioCodec", "Firmware", "MuseLink",
            ]
        ),
        // The Muse gadget protocol on its own, for the macOS developer tools in ios/Tools/MuseDev
        // that pair and exercise a gadget without building the whole kit.
        .library(name: "MuseLink", targets: ["MuseLink"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        // Vendored Speex 1.2.1 (decoder + encoder core) from PebbleOS/third_party/speex.
        // Defines mirror the firmware build (FIXED_POINT arithmetic parity) minus its
        // embedded-only allocator/stack overrides; VAR_ARRAYS uses C99 VLAs for scratch.
        .target(
            name: "CSpeex",
            exclude: ["COPYING"],
            cSettings: [
                .define("EXPORT", to: ""),
                .define("FIXED_POINT"),
                .define("DISABLE_FLOAT_API"),
                .define("DISABLE_VBR"),
                .define("VAR_ARRAYS"),
                .define("DISABLE_WARNINGS"),
                .define("DISABLE_NOTIFICATIONS"),
            ]
        ),
        .target(name: "AudioCodec", dependencies: ["CSpeex"], swiftSettings: swiftSettings),
        // Vendored Cactus (Parakeet on-device speech-to-text), split in two so `swift test`
        // still builds for macOS, where no Cactus slice exists:
        //   • `CactusBinary` — libcactus.a + libcurl.a merged per slice into one xcframework
        //     (SPM cannot link loose `.a` files). Rebuild with
        //     `ios/Tools/make_cactus_xcframework.sh`. iOS-only, hence the platform condition.
        //   • `CCactus` — `cactus_ffi.h` + its module map, so `import CCactus` resolves
        //     everywhere; Swift call sites are `#if os(iOS)`.
        .binaryTarget(name: "CactusBinary", path: "Frameworks/CactusBinary.xcframework"),
        .target(
            name: "CCactus",
            dependencies: [.target(name: "CactusBinary", condition: .when(platforms: [.iOS]))],
            linkerSettings: [
                // Mirrors `cactus/src/nativeInterop/cinterop/cactus.def`'s linkerOpts, plus the
                // C++ runtime and zlib the static libraries themselves need.
                .linkedFramework("Foundation", .when(platforms: [.iOS])),
                .linkedFramework("Accelerate", .when(platforms: [.iOS])),
                .linkedFramework("CoreML", .when(platforms: [.iOS])),
                .linkedFramework("Security", .when(platforms: [.iOS])),
                .linkedFramework("SystemConfiguration", .when(platforms: [.iOS])),
                .linkedFramework("CFNetwork", .when(platforms: [.iOS])),
                .linkedLibrary("c++", .when(platforms: [.iOS])),
                .linkedLibrary("z", .when(platforms: [.iOS])),
            ]
        ),
        // Vendored apple/coreai-models `CoreAISpeech` (Parakeet TDT on Apple's Core AI runtime),
        // see Sources/CoreAISpeechVendored/VENDORING.md. Not a package dependency: upstream
        // declares iOS 27 as its floor and this kit deploys to 26. The framework only exists in
        // the iOS 27 device SDK and the macOS 27 SDK, so every vendored file is
        // `#if canImport(CoreAI)` and the module is empty on the simulator; the linker weak-links
        // CoreAI on its own because every declaration in it is `@available(iOS 27)`, so no
        // linker flag is needed (and none is allowed: `unsafeFlags` would make the package
        // unusable as a dependency).
        .target(
            name: "CoreAISpeechVendored",
            dependencies: ["CAccelerateBLAS"],
            exclude: ["LICENSE", "VENDORING.md"],
            swiftSettings: swiftSettings
        ),
        // `cblas_sgemv` for the vendored mel front end, in C with ACCELERATE_NEW_LAPACK so the
        // deprecated legacy header is never imported into Swift (see caccelerate_blas.h).
        .target(
            name: "CAccelerateBLAS",
            cSettings: [.define("ACCELERATE_NEW_LAPACK", to: "1")],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(name: "WireProtocol", swiftSettings: swiftSettings),
        // Custom-firmware distribution: the release feed, version ordering, checksum
        // verification and the hand-off record. Depends on nothing else in the kit on purpose —
        // it is reachable from Settings alone and must not be able to disturb the capture path.
        .target(name: "Firmware", swiftSettings: swiftSettings),
        // Meta's Muse gadget protocol (pairing, device API, Noise link, chat turns), ported from
        // the Apache-2.0 Muse Gadget SDK so the phone can act as the watch's Muse gadget.
        // Depends on nothing else in the kit: Foundation + CryptoKit only.
        .target(name: "MuseLink", swiftSettings: swiftSettings),
        .target(name: "SegmentStore", dependencies: ["WireProtocol"], swiftSettings: swiftSettings),
        .target(name: "Receiver", dependencies: ["WireProtocol", "SegmentStore"], swiftSettings: swiftSettings),
        .target(name: "StatusUI", dependencies: ["Receiver", "SegmentStore"], swiftSettings: swiftSettings),
        .target(
            name: "AppDB",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "SegmentStore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Transcription",
            dependencies: [
                "WireProtocol", "SegmentStore", "AudioCodec", "AppDB", "CCactus",
                "CoreAISpeechVendored",
            ],
            swiftSettings: swiftSettings
        ),
        // StatusUI: Ask's per-segment gap note is the SAME status vocabulary the Library row
        // shows, and it used to be a hand-maintained replica of the classifier
        // (`AskGapVisibility`) plus its own raw-milliseconds arithmetic. Same edge, same reason
        // as SearchKit's below — a second copy of "quiet is never loss" drifts silently, and
        // this one already had, telling the model a 2-minute recording was 14 hours missing.
        .target(
            name: "Intelligence",
            dependencies: ["Transcription", "AppDB", "SegmentStore", "StatusUI"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "LiveAudio",
            dependencies: ["SegmentStore", "AudioCodec", "Transcription"],
            swiftSettings: swiftSettings
        ),
        // StatusUI: the transcript renderer's inline quiet/missing markers are the SAME status
        // vocabulary as everywhere else. SearchKit used to keep a private copy of the gap
        // classifier and its copy strings; the two drifted (the copy kept the O(n²) classifier
        // long after StatusUI's was fixed), so there is now one implementation and this edge.
        .target(name: "SearchKit", dependencies: ["AppDB", "StatusUI"], swiftSettings: swiftSettings),
        .target(
            name: "Migration",
            // Intelligence: the legacy `ai/outputs` import reuses `parseGroundedAnswer` to
            // resolve the citations inside historical Ask answers (the same resolution the live
            // Ask path uses) and `askCitations` to number them.
            dependencies: ["SegmentStore", "AppDB", "Transcription", "Intelligence"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CompanionRuntime",
            dependencies: [
                "Receiver", "Transcription", "Intelligence", "LiveAudio", "SearchKit",
                "Migration", "StatusUI", "AppDB", "SegmentStore", "AudioCodec",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WireProtocolTests", dependencies: ["WireProtocol"],
            resources: [.copy("Fixtures")], swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "FirmwareTests", dependencies: ["Firmware"],
            resources: [.copy("Fixtures")], swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MuseLinkTests", dependencies: ["MuseLink"],
            resources: [.copy("Fixtures")], swiftSettings: swiftSettings
        ),
        .testTarget(name: "SegmentStoreTests", dependencies: ["SegmentStore"], swiftSettings: swiftSettings),
        .testTarget(name: "ReceiverTests", dependencies: ["Receiver"], swiftSettings: swiftSettings),
        .testTarget(name: "StatusUITests", dependencies: ["StatusUI"], swiftSettings: swiftSettings),
        .testTarget(name: "AppDBTests", dependencies: ["AppDB"], swiftSettings: swiftSettings),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"], swiftSettings: swiftSettings),
        // Runs the vendored engine against a real exported bundle when `PEBBLE_COREAI_BUNDLE` is
        // set (macOS 27 has Core AI); skips otherwise. Depends on Transcription too, so the same
        // run also drives `CoreAIParakeetEngine` end to end.
        .testTarget(
            name: "CoreAISpeechVendoredTests",
            dependencies: ["CoreAISpeechVendored", "Transcription", "AudioCodec"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AudioCodecTests", dependencies: ["AudioCodec"],
            resources: [.copy("Fixtures")], swiftSettings: swiftSettings
        ),
        .testTarget(name: "IntelligenceTests", dependencies: ["Intelligence"], swiftSettings: swiftSettings),
        .testTarget(name: "LiveAudioTests", dependencies: ["LiveAudio"], swiftSettings: swiftSettings),
        .testTarget(
            name: "SearchKitTests", dependencies: ["SearchKit", "StatusUI"],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "MigrationTests", dependencies: ["Migration"], swiftSettings: swiftSettings),
        .testTarget(
            name: "CompanionRuntimeTests",
            dependencies: [
                "CompanionRuntime", "AppDB", "SegmentStore", "Receiver", "Transcription",
                "Intelligence", "LiveAudio", "SearchKit", "StatusUI", "WireProtocol",
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
