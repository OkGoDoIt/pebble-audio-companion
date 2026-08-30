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
        .target(name: "CSpeex"),
        .target(name: "AudioCodec", dependencies: ["CSpeex"], swiftSettings: swiftSettings),
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
            dependencies: ["WireProtocol", "SegmentStore", "AudioCodec", "AppDB"],
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
                "Migration", "StatusUI",
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
        .testTarget(name: "CompanionRuntimeTests", dependencies: ["CompanionRuntime"], swiftSettings: swiftSettings),
    ]
)
