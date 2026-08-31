import AppDB
import Foundation
import Testing

@testable import Transcription

// Port of `core/transcription/src/jvmTest/.../TranscriptionProcessorTest.kt` — all 9 cases,
// same names (queue persistence is the AppDB table; transcripts stay file-backed).

private final class ProcessorFakeProvider: TranscriptionProvider, @unchecked Sendable {
    let id: String
    var available: Bool
    var error: Error?

    init(_ id: String, available: Bool = true, error: Error? = nil) {
        self.id = id
        self.available = available
        self.error = error
    }

    func isAvailable() async -> Bool { available }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        if let error { throw error }
        return TranscriptionResult(text: "hello", providerId: id, modelUsed: "model")
    }
}

/// The Kotlin test's `ArrayDeque(listOf(false, true))` for `isSegmentOpen` answers.
private final class OpenAnswers: @unchecked Sendable {
    private var answers: [Bool]
    init(_ answers: [Bool]) { self.answers = answers }
    func next() -> Bool { answers.isEmpty ? false : answers.removeFirst() }
}

@Suite struct ProcessorTests {

    private let clock = ClockBox(5_000)
    private let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func queue() -> TranscriptionQueue {
        TranscriptionQueue(database: db, nowMs: { [clock] in clock.postIncrement() })
    }

    private func transcriptStore(_ root: URL) -> FileTranscriptStore {
        FileTranscriptStore(root: root, nowMs: { [clock] in clock.postIncrement() })
    }

    private func localOnlyRouter(_ local: ProcessorFakeProvider?) -> TranscriptionModeRouter {
        TranscriptionModeRouter(local: local, remote: nil, mode: { .localOnly })
    }

    private let fourBytePcm: TranscriptionProcessor.PcmSource = { _ in
        pcmStream([Data([1, 2, 3, 4])])
    }

    @Test func processNextCompletesQueuedSegment() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let local = ProcessorFakeProvider("local")
        let processor = TranscriptionProcessor(
            queue: queue,
            router: localOnlyRouter(local),
            pcmSource: fourBytePcm
        )

        try await processor.processNext()

        let task = try queue.load("seg-1")
        #expect(task?.state == .complete)
        #expect(task?.modeUsed == .localOnly)
        #expect(task?.providerId == "local")
    }

    @Test func processNextPersistsTranscriptTextDurably() async throws {
        let root = try makeTempRoot("txprocessor")
        let queue = queue()
        try queue.enqueue("seg-1")
        let transcripts = transcriptStore(root)
        let local = ProcessorFakeProvider("local")
        let processor = TranscriptionProcessor(
            queue: queue,
            router: localOnlyRouter(local),
            pcmSource: fourBytePcm,
            transcriptStore: transcripts
        )

        try await processor.processNext()

        let transcript = transcripts.load("seg-1")
        #expect(transcript?.text == "hello")
        #expect(transcript?.modeUsed == .localOnly)
        #expect(transcript?.providerId == "local")
        #expect(transcript?.modelUsed == "model")
    }

    @Test func processNextSkipsOpenSegmentAndLeavesTaskPending() async throws {
        // A RESUME reattach can reopen a segment while its task waits; an open segment must
        // not be transcribed — the result would cover a stale prefix.
        let queue = queue()
        try queue.enqueue("seg-1")
        let processor = TranscriptionProcessor(
            queue: queue,
            router: localOnlyRouter(ProcessorFakeProvider("local")),
            pcmSource: fourBytePcm,
            isSegmentOpen: { _ in true }
        )

        #expect(try await processor.processNext() == nil)

        let task = try queue.load("seg-1")
        #expect(task?.state == .pending)
        #expect(task?.attempts == 0)
    }

    @Test func processNextDiscardsResultWhenSegmentReopensMidTranscription() async throws {
        // The reattach can also land while transcription is running: the finished result must
        // be discarded (not saved, not marked Complete) and the task re-run after the final
        // close.
        let root = try makeTempRoot("txprocessor")
        let queue = queue()
        try queue.enqueue("seg-1")
        let transcripts = transcriptStore(root)
        let openAnswers = OpenAnswers([false, true])  // closed at pick, reopened at commit
        let processor = TranscriptionProcessor(
            queue: queue,
            router: localOnlyRouter(ProcessorFakeProvider("local")),
            pcmSource: fourBytePcm,
            transcriptStore: transcripts,
            isSegmentOpen: { _ in openAnswers.next() }
        )

        try await processor.processNext()

        #expect(try queue.load("seg-1")?.state == .pending)
        #expect(transcripts.load("seg-1") == nil, "a stale transcript must not be persisted")
    }

    @Test func enqueueRequeuesTerminalSuccessTaskForReattachedSegment() async throws {
        // enqueueClosedSegments only receives closed, not-fully-transcribed segments. One that
        // already carries a Complete/NoSpeech task is a reattached segment that grew after
        // transcription: it must re-run, while a Failed task keeps its normal backoff path.
        let queue = queue()
        try queue.enqueue("seg-1")
        let processor = TranscriptionProcessor(
            queue: queue,
            router: localOnlyRouter(ProcessorFakeProvider("local")),
            pcmSource: fourBytePcm
        )
        try await processor.processNext()
        #expect(try queue.load("seg-1")?.state == .complete)

        try queue.enqueue("seg-2")
        try queue.markFailed("seg-2", error: "boom", retryable: true)

        try processor.enqueueClosedSegments(["seg-1", "seg-2", "seg-3"])

        #expect(try queue.load("seg-1")?.state == .pending, "reattached segment must requeue")
        #expect(try queue.load("seg-2")?.state == .failed, "failed task keeps its backoff")
        #expect(try queue.load("seg-3")?.state == .pending, "new segment enqueues normally")
    }

    @Test func noSpeechIsTerminal() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let local = ProcessorFakeProvider(
            "local",
            error: TranscriptionError.noSpeechDetected("silence")
        )
        let processor = TranscriptionProcessor(
            queue: queue,
            router: localOnlyRouter(local),
            pcmSource: { _ in pcmStream([Data(count: 4)]) }
        )

        try await processor.processNext()

        #expect(try queue.load("seg-1")?.state == .noSpeech)
    }

    @Test func nonExceptionProviderThrowableIsRecordedAsFailedTask() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let local = ProcessorFakeProvider(
            "local",
            error: AssertionError("native boundary failed")
        )
        let processor = TranscriptionProcessor(
            queue: queue,
            router: localOnlyRouter(local),
            pcmSource: { _ in pcmStream([Data(count: 4)]) }
        )

        try await processor.processNext()

        let task = try queue.load("seg-1")
        #expect(task?.state == .failed)
        #expect(task?.lastError == "native boundary failed")
    }

    @Test func cancellationStillPropagates() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let local = ProcessorFakeProvider(
            "local",
            error: CancellationError()
        )
        let processor = TranscriptionProcessor(
            queue: queue,
            router: localOnlyRouter(local),
            pcmSource: { _ in pcmStream([Data(count: 4)]) }
        )

        await #expect(throws: CancellationError.self) {
            try await processor.processNext()
        }
    }

    @Test func unavailableProvidersDisableTask() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let processor = TranscriptionProcessor(
            queue: queue,
            router: TranscriptionModeRouter(local: nil, remote: nil, mode: { .localOnly }),
            pcmSource: { _ in pcmStream([Data(count: 4)]) }
        )

        try await processor.processNext()

        #expect(try queue.load("seg-1")?.state == .disabled)
    }
}
