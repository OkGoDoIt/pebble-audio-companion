// swift-tools-version: 6.0
// PebbleAudioKit — the no-UI core of the native iOS rebuild.
// Module boundaries mirror the implementation plan (Part 3): the KMP modules and their
// test suites are the behavioral spec; spec/fixtures are the wire contract.
import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "PebbleAudioKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(
            name: "PebbleAudioKit",
            targets: [
                "WireProtocol", "SegmentStore", "Receiver", "StatusUI", "AppDB",
                "Transcription", "Intelligence", "LiveAudio", "SearchKit", "Migration",
                "CompanionRuntime", "AudioCodec",
            ]
        ),
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
        .target(name: "WireProtocol", swiftSettings: swiftSettings),
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
            dependencies: ["WireProtocol", "SegmentStore", "AudioCodec", "AppDB", "CCactus"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Intelligence",
            dependencies: ["Transcription", "AppDB", "SegmentStore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "LiveAudio",
            dependencies: ["SegmentStore", "AudioCodec", "Transcription"],
            swiftSettings: swiftSettings
        ),
        .target(name: "SearchKit", dependencies: ["AppDB"], swiftSettings: swiftSettings),
        .target(
            name: "Migration",
            dependencies: ["SegmentStore", "AppDB", "Transcription"],
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
        .testTarget(name: "SegmentStoreTests", dependencies: ["SegmentStore"], swiftSettings: swiftSettings),
        .testTarget(name: "ReceiverTests", dependencies: ["Receiver"], swiftSettings: swiftSettings),
        .testTarget(name: "StatusUITests", dependencies: ["StatusUI"], swiftSettings: swiftSettings),
        .testTarget(name: "AppDBTests", dependencies: ["AppDB"], swiftSettings: swiftSettings),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"], swiftSettings: swiftSettings),
        .testTarget(
            name: "AudioCodecTests", dependencies: ["AudioCodec"],
            resources: [.copy("Fixtures")], swiftSettings: swiftSettings
        ),
        .testTarget(name: "IntelligenceTests", dependencies: ["Intelligence"], swiftSettings: swiftSettings),
        .testTarget(name: "LiveAudioTests", dependencies: ["LiveAudio"], swiftSettings: swiftSettings),
        .testTarget(name: "SearchKitTests", dependencies: ["SearchKit"], swiftSettings: swiftSettings),
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
