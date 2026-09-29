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

/// One analysis window's loudness.
struct WindowLevel: Equatable, Sendable {
    var rms: Double
    var peak: Int
}

/// When a window counts as voiced. Fixed thresholds (`minRms`/`minPeak`), optionally raised to a
/// multiple of the segment's own noise floor (`floorFactor` times the `floorPercentile` window
/// RMS), so a noisy room does not pass as speech while a quiet one keeps its quiet voices.
struct VoiceGate: Equatable, Sendable {
    var minRms: Double
    var minPeak: Int
    var floorFactor: Double = 0
    var floorPercentile: Double = 0.2

    /// The thresholds this gate uses on `levels` (the floor term resolved).
    func resolved(for levels: [WindowLevel]) -> VoiceGate {
        guard floorFactor > 0, !levels.isEmpty else { return self }
        let sorted = levels.map(\.rms).sorted()
        let floor = sorted[min(sorted.count - 1, Int(Double(sorted.count) * floorPercentile))]
        return VoiceGate(minRms: max(minRms, floor * floorFactor), minPeak: minPeak)
    }

    func isVoiced(_ level: WindowLevel) -> Bool {
        level.rms >= minRms || level.peak >= minPeak
    }

    static let production = VoiceGate(
        minRms: ParakeetPcm.minVoiceRms, minPeak: ParakeetPcm.minVoicePeak)
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
    /// How far back from the 45 s cap a chunk boundary may move to land in the quietest window.
    static let boundarySearchMs = 5_000
    static let minVoiceRms = 45.0
    static let minVoicePeak = 240

    static func align(_ bytes: Int) -> Int { bytes - (bytes % bytesPerSample) }

    static func msToBytes(_ ms: Int, sampleRateHz: Int) -> Int {
        align(sampleRateHz * bytesPerSample * ms / 1_000)
    }

    /// RMS and peak of one window of s16le mono audio.
    static func level(_ bytes: Data) -> WindowLevel {
        let sampleBytes = align(bytes.count)
        guard sampleBytes > 0 else { return WindowLevel(rms: 0, peak: 0) }
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
        return WindowLevel(
            rms: (sumSquares / Double(sampleBytes / bytesPerSample)).squareRoot(), peak: peak)
    }

    /// RMS/peak gate over one window of s16le mono audio, at the production thresholds.
    static func isVoiced(_ bytes: Data) -> Bool {
        VoiceGate.production.isVoiced(level(bytes))
    }

    /// The level of every analysis window over `byteCount` bytes of raw PCM, read window by
    /// window through `read` (offset, length) so a multi-hour segment is never resident — only
    /// these numbers are (16 bytes per 100 ms).
    static func windowLevels(
        byteCount: Int,
        sampleRateHz: Int,
        read: (_ offset: Int, _ length: Int) throws -> Data
    ) rethrows -> [WindowLevel] {
        let rawEnd = align(byteCount)
        let windowBytes = max(msToBytes(analysisWindowMs, sampleRateHz: sampleRateHz), bytesPerSample)
        var levels: [WindowLevel] = []
        levels.reserveCapacity(rawEnd / windowBytes + 1)
        var offset = 0
        while offset < rawEnd {
            let window = try read(offset, min(windowBytes, rawEnd - offset))
            if window.isEmpty { break }
            levels.append(level(window))
            offset += window.count
        }
        return levels
    }

    /// The WHOLE of `byteCount` bytes of raw PCM, in chunks no longer than `maxTranscribeChunkMs`,
    /// each boundary placed in the quietest analysis window of the `boundarySearchMs` before the
    /// cap — so a word is not cut in two by the arithmetic of a fixed 45 s split.
    ///
    /// This replaced the interior voice gate (`speechRanges`) as what the engine is handed. The
    /// gate was measured on 2026-09-29 against 258 of the user's cloud-transcribed segments
    /// (390,047 words with timings, 60 hours of audio): at its thresholds (RMS 45 / peak 240 per
    /// 100 ms) it left out 17.3% of the words the cloud heard — whole quiet speakers, up to every
    /// word of a segment — to save 29% of the engine's time. The words it dropped sat at RMS ~19
    /// (p90 30). Every lower threshold that stopped losing speech (RMS 14: 0.01% missed) also
    /// stopped saving anything (99% of the audio handed over), because the watch's noise floor is
    /// that low: there is essentially no interior silence worth skipping. A segment with nothing
    /// in it is still skipped whole, before the engine is ever touched, by
    /// `TranscriptionProcessor.provablySilent`.
    static func chunks(levels: [WindowLevel], byteCount: Int, sampleRateHz: Int) -> [PcmSpeechRange] {
        let rawEnd = align(byteCount)
        guard rawEnd >= minAudioBytes else { return [] }
        let windowBytes = max(msToBytes(analysisWindowMs, sampleRateHz: sampleRateHz), bytesPerSample)
        let maxBytes = msToBytes(maxTranscribeChunkMs, sampleRateHz: sampleRateHz)
        let searchBytes = min(msToBytes(boundarySearchMs, sampleRateHz: sampleRateHz), maxBytes / 2)
        guard maxBytes > windowBytes else {
            return [PcmSpeechRange(startByte: 0, endByte: rawEnd)]
        }
        var ranges: [PcmSpeechRange] = []
        var start = 0
        while rawEnd - start > maxBytes {
            let hardEnd = start + maxBytes
            // Windows lying wholly inside [hardEnd - searchBytes, hardEnd).
            let firstWindow = (hardEnd - searchBytes + windowBytes - 1) / windowBytes
            let lastWindow = hardEnd / windowBytes - 1
            var cut = hardEnd
            if firstWindow <= lastWindow, lastWindow < levels.count {
                var quietest = lastWindow
                for index in firstWindow...lastWindow where levels[index].rms < levels[quietest].rms {
                    quietest = index
                }
                cut = align(quietest * windowBytes + windowBytes / 2)
            }
            if cut <= start { cut = hardEnd }
            ranges.append(PcmSpeechRange(startByte: start, endByte: cut))
            start = cut
        }
        ranges.append(PcmSpeechRange(startByte: start, endByte: rawEnd))
        return ranges
    }

    /// Speech ranges over `byteCount` bytes of raw PCM at the production gate.
    static func speechRanges(
        byteCount: Int,
        sampleRateHz: Int,
        read: (_ offset: Int, _ length: Int) throws -> Data
    ) rethrows -> [PcmSpeechRange] {
        let levels = try windowLevels(byteCount: byteCount, sampleRateHz: sampleRateHz, read: read)
        return speechRanges(
            levels: levels, gate: .production, byteCount: byteCount, sampleRateHz: sampleRateHz)
    }

    /// Speech ranges from precomputed window levels: a window the gate calls voiced opens (or
    /// extends) a range padded by `speechPrerollMs`/`speechPostrollMs`; ranges closer than
    /// `mergeSpeechGapMs` merge; shorter than `minSpeechRangeMs` are dropped; longer than
    /// `maxTranscribeChunkMs` are split.
    static func speechRanges(
        levels: [WindowLevel], gate: VoiceGate, byteCount: Int, sampleRateHz: Int
    ) -> [PcmSpeechRange] {
        let rawEnd = align(byteCount)
        guard rawEnd >= minAudioBytes else { return [] }
        let windowBytes = max(msToBytes(analysisWindowMs, sampleRateHz: sampleRateHz), bytesPerSample)
        let prerollBytes = msToBytes(speechPrerollMs, sampleRateHz: sampleRateHz)
        let postrollBytes = msToBytes(speechPostrollMs, sampleRateHz: sampleRateHz)
        let minSpeechBytes = msToBytes(minSpeechRangeMs, sampleRateHz: sampleRateHz)
        let threshold = gate.resolved(for: levels)

        var ranges: [PcmSpeechRange] = []
        var speechStart: Int?
        var speechEnd = 0
        for (index, level) in levels.enumerated() {
            let offset = index * windowBytes
            guard offset < rawEnd else { break }
            let windowEnd = min(offset + windowBytes, rawEnd)
            if threshold.isVoiced(level) {
                if speechStart == nil { speechStart = align(max(offset - prerollBytes, 0)) }
                speechEnd = align(min(windowEnd + postrollBytes, rawEnd))
            } else if let start = speechStart, offset >= speechEnd {
                append(&ranges, start, speechEnd, minSpeechBytes)
                speechStart = nil
            }
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
    private let rangeDeadline: @Sendable (Int64) -> Int64
    private let lastUsedMs = LastUsed()
    private let loadHold = LoadHold()
    /// Set when the engine refused for memory; see `memoryRetryPauseMs`.
    private let memoryHold = LoadHold()
    /// One cold rebuild attempt per process for a model that was NOT prepared when its load
    /// failed (a re-import meeting the old cache, a rebuild that was interrupted). A prepared
    /// model gets its recovery every time it goes stale; this bounds the other case, whose
    /// failure could otherwise repeat a 1.1 GB rebuild each time the load pause ends.
    private let unpreparedRecovery = OnceFlag()

    /// How long the provider reports itself unavailable after the engine refused for memory.
    ///
    /// `isAvailable()` knew nothing about memory, so a phone short of it spun: every task was
    /// decoded (the silence gate), spooled to disk (~29 MB per 15 minutes), refused by the
    /// engine's guard, parked as Disabled — and un-parked by the next pass, a second later,
    /// because the provider still said it was available. Five minutes is long enough for the
    /// memory situation to change and short enough that nothing waits noticeably.
    public static let memoryRetryPauseMs: Int64 = 5 * 60_000

    /// The longest one range may take before the call is interrupted: eight times the range's
    /// own audio, and never under two minutes — far beyond anything a working engine needs
    /// (a 45 s range is seconds of work even on a throttled phone). A safety net, not a pace:
    /// without it one call that never returns holds the drain, and everything queued behind it,
    /// until the process dies.
    public static func rangeDeadlineMs(forAudioMs audioMs: Int64) -> Int64 {
        max(120_000, audioMs * 8)
    }

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
        log: @escaping @Sendable (String) -> Void = { _ in },
        rangeDeadlineMs: @escaping @Sendable (Int64) -> Int64 = { rangeDeadlineMs(forAudioMs: $0) }
    ) {
        self.rangeDeadline = rangeDeadlineMs
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

    /// Whether a segment handed over NOW could be transcribed — not merely whether the model is
    /// installed. The difference is what the queue parks on: a task that finds no usable
    /// provider waits as Disabled at no cost and is picked up again once one is, while a task
    /// sent to a provider that can only refuse it re-decodes its whole segment to learn that on
    /// every retry. So an unprepared Core AI model in the background, and a model in its
    /// `loadHold` pause, are unavailable until that changes.
    public func isAvailable() async -> Bool {
        guard engine.isSupported, location.installedModelPath(for: spec) != nil else {
            return false
        }
        if spec.requiresPreparation, !location.isPrepared(spec), !isForeground() { return false }
        let now = nowMs()
        return loadHold.reason(nowMs: now) == nil && memoryHold.reason(nowMs: now) == nil
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
        if memoryHold.reason(nowMs: nowMs()) != nil {
            throw TranscriptionError.providerUnavailable(providerId: id)
        }
        // From here to the last range the model must stay put: an opportunistic release (the app
        // leaving the foreground, the store's post-prepare release) waits for this lease.
        engine.beginUse()
        defer { engine.endUse() }
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
        // All of it, in chunks cut at quiet points — see `ParakeetPcm.chunks` for why there is no
        // interior voice gate any more.
        let levels = try ParakeetPcm.windowLevels(byteCount: pcmBytes, sampleRateHz: sampleRateHz) {
            offset, length in
            try source.seek(toOffset: UInt64(offset))
            return try source.read(upToCount: length) ?? Data()
        }
        let ranges = ParakeetPcm.chunks(
            levels: levels, byteCount: pcmBytes, sampleRateHz: sampleRateHz)

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

        let startedMs = nowMs()
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
                    Self.scratchWriteFailed, underlying: error
                )
            }
            let native: ParakeetNativeResponse
            do {
                let audioMs = range.endMs(sampleRateHz: sampleRateHz)
                    - range.startMs(sampleRateHz: sampleRateHz)
                native = ParakeetNativeResponse.parse(
                    try await transcribeWithDeadline(
                        wavPath: wav.path, deadlineMs: rangeDeadline(audioMs)))
            } catch let error as ParakeetEngineError {
                throw mapNoting(error, id: id)
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

        // A verdict is only as good as the reads behind it. An interrupted read can come back as
        // empty text rather than an error, and "every chunk was empty" was then settled as "nothing
        // was said" — permanently: whole conversations were lost that way when the model was
        // released under a running segment (see `TranscriptionQueue.requeueUnexplainedNoSpeech`).
        try Task.checkCancellation()
        let text = pieces.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let audioMs = ranges.reduce(0) {
            $0 + $1.endMs(sampleRateHz: sampleRateHz) - $1.startMs(sampleRateHz: sampleRateHz)
        }
        let engineMs = max(0, nowMs() - startedMs)
        guard !ParakeetPcm.isNoSpeech(text) else {
            // The audio length and the time the engine spent on it travel with the verdict: an
            // engine that "heard nothing" in a fraction of the time the audio needs did not run.
            throw TranscriptionError.noSpeechDetected(
                "local model returned no speech ("
                    + String(format: "%.1f", Double(audioMs) / 1_000) + " s of audio in "
                    + "\(engineMs) ms)")
        }
        // One line per segment: the only on-device measure of how fast the engine really runs
        // on the phone (2026-09-30: completions ~3.5 min apart for 15-min segments, against
        // 50x realtime on a Mac — heat, the charger or the engine, and nothing said which).
        // Counters only, never text.
        log(
            "local transcription: \(id) "
                + String(format: "%.0f s of audio in %.1f s (%.1fx realtime), ", Double(audioMs) / 1_000,
                    Double(engineMs) / 1_000, Double(audioMs) / Double(max(engineMs, 1)))
                + "\(pieces.count) of \(ranges.count) chunk(s) with speech")
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
    /// The discard names the load generation this call saw before failing, so a caller that
    /// failed on the same stale cache as another one does not throw away the model (and cache)
    /// the other just rebuilt — the engine answers `.loadedSince` and this call simply loads.
    /// A model that was not prepared gets one such attempt per process (`unpreparedRecovery`).
    ///
    /// A load that still fails puts the model in `loadHold` for `loadRetryPauseMs`, so the next
    /// segments fail in microseconds instead of repeating a multi-gigabyte load each.
    private func loadEngine(modelPath: String) async throws {
        let wasPrepared = location.isPrepared(spec)
        let generation = engine.loadGeneration
        let message: String
        do {
            try await engine.load(modelPath: modelPath, identity: spec.modelUsed)
            loadHold.clear()
            // A cold load that worked IS the specialization pass (this path only runs cold in the
            // foreground), so the background may use the model again.
            if spec.requiresPreparation, !wasPrepared { location.setPrepared(spec, true) }
            return
        } catch let error as ParakeetEngineError {
            guard case .modelLoadFailed(let failure) = error else { throw mapNoting(error, id: id) }
            guard spec.requiresPreparation, wasPrepared || unpreparedRecovery.claim() else {
                holdLoads(failure)
                throw Self.map(error, id: id)
            }
            message = failure
        } catch {
            throw TranscriptionError.transcriptionFailed(
                "failed to initialize local model", underlying: error
            )
        }

        switch await engine.discardCompiledCache(modelPath: modelPath, unlessLoadedSince: generation) {
        case .loadedSince:
            // Someone else recovered it while this call was failing: the cache is good.
            try await loadOrMap(modelPath: modelPath)
            return
        case .nothingToDiscard:
            holdLoads(message)
            throw Self.map(.modelLoadFailed(message), id: id)
        case .discarded:
            // This process has now spent its cold rebuild; a later failure of the (now
            // unprepared) model is held rather than rebuilt again.
            _ = unpreparedRecovery.claim()
            location.setPrepared(spec, false)
            log(
                "local model \(spec.id) failed to load (\(message)); discarded its compiled cache"
                    + (isForeground() ? ", rebuilding now" : ", rebuilding when the app is open")
            )
        }

        guard isForeground() else { throw TranscriptionError.providerUnavailable(providerId: id) }
        let started = nowMs()
        do {
            try await engine.load(modelPath: modelPath, identity: spec.modelUsed)
        } catch let error as ParakeetEngineError {
            if case .modelLoadFailed(let failure) = error {
                holdLoads(failure)
                log("local model \(spec.id) rebuild failed: \(failure)")
            }
            throw mapNoting(error, id: id)
        } catch {
            throw TranscriptionError.transcriptionFailed(
                "failed to initialize local model", underlying: error
            )
        }
        loadHold.clear()
        location.setPrepared(spec, true)
        log(
            "local model \(spec.id) rebuilt its compiled cache and loaded "
                + "(\((nowMs() - started) / 1_000) s)")
    }

    /// A plain load, errors mapped the usual way.
    private func loadOrMap(modelPath: String) async throws {
        do {
            try await engine.load(modelPath: modelPath, identity: spec.modelUsed)
            loadHold.clear()
        } catch let error as ParakeetEngineError {
            if case .modelLoadFailed(let failure) = error { holdLoads(failure) }
            throw mapNoting(error, id: id)
        } catch {
            throw TranscriptionError.transcriptionFailed(
                "failed to initialize local model", underlying: error
            )
        }
    }

    /// `map`, and a memory refusal starts `memoryHold` so the queue parks instead of spinning.
    private func mapNoting(_ error: ParakeetEngineError, id: String) -> TranscriptionError {
        if case .insufficientMemory = error {
            memoryHold.set(reason: "memory", untilMs: nowMs() + Self.memoryRetryPauseMs)
        }
        return Self.map(error, id: id)
    }

    /// `engine.transcribe`, abandoned if it has not returned within `deadlineMs`.
    ///
    /// Deliberately NOT a task group: a group waits for every child before it returns, so a call
    /// that never comes back would hold the "deadline" hostage too. The first of the answer and
    /// the timer resumes the caller; a late answer is dropped. On timeout the engine is
    /// interrupted, which frees its queue for anything that honours cancellation.
    private func transcribeWithDeadline(wavPath: String, deadlineMs: Int64) async throws -> String {
        let engine = self.engine
        let outcome = FirstResult<String>()
        let work = Task<Void, Never> {
            do {
                outcome.resolve(.success(try await engine.transcribe(wavPath: wavPath)))
            } catch {
                outcome.resolve(.failure(error))
            }
        }
        let timer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadlineMs)) * 1_000_000)
            guard !Task.isCancelled else { return }
            let failure = ParakeetEngineError.nativeFailure(
                "no answer from the engine within \(deadlineMs / 1_000) s")
            if outcome.resolve(.failure(failure)) {
                engine.interrupt()
                work.cancel()
            }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await outcome.value()
        } onCancel: {
            work.cancel()
        }
    }

    private func holdLoads(_ message: String) {
        loadHold.set(reason: message, untilMs: nowMs() + Self.loadRetryPauseMs)
    }

    /// Engine failures the pipeline must NOT treat as a provider bug: no binary and a squeezed
    /// jetsam budget both mean "not usable right now", so the router may fall back to cloud.
    static func map(_ error: ParakeetEngineError, id: String) -> TranscriptionError {
        switch error {
        case .unsupportedPlatform, .insufficientMemory, .notLoaded:
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
            throw TranscriptionError.transcriptionFailed(Self.scratchWriteFailed)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            throw TranscriptionError.transcriptionFailed(Self.scratchWriteFailed, underlying: error)
        }
        defer { try? handle.close() }
        var bytes = 0
        var nonZero = false
        do {
            for try await chunk in chunks where !chunk.isEmpty {
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    // The PHONE could not write (a full disk, most likely) — not the recording
                    // that could not be read. Worded so it classifies as a local engine failure,
                    // which is retried, rather than as unreadable audio, which never is.
                    throw TranscriptionError.transcriptionFailed(
                        Self.scratchWriteFailed, underlying: error)
                }
                bytes += chunk.count
                if !nonZero { nonZero = chunk.contains { $0 != 0 } }
            }
        } catch let error as TranscriptionError {
            throw error
        } catch let error where error is CancellationError {
            throw error
        } catch {
            throw TranscriptionError.transcriptionFailed("failed to read audio", underlying: error)
        }
        guard nonZero else { throw TranscriptionError.noSpeechDetected("local audio is silent") }
        return bytes
    }

    /// A scratch-file write failed on the phone. Classifies as `localEngineFailed` (retried, and
    /// revisited after its retries run out), never as `audioUnreadable` (given up on for good).
    static let scratchWriteFailed = "local transcription failed: could not write its scratch file"

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

    /// Soft, like background entry: `lastUsedMs` is stamped when a segment ENDS, so a long
    /// segment still running reads as "idle" by the time the idle sweep looks — the catch-up
    /// burst runs outside the pipeline loop, and the hard release interrupted it mid-segment.
    public func releaseModelIfIdle(nowMs now: Int64, idleTimeoutMs: Int64) async {
        let last = lastUsedMs.value
        guard last != 0, now - last >= idleTimeoutMs else { return }
        await engine.releaseWhenIdle()
        lastUsedMs.set(0)
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

/// The first `resolve` wins and is what `value()` returns; later ones are dropped.
final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    /// True for the call that settled it.
    @discardableResult
    func resolve(_ value: Result<T, Error>) -> Bool {
        let (won, waiting): (Bool, CheckedContinuation<T, Error>?) = lock.withLock {
            guard result == nil else { return (false, nil) }
            result = value
            let pending = waiter
            waiter = nil
            return (true, pending)
        }
        waiting?.resume(with: value)
        return won
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<T, Error>? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// True for exactly one `claim()`.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
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
