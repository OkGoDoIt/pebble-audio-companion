import Foundation
import Testing

@testable import Transcription

// iOS has no public unzip API, so the model archives are unpacked by our own minimal ZIP
// reader. These tests round-trip a real archive (built with /usr/bin/zip, so the bytes are
// produced by something other than the code under test) and pin the path-traversal guard.

private func makeTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parakeet-zip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ParakeetArchiveTests {
    @Test func extractsStoredAndDeflatedEntriesFromARealArchive() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else { return }
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("weights"), withIntermediateDirectories: true
        )
        // Highly compressible (deflated) and incompressible (likely stored) payloads.
        let config = String(repeating: "parakeet-tdt-0.6b-v3\n", count: 4_000)
        try Data(config.utf8).write(to: source.appendingPathComponent("config.txt"))
        let random = Data((0..<64_000).map { _ in UInt8.random(in: 0...255) })
        try random.write(to: source.appendingPathComponent("weights/tensors.bin"))

        let archive = root.appendingPathComponent("model.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", archive.path, "."]
        zip.currentDirectoryURL = source
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)

        let destination = root.appendingPathComponent("installed", isDirectory: true)
        try ZipArchive.extract(archiveAt: archive, into: destination)

        #expect(
            try Data(contentsOf: destination.appendingPathComponent("config.txt"))
                == Data(config.utf8)
        )
        #expect(
            try Data(contentsOf: destination.appendingPathComponent("weights/tensors.bin"))
                == random
        )
    }

    @Test func rejectsEntriesThatEscapeTheDestination() throws {
        let root = URL(fileURLWithPath: "/tmp/models/parakeet", isDirectory: true)
        for name in ["../evil.bin", "weights/../../evil.bin", "/etc/passwd", "", "~/evil"] {
            #expect(throws: ZipExtractionError.self) {
                _ = try ZipArchive.safeDestination(root: root, entryName: name)
            }
        }
        #expect(
            try ZipArchive.safeDestination(root: root, entryName: "weights/a.bin").path
                == "/tmp/models/parakeet/weights/a.bin"
        )
        // A directory entry keeps its identity minus the trailing slash.
        #expect(
            try ZipArchive.safeDestination(root: root, entryName: "weights/").lastPathComponent
                == "weights"
        )
    }

    @Test func nonArchiveBytesAreRejected() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let bogus = root.appendingPathComponent("not-a-zip.bin")
        try Data(repeating: 7, count: 4_096).write(to: bogus)
        #expect(throws: ZipExtractionError.notAZipArchive) {
            try ZipArchive.extract(archiveAt: bogus, into: root.appendingPathComponent("out"))
        }
    }
}
