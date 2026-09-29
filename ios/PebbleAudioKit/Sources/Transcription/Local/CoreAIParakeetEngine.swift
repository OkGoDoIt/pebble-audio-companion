import Foundation

// The Core AI flavour of the Parakeet engine: the same checkpoint the Cactus engine runs, on
// Apple's Core AI runtime through the vendored `CoreAISpeech` code (see
// Sources/CoreAISpeechVendored/VENDORING.md). One process-wide instance, because the store's
// prepare step and the transcription provider must never hold two copies of a 200–400 MB
// model.
//
// Two bundle kinds come through here, and the adapter tells them apart by their metadata:
//
//   • a `--streaming` export (a `streaming` block in metadata.json): one streaming session per
//     WAV, fed 12-frame slices exactly the way the upstream CLI feeds a file — the ramp-up
//     windows see however much audio has arrived when a hop runs, so the slice size is part of
//     the output — and the finalized segments' 80 ms timestamps come back as `segments`;
//   • a static export (no `streaming` block): the offline `transcribe(pcm:)`, which returns text
//     only, so the response carries a single segment spanning the whole chunk. A static export
//     is traced for one window (45 s for the one in the spike); the provider already caps its
//     chunks at 45 s, and anything longer would be silently truncated by the encoder.
//
// The response is the JSON `ParakeetNativeResponse.parse` already reads; there are no words and
// no speakers (Core AI ships no diarization model).
//
// Everything below the marker is `#if canImport(CoreAI)`: the framework is absent from the
// iPhoneSimulator SDK, so there the factory hands out `UnsupportedParakeetEngine` and the
// provider reports `providerUnavailable`, exactly as it does for a Cactus model on macOS.

/// Which native runtime a Parakeet catalog entry runs on.
public enum LocalEngineRuntime: String, Sendable, Equatable, CaseIterable {
    /// The vendored Cactus binary (`CactusNativeEngine`).
    case cactus
    /// Apple Core AI through `CoreAISpeechVendored` (`CoreAIParakeetEngine`), iOS 27+ device only.
    case coreAI
}

/// Prepares a freshly installed model so its first real use is not a cold start: for Core AI
/// that is the specialization pass (~1.1 GB of cache, seconds on a Mac, longer on a phone) which
/// must happen in the foreground with visible state. A seam so the store's state machine is
/// testable without a bundle.
public protocol ParakeetModelPreparing: Sendable {
    /// Loads the model at `directory` once (and warms its graphs), then drops it. Throws when
    /// this build cannot run that runtime at all.
    func prepare(spec: ParakeetModelSpec, directory: URL) async throws
    /// The model is being uninstalled: drop whatever the runtime built from it outside its
    /// install directory. Core AI's specialization cache is ~1.1 GB that an uninstall otherwise
    /// left behind — and a later re-import could meet the same stale entry it was built from.
    func discardBuiltArtifacts(spec: ParakeetModelSpec, directory: URL) async
}

extension ParakeetModelPreparing {
    public func discardBuiltArtifacts(spec: ParakeetModelSpec, directory: URL) async {}
}

/// Nothing to do — Cactus models are usable the moment they are extracted.
public struct NoModelPreparation: ParakeetModelPreparing {
    public init() {}
    public func prepare(spec: ParakeetModelSpec, directory: URL) async throws {}
}

/// The runtime cannot run here (simulator, macOS host, iOS 26): preparing is refused so the
/// install reports a failure instead of sitting at "finishing up" forever.
public struct UnsupportedModelPreparation: ParakeetModelPreparing {
    public init() {}
    public func prepare(spec: ParakeetModelSpec, directory: URL) async throws {
        throw ParakeetEngineError.unsupportedPlatform
    }
}

extension ParakeetEngineFactory {
    /// True when THIS build, on THIS OS, can run models of `runtime`.
    ///
    /// Core AI needs the framework compiled in (device and macOS SDKs only) AND iOS 27 / macOS 27
    /// at run time; the vendored engine reports the first, `#available` the second.
    public static func isSupported(_ runtime: LocalEngineRuntime) -> Bool {
        switch runtime {
        case .cactus:
            return make().isSupported
        case .coreAI:
            #if canImport(CoreAI) && !targetEnvironment(simulator)
                if #available(iOS 27, macOS 27, *) { return true }
                return false
            #else
                return false
            #endif
        }
    }

    /// The engine for `runtime`: the Cactus engine per call (as `make()` always did), the Core AI
    /// engine as one shared instance, `UnsupportedParakeetEngine` wherever the runtime cannot run.
    public static func make(runtime: LocalEngineRuntime) -> any ParakeetNativeEngine {
        switch runtime {
        case .cactus:
            return make()
        case .coreAI:
            #if canImport(CoreAI) && !targetEnvironment(simulator)
                if #available(iOS 27, macOS 27, *) { return CoreAIParakeetEngine.shared }
                return UnsupportedParakeetEngine()
            #else
                return UnsupportedParakeetEngine()
            #endif
        }
    }

    /// The prepare step the store runs after extracting a model of `runtime`.
    public static func makePreparer(runtime: LocalEngineRuntime) -> any ParakeetModelPreparing {
        switch runtime {
        case .cactus:
            return NoModelPreparation()
        case .coreAI:
            #if canImport(CoreAI) && !targetEnvironment(simulator)
                if #available(iOS 27, macOS 27, *) { return CoreAIModelPreparer() }
                return UnsupportedModelPreparation()
            #else
                return UnsupportedModelPreparation()
            #endif
        }
    }
}

#if canImport(CoreAI)
    import CoreAI
    import CoreAISpeechVendored
    #if os(iOS)
        import os
    #endif

    /// The Core AI engine. See the file comment for the bundle kinds and the JSON it returns.
    ///
    /// `SpeechRecognitionModel` is an actor and serializes its own calls, but a transcription is
    /// a *sequence* of them (`startStream` … `append` … `finishStream`) with suspension points
    /// between, so whole operations are queued through `serial` and cannot interleave.
    /// `interrupt()` never waits on that queue: it cancels the in-flight task and tells the
    /// model to drop its session, which is what makes a cancelled `transcribe` return promptly.
    @available(iOS 27, macOS 27, *)
    public final class CoreAIParakeetEngine: ParakeetNativeEngine, @unchecked Sendable {
        /// The one instance the provider and the store's preparer share. Every graph on Core AI's
        /// default placement — see `decoderOnCPU` for why not the CPU.
        public static let shared = CoreAIParakeetEngine()

        /// Process budget (MB) required to LOAD a model. The first load writes the ~1.1 GB
        /// specialization cache and peaks well above the ~200–400 MB steady-state footprint.
        static let minModelLoadMemoryMb: Int64 = 700
        /// Process budget (MB) required to run one transcription on a loaded model.
        static let minTranscriptionMemoryMb: Int64 = 256

        private let serial = SerialWork()
        private let lock = NSLock()
        private var model: SpeechRecognitionModel?
        private var loadedIdentity: String?
        private var inFlight: Task<String, Error>?
        /// Successful loads so far — see `discardCompiledCache(modelPath:unlessLoadedSince:)`.
        private var generation = 0
        /// Providers between their `load` and their last `transcribe` — see `beginUse()`.
        private var leases = 0
        /// A soft release asked for while the model was busy; honoured when it goes idle.
        private var releaseRequested = false

        /// Runs the TDT decoder's two per-step graphs on the CPU instead of the Neural Engine. A
        /// measured option, OFF in the app.
        ///
        /// The phone transcribes at ~4.3x realtime against ~50x for the same bundle on a Mac, and
        /// its device log shows ~250 Neural Engine requests a second while it does. The tiny
        /// decoder graphs, dispatched per frame/token, looked like the cost. On the CPU they give
        /// byte-identical transcripts (`LocalEngineComparison`, `PEBBLE_COREAI_DECODER_CPU`: 3
        /// segments / 40 min, 0.0% difference, 5–23% faster on the Mac) — but on the phone
        /// (2026-09-30, "900 s of audio in 206.3 s (4.4x realtime)") no faster, with requests
        /// down only to ~150/s: the streaming encoder's own programs set the pace, and the first
        /// load paid ~6 min of CPU specialization for nothing. Kept for the measurement.
        private let decoderOnCPU: Bool

        public init(decoderOnCPU: Bool = false) {
            self.decoderOnCPU = decoderOnCPU
        }

        /// Where the decoder's per-step graphs are specialized. The encoder always takes Core AI's
        /// default (the Neural Engine).
        var decoderOptions: SpecializationOptions { decoderOnCPU ? .cpuOnly : .default }

        public var isSupported: Bool {
            #if targetEnvironment(simulator)
                return false
            #else
                return true
            #endif
        }

        /// The identity of the resident model, nil when none is loaded.
        public var loadedModelIdentity: String? { lock.withLock { loadedIdentity } }

        public var loadGeneration: Int { lock.withLock { generation } }

        public func load(modelPath: String, identity: String) async throws {
            if lock.withLock({ model != nil && loadedIdentity == identity }) { return }
            try Self.requireLoadMemory()
            let url = URL(fileURLWithPath: modelPath, isDirectory: true)
            try await serial.run { [self] in
                _ = try await loadOnQueue(url: url, identity: identity)
            }
        }

        /// `load`, then one pass through every graph so the specialization cache is complete —
        /// as ONE operation on the queue, so nothing (a release, another caller) can drop the
        /// model between the two halves. They used to be two, and a release that landed between
        /// them failed the pass with "no model loaded" (2026-09-29 23:12). Returns true when this
        /// call is the one that loaded the model, so the preparer only lets go of what it took.
        @discardableResult
        public func prepare(modelPath: String, identity: String) async throws -> Bool {
            if !lock.withLock({ model != nil && loadedIdentity == identity }) {
                try Self.requireLoadMemory()
            }
            let url = URL(fileURLWithPath: modelPath, isDirectory: true)
            return try await serial.run { [self] in
                let loadedHere = try await loadOnQueue(url: url, identity: identity)
                guard let model = lock.withLock({ self.model }) else {
                    throw ParakeetEngineError.notLoaded
                }
                let samples: Int
                if let streaming = await model.bundleStreamingConfig {
                    samples = streaming.windowSampleCount
                } else {
                    let mel = await model.melConfig
                    samples = (mel.nFrames ?? 3_000) * mel.hopLength
                }
                do {
                    try await model.prewarm(sampleCount: samples)
                } catch {
                    throw ParakeetEngineError.modelLoadFailed(Self.describe(error))
                }
                return loadedHere
            }
        }

        /// The load itself. Only ever called on `serial`. Re-checks there, because a queued
        /// duplicate must not reload a model the call ahead of it just finished loading.
        private func loadOnQueue(url: URL, identity: String) async throws -> Bool {
            if lock.withLock({ model != nil && loadedIdentity == identity }) { return false }
            dropModel()
            let loaded: SpeechRecognitionModel
            do {
                loaded = try await SpeechRecognitionModel(
                    resourcesAt: url, decoderOptions: decoderOptions)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ParakeetEngineError.modelLoadFailed(Self.describe(error))
            }
            lock.withLock {
                model = loaded
                loadedIdentity = identity
                generation += 1
                releaseRequested = false
            }
            return true
        }

        public func transcribe(wavPath: String) async throws -> String {
            let available = Self.availableMemoryMb()
            guard available >= Self.minTranscriptionMemoryMb else {
                throw ParakeetEngineError.insufficientMemory(
                    availableMb: available, requiredMb: Self.minTranscriptionMemoryMb
                )
            }
            guard let model = lock.withLock({ self.model }) else {
                throw ParakeetEngineError.notLoaded
            }
            let task = Task<String, Error> { [serial] in
                try await serial.run { try await Self.run(model: model, wavPath: wavPath) }
            }
            lock.withLock { inFlight = task }
            defer {
                lock.withLock { if inFlight == task { inFlight = nil } }
                releaseIfRequestedAndIdle()
            }
            return try await withTaskCancellationHandler {
                let text = try await task.value
                // A cancelled run can still finish "normally" with whatever its stream finalized
                // before the cancel landed — often nothing. That is not a transcript of the file,
                // and an empty one reads as silence to everything above.
                if task.isCancelled { throw CancellationError() }
                return text
            } onCancel: {
                task.cancel()
                cancelStream(of: model, ifStillRunning: task)
            }
        }

        public func interrupt() {
            let (task, model) = lock.withLock { (inFlight, self.model) }
            task?.cancel()
            if let task, let model { cancelStream(of: model, ifStillRunning: task) }
        }

        /// Drops `model`'s streaming session — but only if `task` is still the transcription in
        /// flight when the hop to the model actor actually runs. The cancel is necessarily
        /// out of band (it must not wait on `serial`), so it can land late; unguarded, a late one
        /// abandoned the NEXT segment's session, whose own, uncancelled caller then saw a
        /// `CancellationError` it never asked for.
        private func cancelStream(of model: SpeechRecognitionModel, ifStillRunning task: Task<String, Error>) {
            Task { [weak self] in
                guard let self, self.lock.withLock({ self.inFlight == task }) else { return }
                await model.cancelStream()
            }
        }

        /// The hard release, for a memory warning: interrupt, wait, drop — leases or not.
        public func release() async {
            interrupt()
            await serial.drain()
            dropModel()
        }

        /// The soft release, for the app leaving the foreground: nothing is interrupted and the
        /// caller does not wait. The model goes once no transcription is running and no provider
        /// holds a lease; a load in the meantime cancels the request (the work that loaded it
        /// wants it).
        public func releaseWhenIdle() async {
            lock.withLock { releaseRequested = true }
            releaseIfRequestedAndIdle()
        }

        public func beginUse() {
            lock.withLock { leases += 1 }
        }

        public func endUse() {
            lock.withLock { leases = max(0, leases - 1) }
            releaseIfRequestedAndIdle()
        }

        /// Queues the drop behind whatever is running, re-checking there: the request, the leases
        /// and the in-flight task can all have changed by the time the queue gets to it.
        private func releaseIfRequestedAndIdle() {
            guard lock.withLock({ releaseRequested && leases == 0 && inFlight == nil }) else {
                return
            }
            Task { [self] in
                try? await serial.run { [self] in
                    let drop = lock.withLock { () -> Bool in
                        guard releaseRequested, leases == 0, inFlight == nil else { return false }
                        releaseRequested = false
                        return true
                    }
                    if drop { dropModel() }
                }
            }
        }

        /// Deletes this app's Core AI specialization cache, so the next `load` specializes the
        /// bundle afresh (a cold load: ~1.1 GB of cache written, the same pass the store's
        /// preparer runs after an install) — unless a load has succeeded since `generation`, in
        /// which case someone else already recovered the model and the cache is good.
        ///
        /// Why this exists (2026-09-29): Core AI keeps the specialized model in the app's
        /// `Library/Caches/coreai-cache`, and that entry points at Neural Engine programs held in
        /// a SYSTEM cache (`com.apple.aned/…/ModelAssetsCache`). iOS evicted one of those programs
        /// on the user's phone. Core AI still reported "received a model already specialized in
        /// the cache", `aned` then failed `open(…) errno=2` on the missing program, and
        /// `loadFunction` threw — on every load, for ten days, because nothing ever invalidated
        /// the app-side entry. Deleting it is the only way back that does not need a reinstall.
        ///
        /// `deleteAll`, not `deleteEntries(for:)` per graph: this app specializes exactly one
        /// bundle, and a per-entry delete that missed one graph would leave the same dead
        /// reference behind. Serialized behind any in-flight operation, and the model is dropped
        /// first so nothing resident still refers to the entries being deleted.
        public func discardCompiledCache(modelPath: String, unlessLoadedSince since: Int) async
            -> ParakeetCacheDiscard
        {
            let outcome: ParakeetCacheDiscard? = try? await serial.run { [self] in
                if lock.withLock({ generation != since }) { return .loadedSince }
                dropModel()
                do {
                    try AIModelCache.default.deleteAll()
                    return .discarded
                } catch {
                    return .nothingToDiscard
                }
            }
            return outcome ?? .nothingToDiscard
        }

        /// Drops the model unless it is in use right now. The store's preparer calls this rather
        /// than `release()`, and only for a model it loaded itself: the pipeline may have started
        /// on the same shared model, and yanking it would fail that segment.
        public func releaseUnlessBusy() async {
            try? await serial.run { [self] in
                guard lock.withLock({ inFlight == nil && leases == 0 }) else { return }
                dropModel()
            }
        }

        private static func requireLoadMemory() throws {
            let available = availableMemoryMb()
            guard available >= minModelLoadMemoryMb else {
                throw ParakeetEngineError.insufficientMemory(
                    availableMb: available, requiredMb: minModelLoadMemoryMb
                )
            }
        }

        // MARK: - The transcription itself

        private static func run(model: SpeechRecognitionModel, wavPath: String) async throws
            -> String
        {
            let sampleRate = await model.sampleRate
            let pcm: [Float]
            do {
                // The same reader the upstream CLI used, so the samples are bit-identical to
                // what the parity fixtures were produced from (a canonical s16le WAV takes its
                // no-conversion fast path).
                pcm = try MelSpectrogram.loadAndResample(
                    URL(fileURLWithPath: wavPath), targetSampleRate: sampleRate
                )
            } catch {
                throw ParakeetEngineError.nativeFailure("could not read audio: \(describe(error))")
            }
            try Task.checkCancellation()
            let segments: [ResponseSegment]
            if await model.bundleStreamingConfig != nil {
                segments = try await stream(model: model, pcm: pcm)
            } else {
                segments = try await offline(model: model, pcm: pcm, sampleRate: sampleRate)
            }
            return encode(segments)
        }

        struct ResponseSegment: Equatable {
            var start: Double
            var end: Double
            var text: String
        }

        /// The offline path: text only, so one segment spanning the chunk.
        private static func offline(
            model: SpeechRecognitionModel, pcm: [Float], sampleRate: Double
        ) async throws -> [ResponseSegment] {
            let text: String
            do {
                (text, _) = try await model.transcribe(pcm: pcm)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ParakeetEngineError.nativeFailure(describe(error))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [
                ResponseSegment(
                    start: 0, end: Double(pcm.count) / sampleRate, text: trimmed
                )
            ]
        }

        /// The streaming path, fed exactly as the upstream CLI feeds a file.
        private static func stream(model: SpeechRecognitionModel, pcm: [Float]) async throws
            -> [ResponseSegment]
        {
            let updates: AsyncThrowingStream<TranscriptionUpdate, Error>
            let config: StreamingConfig
            do {
                updates = try await model.startStream()
                guard let active = await model.activeStreamingConfig else {
                    throw SpeechError.invalidStreamingConfig("no active streaming geometry")
                }
                config = active
            } catch {
                throw ParakeetEngineError.nativeFailure(describe(error))
            }
            let collector = Task<[ResponseSegment], Error> {
                var finals: [ResponseSegment] = []
                for try await update in updates {
                    if case .finalized(let segment) = update {
                        finals.append(
                            ResponseSegment(
                                start: segment.startTime, end: segment.endTime, text: segment.text
                            )
                        )
                    }
                }
                return finals
            }
            let pushSize = config.chunkFrames * config.samplesPerEncoderFrame
            var offset = 0
            do {
                while offset < pcm.count {
                    try Task.checkCancellation()
                    let end = min(offset + pushSize, pcm.count)
                    try await model.append(pcm: Array(pcm[offset..<end]))
                    offset = end
                }
                try Task.checkCancellation()
                _ = try await model.finishStream()
            } catch {
                // Whatever went wrong, the session must not outlive this call: the next
                // `startStream` would otherwise refuse with "a stream is already running".
                await model.cancelStream()
                collector.cancel()
                _ = try? await collector.value
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw ParakeetEngineError.nativeFailure(describe(error))
            }
            do {
                return try await collector.value
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw ParakeetEngineError.nativeFailure(describe(error))
            }
        }

        /// `{"text": …, "segments": [{"start", "end", "text"}]}` — seconds, as the provider parses.
        static func encode(_ segments: [ResponseSegment]) -> String {
            let text = segments.map(\.text).joined(separator: " ")
            let payload: [String: Any] = [
                "text": text,
                "segments": segments.map {
                    ["start": $0.start, "end": $0.end, "text": $0.text] as [String: Any]
                },
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                let json = String(data: data, encoding: .utf8)
            else { return #"{"text":""}"# }
            return json
        }

        // MARK: - Plumbing

        private func dropModel() {
            lock.withLock {
                model = nil
                loadedIdentity = nil
            }
        }

        /// `SpeechError` and `ModelBundle.BundleError` describe themselves; anything else is
        /// whatever Swift prints for it.
        private static func describe(_ error: Error) -> String {
            String(describing: error)
        }

        /// Memory this PROCESS may still allocate before iOS jetsams it. 0 (or a host without the
        /// call) means "unavailable in this context" — treated as plenty, never as a block.
        private static func availableMemoryMb() -> Int64 {
            #if os(iOS)
                let bytes = os_proc_available_memory()
                guard bytes > 0 else { return .max }
                return Int64(bytes) / (1024 * 1024)
            #else
                return .max
            #endif
        }
    }

    /// The store's prepare step for Core AI models: load + warm through the shared engine,
    /// then release so a model the user merely installed is not left resident.
    @available(iOS 27, macOS 27, *)
    public struct CoreAIModelPreparer: ParakeetModelPreparing {
        public init() {}

        public func prepare(spec: ParakeetModelSpec, directory: URL) async throws {
            let engine = CoreAIParakeetEngine.shared
            let generation = engine.loadGeneration
            let loadedHere: Bool
            do {
                loadedHere = try await engine.prepare(
                    modelPath: directory.path, identity: spec.modelUsed)
            } catch ParakeetEngineError.modelLoadFailed {
                // The same stale-cache case the provider recovers from (see
                // `CoreAIParakeetEngine.discardCompiledCache`): a re-prepare after the model was
                // withdrawn, or a re-import after an uninstall, can meet the same dead entry. One
                // discard, one retry; a second failure is a real one and is reported.
                guard
                    await engine.discardCompiledCache(
                        modelPath: directory.path, unlessLoadedSince: generation) != .nothingToDiscard
                else { throw ParakeetEngineError.modelLoadFailed("the model could not be loaded") }
                loadedHere = try await engine.prepare(
                    modelPath: directory.path, identity: spec.modelUsed)
            }
            // Only let go of a model this pass loaded: one a transcription loaded is its business.
            if loadedHere { await engine.releaseUnlessBusy() }
        }

        public func discardBuiltArtifacts(spec: ParakeetModelSpec, directory: URL) async {
            let engine = CoreAIParakeetEngine.shared
            _ = await engine.discardCompiledCache(
                modelPath: directory.path, unlessLoadedSince: engine.loadGeneration)
        }
    }

    /// FIFO for whole engine operations. Each `run` waits for the operation before it, so two
    /// transcriptions (or a load and a transcription) never interleave their actor calls.
    private actor SerialWork {
        private var tail: Task<Void, Never>?

        func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
            let previous = tail
            let task = Task<T, Error> {
                await previous?.value
                return try await body()
            }
            tail = Task { _ = try? await task.value }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        /// Waits for everything queued so far to finish.
        func drain() async {
            await tail?.value
        }
    }
#endif
