import Foundation
import Receiver
import SegmentStore
import Transcription

/// The diagnostics snapshot. **A published struct, never a reload key** — this is the B17 fix.
///
/// The KMP runtime made the UI re-read the filesystem whenever a counter in here changed (and
/// bumped a counter on a 500 ms tick), which recomposed the entire tree. Here the UI observes the
/// database for content and this struct for status; nothing in the UI ever re-reads disk.
public struct RuntimeDiagnostics: Equatable, Sendable {
    public var segmentCount: Int
    public var openSegmentId: String?
    public var queuedTranscriptionTasks: Int
    public var failedTranscriptionTasks: Int
    /// Conversations that are fully transcribed but still have no AI title/summary/tags. The
    /// counterpart of `queuedTranscriptionTasks` for the enrichment pass: without it, a
    /// freshly migrated library annotates itself invisibly and the rows just look untitled.
    public var conversationsAwaitingEnrichment: Int
    /// True while an enrichment pass is actually running right now.
    public var enrichmentRunning: Bool
    public var lowStorage: Bool
    public var pauseRequested: Bool
    public var freeStorageHintKb: UInt32
    /// True while the app is backgrounded: audio is still received, but local transcription and
    /// AI are deferred until it returns to the foreground. Surfaced (not hidden) so status stays
    /// honest — the KMP flag was computed and never shown.
    public var transcriptionDeferredInBackground: Bool
    public var lastRefreshedAtMs: Int64

    public init(
        segmentCount: Int = 0,
        openSegmentId: String? = nil,
        queuedTranscriptionTasks: Int = 0,
        failedTranscriptionTasks: Int = 0,
        conversationsAwaitingEnrichment: Int = 0,
        enrichmentRunning: Bool = false,
        lowStorage: Bool = false,
        pauseRequested: Bool = false,
        freeStorageHintKb: UInt32 = 0,
        transcriptionDeferredInBackground: Bool = false,
        lastRefreshedAtMs: Int64 = 0
    ) {
        self.segmentCount = segmentCount
        self.openSegmentId = openSegmentId
        self.queuedTranscriptionTasks = queuedTranscriptionTasks
        self.failedTranscriptionTasks = failedTranscriptionTasks
        self.conversationsAwaitingEnrichment = conversationsAwaitingEnrichment
        self.enrichmentRunning = enrichmentRunning
        self.lowStorage = lowStorage
        self.pauseRequested = pauseRequested
        self.freeStorageHintKb = freeStorageHintKb
        self.transcriptionDeferredInBackground = transcriptionDeferredInBackground
        self.lastRefreshedAtMs = lastRefreshedAtMs
    }
}

/// Support-report payload for the Diagnostics screen. Content is never included (the KMP
/// `diagnosticsIncludeContent` flag was hardcoded false and is not resurrected here).
public struct SupportReport: Equatable, Sendable {
    public var generatedAtMs: Int64
    public var receiverState: String
    public var captureIntent: String
    public var diagnostics: RuntimeDiagnostics

    public init(
        generatedAtMs: Int64, receiverState: String, captureIntent: String,
        diagnostics: RuntimeDiagnostics
    ) {
        self.generatedAtMs = generatedAtMs
        self.receiverState = receiverState
        self.captureIntent = captureIntent
        self.diagnostics = diagnostics
    }
}

/// Recomputes and publishes `RuntimeDiagnostics`.
public final class DiagnosticsService: Sendable {
    private let store: SegmentStore
    private let retention: RetentionManager
    private let tasks: @Sendable () async -> [TranscriptionTask]
    private let isForeground: @Sendable () -> Bool
    private let clock: RuntimeClock
    /// Conversations still owed an AI pass, and whether one is running. Injected so this
    /// service keeps its "no database" shape (the App wires it to `ConversationQueries`).
    private let enrichment: @Sendable () async -> (waiting: Int, running: Bool)

    /// Observable published value (`.value` for a sync read, `.stream()` to follow changes).
    public let snapshot = StateSubject<RuntimeDiagnostics>(RuntimeDiagnostics())

    public init(
        store: SegmentStore,
        retention: RetentionManager,
        tasks: @escaping @Sendable () async -> [TranscriptionTask],
        isForeground: @escaping @Sendable () -> Bool,
        clock: RuntimeClock,
        enrichment: @escaping @Sendable () async -> (waiting: Int, running: Bool) = {
            (0, false)
        }
    ) {
        self.store = store
        self.retention = retention
        self.tasks = tasks
        self.isForeground = isForeground
        self.clock = clock
        self.enrichment = enrichment
    }

    @discardableResult
    public func refresh() async -> RuntimeDiagnostics {
        let segments = await store.listSegments()
        let openId = await store.openSegmentId
        let allTasks = await tasks()
        let ai = await enrichment()
        let value = RuntimeDiagnostics(
            segmentCount: segments.count,
            openSegmentId: openId,
            queuedTranscriptionTasks: allTasks.filter {
                $0.state == .pending || $0.state == .running || $0.state == .uploading
            }.count,
            failedTranscriptionTasks: allTasks.filter { $0.state == .failed }.count,
            conversationsAwaitingEnrichment: ai.waiting,
            enrichmentRunning: ai.running,
            lowStorage: retention.lowStorage,
            pauseRequested: retention.pauseRequested,
            freeStorageHintKb: retention.freeStorageHintKb(),
            transcriptionDeferredInBackground: !isForeground(),
            lastRefreshedAtMs: clock.nowMs
        )
        snapshot.value = value
        return value
    }
}
