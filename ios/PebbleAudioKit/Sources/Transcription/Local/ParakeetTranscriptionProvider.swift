import AudioCodec
import Foundation

// Port of `core/transcription/.../CactusLocalTranscriptionProvider.kt`, the batch flavor: the
// PCM stream is spooled to a raw temp file, split into speech ranges (so long silences are not
// paid for and no single native call exceeds 45 s), and each range handed to the native engine
// as a WAV file. Everything about audio handling, thresholds and no-speech detection is carried
// across unchanged; only the FFI plumbing is new.

struct PcmSpeechRange: Equatable, Sendable {
    var startByte: Int
    var endByte: Int

    var byteLength: Int { endByte - startByte }

    func startMs(sampleRateHz: Int) -> Int64 {
        Int64(startByte / 2) * 1_000 / Int64(sampleRateHz)
    }

    func endMs(sampleRateHz: Int) -> Int64 {
        Int64(endByte / 2) * 1_000 / Int64(sampleRateHz)
    }
}

/// Pure PCM helpers — the RMS/peak voice test and range arithmetic, hermetically testable.
enum ParakeetPcm {
    static let bytesPerSample = 2
    static let minAudioBytes = 3_200
    static let analysisWindowMs = 100
    static let minSpeechRangeMs = 400
    static let speechPrerollMs = 450
    static let speechPostrollMs = 700
    static let mergeSpeechGapMs = 1_500
    static let maxTranscribeChunkMs = 45_000
    static let minVoiceRms = 45.0
    static let minVoicePeak = 240

    static func align(_ bytes: Int) -> Int { bytes - (bytes % bytesPerSample) }

    static func msToBytes(_ ms: Int, sampleRateHz: Int) -> Int {
        align(sampleRateHz * bytesPerSample * ms / 1_000)
    }

    /// RMS/peak gate over one window of s16le mono audio.
    static func isVoiced(_ bytes: Data) -> Bool {
        let sampleBytes = align(bytes.count)
        guard sampleBytes > 0 else { return false }
        var sumSquares = 0.0
        var peak = 0
        bytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < sampleBytes {
                let sample = Int(
                    Int16(bitPattern: UInt16(base[index]) | (UInt16(base[index + 1]) << 8))
                )
                peak = max(peak, abs(sample))
                sumSquares += Double(sample) * Double(sample)
                index += bytesPerSample
            }
        }
        let rms = (sumSquares / Double(sampleBytes / bytesPerSample)).squareRoot()
        return rms >= minVoiceRms || peak >= minVoicePeak
    }

    /// Speech ranges over `byteCount` bytes of raw PCM, read window-by-window through `read`
    /// (offset, length) so a multi-hour segment is never resident.
    static func speechRanges(
        byteCount: Int,
        sampleRateHz: Int,
        read: (_ offset: Int, _ length: Int) throws -> Data
    ) rethrows -> [PcmSpeechRange] {
        let rawEnd = align(byteCount)
        guard rawEnd >= minAudioBytes else { return [] }
        let windowBytes = max(msToBytes(analysisWindowMs, sampleRateHz: sampleRateHz), bytesPerSample)
        let prerollBytes = msToBytes(speechPrerollMs, sampleRateHz: sampleRateHz)
        let postrollBytes = msToBytes(speechPostrollMs, sampleRateHz: sampleRateHz)
        let minSpeechBytes = msToBytes(minSpeechRangeMs, sampleRateHz: sampleRateHz)

        var ranges: [PcmSpeechRange] = []
        var speechStart: Int?
        var speechEnd = 0
        var offset = 0
        while offset < rawEnd {
            let window = try read(offset, min(windowBytes, rawEnd - offset))
            if window.isEmpty { break }
            let windowEnd = offset + align(window.count)
            if isVoiced(window) {
                if speechStart == nil { speechStart = align(max(offset - prerollBytes, 0)) }
                speechEnd = align(min(windowEnd + postrollBytes, rawEnd))
            } else if let start = speechStart, offset >= speechEnd {
                append(&ranges, start, speechEnd, minSpeechBytes)
                speechStart = nil
            }
            offset += window.count
        }
        if let start = speechStart { append(&ranges, start, speechEnd, minSpeechBytes) }
        return splitLong(merge(ranges, sampleRateHz: sampleRateHz), sampleRateHz: sampleRateHz)
    }

    private static func append(
        _ ranges: inout [PcmSpeechRange], _ startByte: Int, _ endByte: Int, _ minSpeechBytes: Int
    ) {
        let start = align(startByte)
        let end = max(align(endByte), start)
        if end - start >= minSpeechBytes {
            ranges.append(PcmSpeechRange(startByte: start, endByte: end))
        }
    }

    /// Merges ranges separated by less than a 1.5 s gap, so one sentence is one native call.
    static func merge(_ ranges: [PcmSpeechRange], sampleRateHz: Int) -> [PcmSpeechRange] {
        guard var current = ranges.first else { return [] }
        let gap = msToBytes(mergeSpeechGapMs, sampleRateHz: sampleRateHz)
        var merged: [PcmSpeechRange] = []
        for next in ranges.dropFirst() {
            if next.startByte - current.endByte <= gap {
                current.endByte = max(current.endByte, next.endByte)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    /// Caps each range at 45 s so a long monologue is not one enormous native call.
    static func splitLong(_ ranges: [PcmSpeechRange], sampleRateHz: Int) -> [PcmSpeechRange] {
        let maxBytes = msToBytes(maxTranscribeChunkMs, sampleRateHz: sampleRateHz)
        guard maxBytes > 0 else { return ranges }
        return ranges.flatMap { range -> [PcmSpeechRange] in
            guard range.byteLength > maxBytes else { return [range] }
            var pieces: [PcmSpeechRange] = []
            var start = range.startByte
            while start < range.endByte {
                let end = min(start + maxBytes, range.endByte)
                pieces.append(PcmSpeechRange(startByte: start, endByte: end))
                start = end
            }
            return pieces
        }
    }

    /// Cactus sometimes answers with bracketed non-speech markers ("[BLANK_AUDIO]") or a stray
    /// character; those are a no-speech outcome, not a transcript.
    static func isNoSpeech(_ text: String) -> Bool {
        if text.count < 2 { return true }
        let stripped = text.replacingOccurrences(
            of: "\\[[^\\]]*\\]|\\([^)]*\\)", with: "", options: .regularExpression
        )
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return text.filter { $0.isLetter || $0.isNumber }.count < 2
    }
}

/// One native JSON response, before offsets are applied.
struct ParakeetNativeResponse: Equatable {
    var text: String
    var segments: [TranscriptSegment] = []
    var words: [TranscriptWord] = []

    /// Parses Cactus's `{"response"|"text", "segments":[…], "words":[…]}`; anything unparseable
    /// is treated as the transcript itself, exactly as the Kotlin provider did.
    static func parse(_ json: String) -> ParakeetNativeResponse {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ParakeetNativeResponse(text: json) }
        let text = (root["response"] as? String) ?? (root["text"] as? String) ?? json
        return ParakeetNativeResponse(
            text: text,
            segments: (root["segments"] as? [[String: Any]] ?? []).compactMap(segment),
            words: (root["words"] as? [[String: Any]] ?? []).compactMap(word)
        )
    }

    private static func segment(_ item: [String: Any]) -> TranscriptSegment? {
        guard let start = ms(item["start"]) else { return nil }
        let end = max(ms(item["end"]) ?? start, start)
        guard let raw = (item["text"] as? String) ?? (item["word"] as? String) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TranscriptSegment(
            text: text, startMs: start, endMs: end, speaker: item["speaker"] as? String
        )
    }

    private static func word(_ item: [String: Any]) -> TranscriptWord? {
        guard let start = ms(item["start"]) else { return nil }
        let end = max(ms(item["end"]) ?? start, start)
        guard let raw = (item["word"] as? String) ?? (item["text"] as? String) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TranscriptWord(text: text, startMs: start, endMs: end)
    }

    /// Native timings are seconds relative to the range; the caller shifts them to segment time.
    private static func ms(_ value: Any?) -> Int64? {
        guard let seconds = (value as? NSNumber)?.doubleValue else { return nil }
        return Int64(seconds * 1_000)
    }

    /// Shifts this response's timings into the whole-segment timeline.
    func offset(by startMs: Int64, rangeEndMs: Int64, text cleaned: String) -> ParakeetNativeResponse
    {
        let shifted = segments.map {
            TranscriptSegment(
                text: $0.text, startMs: $0.startMs + startMs, endMs: $0.endMs + startMs,
                speaker: $0.speaker
            )
        }
        return ParakeetNativeResponse(
            text: cleaned,
            segments: shifted.isEmpty
                ? [
                    TranscriptSegment(
                        text: cleaned, startMs: startMs, endMs: max(rangeEndMs, startMs)
                    )
                ] : shifted,
            words: words.map {
                TranscriptWord(text: $0.text, startMs: $0.startMs + startMs, endMs: $0.endMs + startMs)
            }
        )
    }
}

/// On-device speech-to-text over a downloaded Parakeet model.
///
/// Availability is purely "is the selected model installed" — transcription NEVER triggers the
/// download, which is an explicit action in Settings.
public final class ParakeetTranscriptionProvider: TranscriptionProvider, LocalTranscriptionLifecycle
{
    /// Unchanged from the KMP app so provenance on migrated transcripts still resolves.
    public static let providerId = "cactus-local"
    /// The Core AI runtime's id. Same `-local` suffix, which is what the app reads as
    /// "on-device"; a different name, because a transcript's provenance should say which
    /// runtime produced it.
    public static let coreAIProviderId = "coreai-local"

    public static func providerId(for runtime: LocalEngineRuntime) -> String {
        switch runtime {
        case .cactus: return providerId
        case .coreAI: return coreAIProviderId
        }
    }

    public let id: String
    private let spec: ParakeetModelSpec
    private let location: any ParakeetModelLocating
    private let engine: any ParakeetNativeEngine
    private let temporaryDirectory: URL
    private let nowMs: @Sendable () -> Int64
    private let isForeground: @Sendable () -> Bool
    private let boostQuietAudio: @Sendable () -> Bool
    private let log: @Sendable (String) -> Void
    private let lastUsedMs = LastUsed()
    private let loadHold = LoadHold()

    /// How long a model that could not be loaded is left alone before the next attempt.
    ///
    /// Without it every queued segment retried the load. On 2026-09-29 that was a Core AI load
    /// every ~14 s for hours while the phone charged: each one re-read the 1.1 GB encoder, had
    /// MPSGraph re-materialise its graphs, and spooled the segment's PCM to disk first — 17 GB of
    /// writes in 50 minutes by the OS's own disk-write report, the phone at `thermal=serious`,
    /// and not one transcript. A load that fails now costs one attempt per window.
    static let loadRetryPauseMs: Int64 = 30 * 60_000

    /// - Parameters:
    ///   - engine: the native engine for `spec.runtime`; the factory's when nil.
    ///   - isForeground: whether the app is on screen. A Core AI model whose one-time
    ///     specialization pass has not completed (`location.isPrepared`) is `providerUnavailable`
    ///     in the background rather than started cold inside a background pass.
    ///   - boostQuietAudio: the `ParakeetQuietAudioBoost` switch, read per chunk.
    ///   - log: the flight recorder. Only model-load trouble is written — never per segment.
    public init(
        spec: ParakeetModelSpec,
        location: any ParakeetModelLocating = ParakeetModelLocation(),
        engine: (any ParakeetNativeEngine)? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        isForeground: @escaping @Sendable () -> Bool = { true },
        boostQuietAudio: @escaping @Sendable () -> Bool = { ParakeetQuietAudioBoost.isEnabled() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.spec = spec
        self.id = Self.providerId(for: spec.runtime)
        self.location = location
        self.engine = engine ?? ParakeetEngineFactory.make(runtime: spec.runtime)
        self.temporaryDirectory = temporaryDirectory
        self.nowMs = nowMs
        self.isForeground = isForeground
        self.boostQuietAudio = boostQuietAudio
        self.log = log
    }

    public var modelSpec: ParakeetModelSpec { spec }

    public func isAvailable() async -> Bool {
        engine.isSupported && location.installedModelPath(for: spec) != nil
    }

    public func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        guard engine.isSupported, let modelPath = location.installedModelPath(for: spec) else {
            throw TranscriptionError.providerUnavailable(providerId: id)
        }
        // A cold Core AI load writes ~1.1 GB of specialization cache and takes seconds of CPU
        // at a memory peak — foreground work with a visible "finishing up" row, never something
        // a background wake spends its budget on. `providerUnavailable`, not a failure: the
        // router may fall back and the queue retries once the app is up.
        if spec.requiresPreparation, !location.isPrepared(spec), !isForeground() {
            throw TranscriptionError.providerUnavailable(providerId: id)
        }
        // Checked before the audio is spooled: a model known not to load right now must not cost
        // a segment's worth of disk writes to find that out again.
        if let reason = loadHold.reason(nowMs: nowMs()) {
            throw TranscriptionError.transcriptionFailed(
                "failed to initialize local model: \(reason) (next attempt after a pause)"
            )
        }
        let raw = temporaryDirectory.appendingPathComponent("cactus_stt-\(UUID().uuidString).raw")
        let wav = temporaryDirectory.appendingPathComponent("cactus_stt-\(UUID().uuidString).wav")
        defer {
            lastUsedMs.set(nowMs())
            try? FileManager.default.removeItem(at: raw)
            try? FileManager.default.removeItem(at: wav)
        }

        let pcmBytes = try await spool(pcmChunks, to: raw)
        guard pcmBytes >= ParakeetPcm.minAudioBytes else {
            throw TranscriptionError.noSpeechDetected("local audio too short")
        }

        let source = try FileHandle(forReadingFrom: raw)
        defer { try? source.close() }
        var ranges = try ParakeetPcm.speechRanges(byteCount: pcmBytes, sampleRateHz: sampleRateHz) {
            offset, length in
            try source.seek(toOffset: UInt64(offset))
            return try source.read(upToCount: length) ?? Data()
        }
        if ranges.isEmpty {
            ranges = ParakeetPcm.splitLong(
                [PcmSpeechRange(startByte: 0, endByte: ParakeetPcm.align(pcmBytes))],
                sampleRateHz: sampleRateHz
            )
        }

        return try await withTaskCancellationHandler {
            try await run(
                ranges: ranges, source: source, wav: wav, modelPath: modelPath.path,
                sampleRateHz: sampleRateHz
            )
        } onCancel: {
            // Interrupt the blocking native call so the engine's queue frees promptly.
            engine.interrupt()
        }
    }

    private func run(
        ranges: [PcmSpeechRange], source: FileHandle, wav: URL, modelPath: String,
        sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        try await loadEngine(modelPath: modelPath)

        var pieces: [ParakeetNativeResponse] = []
        let boost = boostQuietAudio()
        for range in ranges {
            try Task.checkCancellation()
            do {
                let gain = boost ? try Self.boostGain(from: source, range: range) : 1
                try Self.writeWav(
                    from: source, range: range, to: wav, sampleRateHz: sampleRateHz, gain: gain
                )
            } catch {
                throw TranscriptionError.transcriptionFailed(
                    "failed to stage local audio", underlying: error
                )
            }
            let native: ParakeetNativeResponse
            do {
                native = ParakeetNativeResponse.parse(try await engine.transcribe(wavPath: wav.path))
            } catch let error as ParakeetEngineError {
                throw Self.map(error, id: id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscriptionError.transcriptionFailed(
                    "local transcription failed", underlying: error
                )
            }
            let cleaned = native.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ParakeetPcm.isNoSpeech(cleaned) { continue }
            pieces.append(
                native.offset(
                    by: range.startMs(sampleRateHz: sampleRateHz),
                    rangeEndMs: range.endMs(sampleRateHz: sampleRateHz),
                    text: cleaned
                )
            )
        }

        let text = pieces.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ParakeetPcm.isNoSpeech(text) else {
            throw TranscriptionError.noSpeechDetected("local model returned no speech")
        }
        return TranscriptionResult(
            text: text,
            providerId: id,
            modelUsed: spec.modelUsed,
            segments: pieces.flatMap { $0.segments },
            words: pieces.flatMap { $0.words }
        )
    }

    /// Loads the model, recovering once from a stale compiled cache.
    ///
    /// A model that was PREPARED and now fails to load has not changed on disk — the install
    /// check just passed — so what broke is the runtime's compiled cache outside it (see
    /// `CoreAIParakeetEngine.discardCompiledCache` for the case that took the user's on-device
    /// transcription down for ten days). The recovery:
    ///
    /// 1. drop the compiled cache and withdraw `.prepared`, because the next load IS the cold
    ///    specialization pass the prepare step exists to keep out of the background;
    /// 2. in the foreground, run that load now and restore `.prepared` when it works;
    /// 3. in the background, answer `providerUnavailable` — the router falls back, and the
    ///    unprepared model waits for the app to come forward (or for the store's prepare pass)
    ///    exactly as a fresh install does.
    ///
    /// A load that still fails puts the model in `loadHold` for `loadRetryPauseMs`, so the next
    /// segments fail in microseconds instead of repeating a multi-gigabyte load each.
    private func loadEngine(modelPath: String) async throws {
        let wasPrepared = location.isPrepared(spec)
        do {
            try await engine.load(modelPath: modelPath, identity: spec.modelUsed)
            loadHold.clear()
            // A cold load that worked IS the specialization pass (this path only runs cold in the
            // foreground), so the background may use the model again.
            if spec.requiresPreparation, !wasPrepared { location.setPrepared(spec, true) }
            return
        } catch let error as ParakeetEngineError {
            guard case .modelLoadFailed(let message) = error else { throw Self.map(error, id: id) }
            guard spec.requiresPreparation, wasPrepared else {
                holdLoads(message)
                throw Self.map(error, id: id)
            }
            let discarded = await engine.discardCompiledCache(modelPath: modelPath)
            location.setPrepared(spec, false)
            log(
                "local model \(spec.id) failed to load (\(message)); "
                    + (discarded ? "discarded its compiled cache" : "no compiled cache to discard")
                    + (isForeground() ? ", rebuilding now" : ", rebuilding when the app is open")
            )
        } catch {
            throw TranscriptionError.transcriptionFailed(
                "failed to initialize local model", underlying: error
            )
        }

        guard isForeground() else { throw TranscriptionError.providerUnavailable(providerId: id) }
        do {
            try await engine.load(modelPath: modelPath, identity: spec.modelUsed)
        } catch let error as ParakeetEngineError {
            if case .modelLoadFailed(let message) = error {
                holdLoads(message)
                log("local model \(spec.id) rebuild failed: \(message)")
            }
            throw Self.map(error, id: id)
        } catch {
            throw TranscriptionError.transcriptionFailed(
                "failed to initialize local model", underlying: error
            )
        }
        loadHold.clear()
        location.setPrepared(spec, true)
        log("local model \(spec.id) rebuilt its compiled cache and loaded")
    }

    private func holdLoads(_ message: String) {
        loadHold.set(reason: message, untilMs: nowMs() + Self.loadRetryPauseMs)
    }

    /// Engine failures the pipeline must NOT treat as a provider bug: no binary and a squeezed
    /// jetsam budget both mean "not usable right now", so the router may fall back to cloud.
    static func map(_ error: ParakeetEngineError, id: String) -> TranscriptionError {
        switch error {
        case .unsupportedPlatform, .insufficientMemory:
            return .providerUnavailable(providerId: id)
        case .modelLoadFailed(let message):
            return .transcriptionFailed("failed to initialize local model: \(message)")
        case .nativeFailure(let message):
            return .transcriptionFailed("local transcription failed: \(message)")
        }
    }

    /// Spools the PCM stream to `destination`, returning the byte count. Throws
    /// `noSpeechDetected` for all-zero audio (the watch sent digital silence).
    private func spool(_ chunks: AsyncThrowingStream<Data, Error>, to destination: URL) async throws
        -> Int
    {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw TranscriptionError.transcriptionFailed("failed to stage local audio")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var bytes = 0
        var nonZero = false
        do {
            for try await chunk in chunks where !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
                bytes += chunk.count
                if !nonZero { nonZero = chunk.contains { $0 != 0 } }
            }
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.transcriptionFailed("failed to read audio", underlying: error)
        }
        guard nonZero else { throw TranscriptionError.noSpeechDetected("local audio is silent") }
        return bytes
    }

    /// The `ParakeetQuietAudioBoost` gain for one range: its peak, read in bounded chunks.
    static func boostGain(from source: FileHandle, range: PcmSpeechRange) throws -> Double {
        var peak = 0
        try forEachChunk(of: source, range: range) { peak = max(peak, ParakeetQuietAudioBoost.peak(of: $0)) }
        return ParakeetQuietAudioBoost.gain(forPeak: peak)
    }

    /// Writes one range of the raw spool out as a mono 16-bit WAV, copied in bounded chunks,
    /// with `gain` applied to every sample on the way (1 copies the bytes as they are).
    static func writeWav(
        from source: FileHandle, range: PcmSpeechRange, to destination: URL, sampleRateHz: Int,
        gain: Double = 1
    ) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw TranscriptionError.transcriptionFailed("failed to stage local audio")
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        try out.write(
            contentsOf: PcmWav.headerMono16(pcmSizeBytes: range.byteLength, sampleRateHz: sampleRateHz)
        )
        try forEachChunk(of: source, range: range) { chunk in
            try out.write(contentsOf: ParakeetQuietAudioBoost.apply(gain, to: chunk))
        }
    }

    /// Reads `range` of the spool in 64 KiB pieces (sample-aligned, since the range is).
    private static func forEachChunk(
        of source: FileHandle, range: PcmSpeechRange, _ body: (Data) throws -> Void
    ) throws {
        try source.seek(toOffset: UInt64(range.startByte))
        var remaining = range.byteLength
        while remaining > 0 {
            guard let chunk = try source.read(upToCount: min(remaining, 64 * 1024)),
                !chunk.isEmpty
            else { break }
            try body(chunk)
            remaining -= chunk.count
        }
    }

    // MARK: - LocalTranscriptionLifecycle

    public func releaseModel(reason: String) async {
        await engine.release()
        lastUsedMs.set(0)
    }

    public func releaseModelIfIdle(nowMs now: Int64, idleTimeoutMs: Int64) async {
        let last = lastUsedMs.value
        guard last != 0, now - last >= idleTimeoutMs else { return }
        await releaseModel(reason: "idle \(idleTimeoutMs)ms")
    }
}

/// A model load that failed and is not retried until `untilMs`. See `loadRetryPauseMs`.
final class LoadHold: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (reason: String, untilMs: Int64)?

    /// The failure that is still being waited out at `nowMs`, or nil when a load may be tried.
    func reason(nowMs: Int64) -> String? {
        lock.withLock {
            guard let held, nowMs < held.untilMs else { return nil }
            return held.reason
        }
    }

    func set(reason: String, untilMs: Int64) {
        lock.withLock { held = (reason, untilMs) }
    }

    func clear() {
        lock.withLock { held = nil }
    }
}

/// Wall-clock of the most recent transcription, for the idle release.
final class LastUsed: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: Int64 = 0

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return stamp
    }

    func set(_ value: Int64) {
        lock.lock()
        stamp = value
        lock.unlock()
    }
}
