import CryptoKit
import Foundation
import Testing

@testable import Firmware

// The staging invariant, which is the whole safety story of this feature:
// **a file in the staging directory has passed verification, or it is not there.**

@Suite("Firmware download verification")
struct FirmwareVerificationTests {

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    private func release(
        sha256: String,
        sizeBytes: Int64? = nil,
        version: String = "4.36.1"
    ) throws -> FirmwareRelease {
        FirmwareRelease(
            version: try #require(FirmwareVersion(version)),
            board: .pebbleTime2,
            assetURL: URL(string: "https://example.invalid/fw.pbz")!,
            sizeBytes: sizeBytes,
            sha256: sha256
        )
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("The hash matches CryptoKit over the same bytes, including across chunk boundaries")
    func hashesCorrectly() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for size in [0, 1, 1024, (1 << 20) - 1, (1 << 20), (1 << 20) + 7] {
            let bytes = Data((0..<size).map { UInt8($0 % 251) })
            let file = try write(bytes, named: "blob-\(size).bin", in: directory)
            // A small chunk size forces many update() calls even for the small inputs, which is
            // where a streaming hash usually breaks.
            let streamed = try FirmwareChecksum.sha256Hex(ofFileAt: file, chunkSize: 997)
            #expect(streamed == hex(bytes), "size \(size)")
        }
    }

    @Test("A matching download verifies and is left in place")
    func verifiesGoodDownload() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("a plausible pbz".utf8)
        let file = try write(bytes, named: "fw.pbz", in: directory)

        try FirmwareChecksum.verify(
            fileAt: file,
            matches: try release(sha256: hex(bytes), sizeBytes: Int64(bytes.count))
        )
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A single flipped bit fails, and the file is deleted")
    func rejectsTamperedDownload() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = Data("the firmware that was published".utf8)
        let actual = Data("the firmware that was published!".utf8)
        let file = try write(actual, named: "fw.pbz", in: directory)

        #expect(throws: FirmwareDownloadError.self) {
            try FirmwareChecksum.verify(fileAt: file, matches: try release(sha256: hex(expected)))
        }
        // The delete is the invariant: an unverified .pbz left in staging is one stray tap from
        // being flashed, and the Open In menu cannot tell the two apart.
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("An error page served with a 200 fails on size before it is even hashed")
    func rejectsSizeMismatch() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("<html>404 Not Found</html>".utf8)
        let file = try write(bytes, named: "fw.pbz", in: directory)

        var thrown: FirmwareDownloadError?
        do {
            try FirmwareChecksum.verify(
                fileAt: file, matches: try release(sha256: hex(bytes), sizeBytes: 1_245_184)
            )
        } catch let error as FirmwareDownloadError {
            thrown = error
        }
        #expect(thrown == .sizeMismatch(expected: 1_245_184, actual: Int64(bytes.count)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("An empty file does not slip through as 'nothing to check'")
    func rejectsEmptyFile() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try write(Data(), named: "fw.pbz", in: directory)

        #expect(throws: FirmwareDownloadError.self) {
            try FirmwareChecksum.verify(
                fileAt: file, matches: try release(sha256: String(repeating: "a", count: 64))
            )
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Staging keeps at most the current release and names it .pbz")
    func stagingHousekeeping() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = FirmwareStagingArea(directory: directory)
        try staging.prepare()

        let old = try release(sha256: String(repeating: "a", count: 64), version: "4.35.0")
        let new = try release(sha256: String(repeating: "b", count: 64), version: "4.36.1")
        _ = try write(Data("old".utf8), named: old.suggestedFileName, in: directory)
        _ = try write(Data("new".utf8), named: new.suggestedFileName, in: directory)

        #expect(staging.location(for: new).lastPathComponent.hasSuffix(".pbz"))
        #expect(staging.existingDownload(for: old) != nil)

        staging.removeAll(except: new)
        #expect(staging.existingDownload(for: old) == nil)
        #expect(staging.existingDownload(for: new) != nil)

        staging.removeAll(except: nil)
        #expect(staging.existingDownload(for: new) == nil)
    }
}
