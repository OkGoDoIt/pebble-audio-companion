import Foundation

#if os(iOS)
    import CCactus
    import os
#endif

// Swift port of the Cactus call sequence in `cactus/src/iosMain/kotlin/com/cactus/Cactus.kt`:
// `cactus_init` → `cactus_transcribe` (fixed 64 KiB response buffer, negative return means
// failure and `cactus_get_last_error()` carries the message) → `cactus_destroy`, with
// `cactus_stop` as the out-of-band interrupt.
//
// The implementations live in the iOS-only `CactusBinary` xcframework, so the whole native
// engine is `#if os(iOS)`; `swift test` (macOS) sees only the seam and its fakes.
//
// The same seam has a second implementation since the iOS 27 build-out: `CoreAIParakeetEngine`
// (its own file), which runs the Core AI export of the same checkpoint. `ParakeetEngineFactory
// .make(runtime:)` picks by `ParakeetModelSpec.runtime`; the plain `make()` below is still the
// Cactus engine.

// NOT ported: a streaming (`StreamingTranscriptionProvider`) flavor over
// `cactus_stream_transcribe_start/process/stop`. The header does not say whether the JSON each
// `process` call returns is the transcript so far or only the newest words, nothing in the KMP
// app ever called those functions, and guessing wrong produces a live transcript that either
// duplicates or drops text. The live path runs on SpeechAnalyzer, which is on-device already,
// so there is nothing to gain from a guess. Revisit with real device output to read from.

public enum ParakeetEngineError: Error, Equatable, Sendable {
    /// No engine for this runtime on this platform (no Cactus binary on macOS host builds and
    /// previews; no Core AI below iOS 27 or on a simulator).
    case unsupportedPlatform
    case modelLoadFailed(String)
    case nativeFailure(String)
    /// This process's remaining jetsam budget is too small to load/run the model right now.
    case insufficientMemory(availableMb: Int64, requiredMb: Int64)
}

/// The native speech-to-text engine behind `ParakeetTranscriptionProvider`. A protocol so the
/// provider's audio handling and error mapping are testable without the 700 MB model.
public protocol ParakeetNativeEngine: Sendable {
    /// False when this build cannot run the engine here (no Cactus binary linked, no Core AI
    /// framework) — the provider then reports `providerUnavailable`.
    var isSupported: Bool { get }

    /// Loads the model at `path` (a no-op when `identity` matches the loaded one).
    func load(modelPath: String, identity: String) async throws

    /// Transcribes one whole WAV file, returning the raw native JSON response.
    func transcribe(wavPath: String) async throws -> String

    /// Interrupts an in-flight `transcribe` (`cactus_stop`). Must be callable while a
    /// transcription is running, so it never waits on the engine's serial queue.
    func interrupt()

    /// Unloads the model and frees its memory.
    func release() async

    /// Throws away whatever the runtime compiled from the model at `modelPath` and cached outside
    /// the install directory, so the next `load` rebuilds it from the model files. Returns true
    /// when there was such a cache and it was dropped.
    ///
    /// Core AI needs this; Cactus has nothing of the kind (its install directory is all there is).
    /// See `ParakeetTranscriptionProvider.loadEngine` for when it is called.
    func discardCompiledCache(modelPath: String) async -> Bool
}

extension ParakeetNativeEngine {
    public func discardCompiledCache(modelPath: String) async -> Bool { false }
}

/// Engine used where the runtime cannot run (no Cactus slice, no Core AI).
public struct UnsupportedParakeetEngine: ParakeetNativeEngine {
    public init() {}
    public var isSupported: Bool { false }
    public func load(modelPath: String, identity: String) async throws {
        throw ParakeetEngineError.unsupportedPlatform
    }
    public func transcribe(wavPath: String) async throws -> String {
        throw ParakeetEngineError.unsupportedPlatform
    }
    public func interrupt() {}
    public func release() async {}
}

/// The engines the app runs with: `UnsupportedParakeetEngine` wherever a runtime cannot run.
/// `make()` is the Cactus engine; `make(runtime:)` (CoreAIParakeetEngine.swift) covers both.
public enum ParakeetEngineFactory {
    public static func make() -> any ParakeetNativeEngine {
        #if os(iOS)
            return CactusNativeEngine()
        #else
            return UnsupportedParakeetEngine()
        #endif
    }
}

#if os(iOS)
    /// Live Cactus engine. The native calls block, so they run on a dedicated serial queue —
    /// which also serializes model use, the role `CactusLocalTranscriptionProvider`'s mutex
    /// played. `interrupt()` deliberately does NOT use that queue: `cactus_stop` must reach a
    /// transcription that is currently running on it.
    public final class CactusNativeEngine: ParakeetNativeEngine, @unchecked Sendable {
        /// Same 64 KiB response buffer the Kotlin wrapper allocated.
        private static let responseBufferBytes = 65_536
        /// Process budget (MB) required to LOAD a model — loading needs headroom steady-state
        /// inference does not (`CactusPlatform.ios.kt`).
        private static let minModelInitMemoryMb: Int64 = 150
        /// Process budget (MB) required to run one transcription.
        private static let minTranscriptionMemoryMb: Int64 = 96

        private let queue = DispatchQueue(
            label: "dev.audiocompanion.parakeet.engine", qos: .userInitiated
        )
        private let lock = NSLock()
        private var handle: UnsafeMutableRawPointer?
        private var loadedIdentity: String?

        public init() {}

        public var isSupported: Bool { true }

        public func load(modelPath: String, identity: String) async throws {
            if currentIdentity() == identity, currentHandle() != nil { return }
            let available = Self.availableMemoryMb()
            guard available >= Self.minModelInitMemoryMb else {
                throw ParakeetEngineError.insufficientMemory(
                    availableMb: available, requiredMb: Self.minModelInitMemoryMb
                )
            }
            try await onQueue {
                self.destroyLocked()
                // Before `cactus_init`, every time — telemetry is initialized from inside it, so
                // afterwards is too late for the very first event. The work happens once; this is
                // sited at the call rather than at an app-start hook so no later reordering can
                // separate the two. See `CactusPrivacyConfiguration`.
                CactusPrivacyConfiguration.configure()
                guard let loaded = cactus_init(modelPath, nil, false) else {
                    throw ParakeetEngineError.modelLoadFailed(Self.lastError())
                }
                // Belt and braces to the environment switch: stop the dispatcher so nothing is
                // collected or queued for a later flush. After EVERY successful init, because a
                // re-init starts a new subsystem.
                cactus_telemetry_shutdown()
                self.lock.lock()
                self.handle = loaded
                self.loadedIdentity = identity
                self.lock.unlock()
            }
        }

        public func transcribe(wavPath: String) async throws -> String {
            let available = Self.availableMemoryMb()
            guard available >= Self.minTranscriptionMemoryMb else {
                throw ParakeetEngineError.insufficientMemory(
                    availableMb: available, requiredMb: Self.minTranscriptionMemoryMb
                )
            }
            return try await onQueue {
                guard let handle = self.currentHandle() else {
                    throw ParakeetEngineError.modelLoadFailed("no model loaded")
                }
                var buffer = [CChar](repeating: 0, count: Self.responseBufferBytes)
                let status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    cactus_transcribe(
                        handle,
                        wavPath,
                        nil,
                        out.baseAddress,
                        Self.responseBufferBytes,
                        nil,
                        nil,
                        nil,
                        nil,
                        0
                    )
                }
                guard status >= 0 else { throw ParakeetEngineError.nativeFailure(Self.lastError()) }
                // The C side NUL-terminates inside the buffer; decode up to that byte.
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }

        public func interrupt() {
            guard let handle = currentHandle() else { return }
            cactus_stop(handle)
        }

        public func release() async {
            interrupt()
            try? await onQueue { self.destroyLocked() }
        }

        // MARK: - Plumbing

        private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        continuation.resume(returning: try body())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func currentHandle() -> UnsafeMutableRawPointer? {
            lock.lock()
            defer { lock.unlock() }
            return handle
        }

        private func currentIdentity() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return loadedIdentity
        }

        private func destroyLocked() {
            lock.lock()
            let existing = handle
            handle = nil
            loadedIdentity = nil
            lock.unlock()
            if let existing { cactus_destroy(existing) }
        }

        private static func lastError() -> String {
            guard let message = cactus_get_last_error() else { return "Unknown Cactus error" }
            let text = String(cString: message)
            return text.isEmpty ? "Unknown Cactus error" : text
        }

        /// Memory this PROCESS may still allocate before iOS jetsams it. 0 means "unavailable
        /// in this context" (simulator, extensions) — treated as plenty, never as a block.
        private static func availableMemoryMb() -> Int64 {
            let bytes = os_proc_available_memory()
            guard bytes > 0 else { return .max }
            return Int64(bytes) / (1024 * 1024)
        }
    }
#endif
