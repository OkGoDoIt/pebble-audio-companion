import Foundation

// Shared helpers for the SegmentStore test suites (ports of the fixtures embedded in
// `core/storage/src/jvmTest/.../SegmentStoreTest.kt` and `RetentionManagerTest.kt`).

/// Mutable wall clock injected into the store; each test drives it explicitly.
final class ClockBox: @unchecked Sendable {
    var now: Int64
    init(_ now: Int64) { self.now = now }
}

/// Captures the store's log lines (the Kotlin tests passed `logged::add`).
final class LogBox: @unchecked Sendable {
    var lines: [String] = []
}

func makeTempRoot(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func appendBytes(_ bytes: [UInt8], to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(bytes))
    try handle.close()
}
