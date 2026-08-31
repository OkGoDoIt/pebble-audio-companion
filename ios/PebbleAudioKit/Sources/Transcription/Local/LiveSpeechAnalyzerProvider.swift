import Foundation

#if canImport(Speech)
    import CoreMedia
    import Speech
#endif

// Streaming flavor of the M3 SpeechAnalyzer engine: the same analyzer run with
// `.volatileResults` so partial hypotheses stream out while audio flows (the on-device live
// path — unlike the cloud realtime sockets this survives with no network at all).

/// Real-time on-device transcription over `SpeechAnalyzer` + `SpeechTranscriber` in
/// volatile-results mode: volatile hypotheses become `partialText`, finalized results append
/// to `finalText`.
public final class LiveSpeechAnalyzerProvider: StreamingTranscriptionProvider {
    public let id = SpeechAnalyzerProvider.providerId
    private let locale: Locale
    private let inventory: any SpeechAssetInventorying

    public init(locale: Locale = .current, inventory: (any SpeechAssetInventorying)? = nil) {
        self.locale = locale
        self.inventory = inventory ?? SpeechAnalyzerProvider.defaultInventory()
    }

    public func isAvailable() async -> Bool {
        await inventory.status(for: locale) == .installed
    }

    public func transcribeStream(
        pcm: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) -> AsyncThrowingStream<StreamingTranscriptUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [locale, id] in
                guard await self.isAvailable() else {
                    continuation.finish(
                        throwing: TranscriptionError.providerUnavailable(providerId: id)
                    )
                    return
                }
                #if canImport(Speech)
                    if #available(iOS 26.0, macOS 26.0, *) {
                        do {
                            try await SpeechAnalyzerSession.streamLive(
                                locale: locale,
                                pcm: pcm,
                                sampleRateHz: sampleRateHz
                            ) { update in
                                continuation.yield(update)
                            }
                            continuation.finish()
                        } catch let error as TranscriptionError {
                            continuation.finish(throwing: error)
                        } catch is CancellationError {
                            continuation.finish()
                        } catch {
                            continuation.finish(
                                throwing: TranscriptionError.transcriptionFailed(
                                    "On-device live transcription failed", underlying: error
                                )
                            )
                        }
                        return
                    }
                #endif
                continuation.finish(
                    throwing: TranscriptionError.providerUnavailable(providerId: id)
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Pure accumulation of volatile/finalized results into `StreamingTranscriptUpdate`s
/// (hermetically tested; the analyzer session drives it).
struct LiveTranscriptAccumulator {
    private var finalPieces: [String] = []
    private var segments: [TranscriptSegment] = []
    private var partialText = ""

    /// A volatile hypothesis replaces the current partial tail.
    mutating func applyVolatile(_ text: String) -> StreamingTranscriptUpdate {
        partialText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return update(isFinal: false)
    }

    /// A finalized result becomes stable transcript; the volatile tail it replaces clears.
    mutating func applyFinal(
        _ text: String, segment: TranscriptSegment?
    ) -> StreamingTranscriptUpdate {
        finalPieces.append(text)
        if let segment, !segment.text.isEmpty {
            segments.append(segment)
        }
        partialText = ""
        return update(isFinal: false)
    }

    /// The session-final update, emitted once the analyzer has finished.
    func finished() -> StreamingTranscriptUpdate {
        update(isFinal: true)
    }

    private func update(isFinal: Bool) -> StreamingTranscriptUpdate {
        StreamingTranscriptUpdate(
            finalText: localSpeechJoin(finalPieces)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            partialText: isFinal ? "" : partialText,
            segments: segments,
            isFinal: isFinal
        )
    }
}

#if canImport(Speech)
    @available(iOS 26.0, macOS 26.0, *)
    extension SpeechAnalyzerSession {
        /// Live session: feeds PCM as it arrives while volatile/finalized results stream back.
        static func streamLive(
            locale: Locale,
            pcm: AsyncThrowingStream<Data, Error>,
            sampleRateHz: Int,
            emit: @escaping @Sendable (StreamingTranscriptUpdate) -> Void
        ) async throws {
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
            let transcriber = SpeechTranscriber(
                locale: resolved,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange]
            )
            guard let format = LocalSpeechPcm.format(sampleRateHz: sampleRateHz) else {
                throw TranscriptionError.transcriptionFailed(
                    "Unsupported sample rate \(sampleRateHz)"
                )
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: inputSequence)

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await chunk in pcm {
                            guard
                                let buffer = LocalSpeechPcm.makeBuffer(
                                    data: chunk, format: format
                                )
                            else { continue }
                            inputContinuation.yield(AnalyzerInput(buffer: buffer))
                        }
                        inputContinuation.finish()
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                    }
                    group.addTask {
                        var accumulator = LiveTranscriptAccumulator()
                        for try await result in transcriber.results {
                            let mapped = mapResult(result)
                            if result.isFinal {
                                emit(accumulator.applyFinal(mapped.text, segment: mapped.segment))
                            } else {
                                emit(accumulator.applyVolatile(mapped.text))
                            }
                        }
                        emit(accumulator.finished())
                    }
                    try await group.waitForAll()
                }
            } catch {
                inputContinuation.finish()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
    }
#endif
