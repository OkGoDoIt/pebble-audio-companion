// swift-tools-version: 6.0
// archive-import seeds the Pebble Audio server from one of the phone's Desktop backups. It builds
// every payload with the iOS app's own export code (`CompanionRuntime/ArchiveSync`), so the server
// receives exactly what the phone would send. macOS only. Never shipped.
import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "ArchiveImport",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../../PebbleAudioKit"),
        // The kit's own pin; named here because the import reads the database through it.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "ArchiveImportCore",
            dependencies: [
                .product(name: "PebbleAudioKit", package: "PebbleAudioKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "archive-import",
            dependencies: [
                "ArchiveImportCore",
                .product(name: "PebbleAudioKit", package: "PebbleAudioKit"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ArchiveImportTests",
            dependencies: [
                "ArchiveImportCore",
                .product(name: "PebbleAudioKit", package: "PebbleAudioKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
