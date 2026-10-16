// swift-tools-version: 6.0
// Developer tools for the Muse gadget integration, macOS only. `muse-dev pair` makes this Mac a
// Muse gadget for one pairing (a stand-in until the watch hosts the setup service); the other
// commands exercise the paired gadget against Muse's cloud. Never shipped.
import PackageDescription

let package = Package(
    name: "MuseDev",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../PebbleAudioKit")],
    targets: [
        .executableTarget(
            name: "muse-dev",
            dependencies: [.product(name: "MuseLink", package: "PebbleAudioKit")],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // A command-line tool that touches Bluetooth needs a usage string, or macOS kills it at
            // the first CoreBluetooth call; embedding an Info.plist in the binary provides one.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", Context.packageDirectory + "/Sources/muse-dev/Info.plist",
                ])
            ]
        )
    ]
)
