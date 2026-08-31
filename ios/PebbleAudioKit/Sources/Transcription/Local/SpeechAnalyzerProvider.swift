import Foundation

#if canImport(AVFAudio)
    import AVFAudio
#endif
#if canImport(Speech)
    import CoreMedia
    import Speech
#endif

// M3 decision: the local speech-to-text engine is Apple's SpeechAnalyzer (iOS 26
// Speech.framework) — system-managed language assets instead of the KMP app's self-managed
// 700 MB Parakeet download and vendored GGML stack. See the decision record at the end of
// `docs/redesign/2026-08-30-swiftui-implementation-plan.md`. The `TranscriptionProvider` seam
// is fixed, so a Parakeet port can slot back in if the M6 on-device quality gate disappoints.

/// Batch on-device transcription over `SpeechAnalyzer` + `SpeechTranscriber`.
///
/// Availability = the locale is supported by `SpeechTranscriber` AND its assets are installed
/// (`AssetInventory` via the `SpeechAssetInventorying` seam — the same one the Settings
/// "Local model" row drives through `LocalModelManager`).
public final class SpeechAnalyzerProvider: TranscriptionProvider {
    public static let providerId = "speechanalyzer"

    public let id = SpeechAnalyzerProvider.providerId
    private let locale: Locale
    private let inventory: any SpeechAssetInventorying

    public init(locale: Locale = .current, inventory: (any SpeechAssetInventorying)? = nil) {
        self.locale = locale
        self.inventory = inventory ?? Self.defaultInventory()
    }

    static func defaultInventory() -> any SpeechAssetInventorying {
        #if canImport(Speech)
            if #available(iOS 26.0, macOS 26.0, *) {
                return SystemSpeechAssetInventory()
            }
        #endif
        return UnsupportedSpeechAssetInventory()
    }

    public func isAvailable() async -> Bool {
        await inventory.status(for: locale) == .installed
    }

    public func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        guard await isAvailable() else {
            throw TranscriptionError.providerUnavailable(providerId: id)
        }
        #if canImport(Speech)
            if #available(iOS 26.0, macOS 26.0, *) {
                return try await SpeechAnalyzerSession.transcribeBatch(
                    locale: locale,
                    pcmChunks: pcmChunks,
                    sampleRateHz: sampleRateHz,
                    providerId: id
                )
            }
        #endif
        throw TranscriptionError.providerUnavailable(providerId: id)
    }
}

/// Fallback inventory for platforms without the iOS 26 Speech stack.
struct UnsupportedSpeechAssetInventory: SpeechAssetInventorying {
    func status(for locale: Locale) async -> SpeechAssetStatus { .unsupported }
    func installationRequest(for locale: Locale) async throws -> (any SpeechAssetInstalling)? {
        nil
    }
    func release(locale: Locale) async {}
}

// MARK: - Pure helpers (hermetically tested; no Speech dependency)

/// Joins finalized result texts into the durable transcript. SpeechTranscriber's finalized
/// results usually carry their own separators; a space is inserted only when neither side
/// provides one (and never before closing punctuation).
func localSpeechJoin(_ pieces: [String]) -> String {
    var joined = ""
    for piece in pieces {
        if piece.isEmpty { continue }
        if joined.isEmpty {
            joined = piece
            continue
        }
        let needsSpace =
            !(joined.last?.isWhitespace ?? true)
            && !(piece.first?.isWhitespace ?? true)
            && !".,!?;:".contains(piece.first!)
        joined += needsSpace ? " " + piece : piece
    }
    return joined
}

/// The final transcript, or nil when the audio produced no usable speech (the provider maps
/// nil to `TranscriptionError.noSpeechDetected` — a valid terminal outcome, not a failure).
func localSpeechFinalText(_ pieces: [String]) -> String? {
    let text = localSpeechJoin(pieces).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

#if canImport(AVFAudio)
    /// 16 kHz mono s16le chunk → `AVAudioPCMBuffer` conversion for `AnalyzerInput`.
    enum LocalSpeechPcm {
        static func format(sampleRateHz: Int) -> AVAudioFormat? {
            guard sampleRateHz > 0 else { return nil }
            return AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(sampleRateHz),
                channels: 1,
                interleaved: true
            )
        }

        /// Copies little-endian signed 16-bit mono samples into a PCM buffer. A trailing odd
        /// byte (torn sample) is dropped. Returns nil for empty/undersized input.
        static func makeBuffer(data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            guard bytesPerFrame > 0 else { return nil }
            let frames = data.count / bytesPerFrame
            guard frames > 0,
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
                ),
                let channel = buffer.int16ChannelData?[0]
            else { return nil }
            buffer.frameLength = AVAudioFrameCount(frames)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(channel, base, frames * bytesPerFrame)
            }
            return buffer
        }
    }
#endif

#if canImport(Speech)
    // MARK: - The analyzer session

    @available(iOS 26.0, macOS 26.0, *)
    enum SpeechAnalyzerSession {
        /// Whole-segment batch transcription: feed every chunk, finalize through end of input,
        /// keep only finalized results.
        static func transcribeBatch(
            locale: Locale,
            pcmChunks: AsyncThrowingStream<Data, Error>,
            sampleRateHz: Int,
            providerId: String
        ) async throws -> TranscriptionResult {
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
            let transcriber = SpeechTranscriber(
                locale: resolved,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            guard let format = LocalSpeechPcm.format(sampleRateHz: sampleRateHz) else {
                throw TranscriptionError.transcriptionFailed(
                    "Unsupported sample rate \(sampleRateHz)"
                )
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

            // Collect finalized results concurrently with feeding.
            async let collected: [(text: String, segment: TranscriptSegment, words: [TranscriptWord])] = {
                var finals: [(String, TranscriptSegment, [TranscriptWord])] = []
                for try await result in transcriber.results where result.isFinal {
                    finals.append(mapResult(result))
                }
                return finals
            }()

            do {
                try await analyzer.start(inputSequence: inputSequence)
                for try await chunk in pcmChunks {
                    guard let buffer = LocalSpeechPcm.makeBuffer(data: chunk, format: format)
                    else { continue }
                    inputContinuation.yield(AnalyzerInput(buffer: buffer))
                }
                inputContinuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch let error as TranscriptionError {
                inputContinuation.finish()
                await analyzer.cancelAndFinishNow()
                throw error
            } catch {
                inputContinuation.finish()
                await analyzer.cancelAndFinishNow()
                throw TranscriptionError.transcriptionFailed(
                    "On-device transcription failed", underlying: error
                )
            }

            let finals = try await collected
            guard let text = localSpeechFinalText(finals.map { $0.text }) else {
                throw TranscriptionError.noSpeechDetected(
                    "SpeechAnalyzer produced no speech for this audio"
                )
            }
            return TranscriptionResult(
                text: text,
                providerId: providerId,
                modelUsed: "SpeechAnalyzer (\(resolved.identifier))",
                segments: finals.map { $0.segment }.filter { !$0.text.isEmpty },
                words: finals.flatMap { $0.words }
            )
        }

        /// One finalized (or volatile) transcriber result → plain text, a phrase segment from
        /// `result.range`, and word timings from the `audioTimeRange` run attributes.
        static func mapResult(
            _ result: SpeechTranscriber.Result
        ) -> (text: String, segment: TranscriptSegment, words: [TranscriptWord]) {
            let attributed = result.text
            let plain = String(attributed.characters)
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            let segment = TranscriptSegment(
                text: trimmed,
                startMs: ms(result.range.start),
                endMs: ms(result.range.end)
            )
            var words: [TranscriptWord] = []
            for run in attributed.runs {
                guard let timeRange = run.audioTimeRange else { continue }
                let wordText = String(attributed[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if wordText.isEmpty { continue }
                words.append(
                    TranscriptWord(
                        text: wordText,
                        startMs: ms(timeRange.start),
                        endMs: ms(timeRange.end)
                    )
                )
            }
            return (plain, segment, words)
        }

        static func ms(_ time: CMTime) -> Int64 {
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return Int64((seconds * 1_000).rounded())
        }
    }
#endif
