import Foundation

@testable import Transcription

// Shared helpers for the Transcription test suites (ports of the fixtures embedded in the KMP
// test files under `core/transcription/src/*Test/`).

/// Mutable wall clock injected into queue/stores; each test drives it explicitly (the Kotlin
/// tests' `private var clock` field).
final class ClockBox: @unchecked Sendable {
    var now: Int64
    init(_ now: Int64) { self.now = now }

    /// Kotlin `{ clock++ }`: returns the current value, then advances by one.
    func postIncrement() -> Int64 {
        defer { now += 1 }
        return now
    }
}

func makeTempRoot(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A finished single-use PCM chunk stream (the Kotlin tests' `flowOf(...)`).
func pcmStream(_ chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }
}

/// Port of the JVM tests' `AssertionError("...")` — a non-TranscriptionError failure crossing
/// the provider boundary.
struct AssertionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension CloudConnectivityResult {
    var isOk: Bool {
        if case .ok = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
