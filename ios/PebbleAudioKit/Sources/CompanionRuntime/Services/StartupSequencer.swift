import Foundation
import Migration
import SegmentStore

/// The recovery startup order, ported verbatim (plan Part 4.6):
///
/// `recover → queue recover → retention enforce (with cascade) → enqueue → diagnostics`
///
/// plus the M8 legacy import, which runs ONCE **before all of it** — the importer writes the
/// segment index and `transcription_tasks` rows that every later step reads, so running it after
/// recovery would make the first launch look empty.
public enum StartupStep: String, Sendable, Equatable, CaseIterable {
    case legacyImport
    case storeRecover
    case queueRecover
    case retentionEnforce
    case enqueueClosedSegments
    case refreshDiagnostics
}

/// The startup steps, as closures (same seam discipline as `PipelineSteps`).
public struct StartupSteps: Sendable {
    /// Returns true when an import actually ran (first launch after the upgrade).
    public var runLegacyImportIfNeeded: @Sendable () async throws -> Bool
    public var recoverStore: @Sendable () async throws -> Void
    /// Reclaims empty quarantined logs and counts any that still hold audio.
    public var sweepQuarantine: @Sendable () async -> Void = {}
    public var recoverQueue: @Sendable () async throws -> Void
    /// Returns the segment ids retention deleted, so the caller can cascade over them.
    public var enforceRetention: @Sendable () async throws -> [String]
    public var cascadeDeleted: @Sendable (String) async -> Void
    public var enqueueClosedSegments: @Sendable () async throws -> Void
    public var refreshDiagnostics: @Sendable () async -> Void

    public init(
        runLegacyImportIfNeeded: @escaping @Sendable () async throws -> Bool = { false },
        recoverStore: @escaping @Sendable () async throws -> Void = {},
        sweepQuarantine: @escaping @Sendable () async -> Void = {},
        recoverQueue: @escaping @Sendable () async throws -> Void = {},
        enforceRetention: @escaping @Sendable () async throws -> [String] = { [] },
        cascadeDeleted: @escaping @Sendable (String) async -> Void = { _ in },
        enqueueClosedSegments: @escaping @Sendable () async throws -> Void = {},
        refreshDiagnostics: @escaping @Sendable () async -> Void = {}
    ) {
        self.runLegacyImportIfNeeded = runLegacyImportIfNeeded
        self.recoverStore = recoverStore
        self.sweepQuarantine = sweepQuarantine
        self.recoverQueue = recoverQueue
        self.enforceRetention = enforceRetention
        self.cascadeDeleted = cascadeDeleted
        self.enqueueClosedSegments = enqueueClosedSegments
        self.refreshDiagnostics = refreshDiagnostics
    }
}

/// Runs the startup order exactly once per process (later calls only refresh diagnostics).
public actor StartupSequencer {
    private let steps: StartupSteps
    private let onStep: @Sendable (StartupStep) -> Void
    private let log: RuntimeLog
    /// The store-critical half has run: the receiver may open segments.
    private var recovered = false
    /// The catch-up half has run.
    private var remainderDone = false

    public init(
        steps: StartupSteps,
        onStep: @escaping @Sendable (StartupStep) -> Void = { _ in },
        log: RuntimeLog = .silent
    ) {
        self.steps = steps
        self.onStep = onStep
        self.log = log
    }

    public var hasRecovered: Bool { recovered }

    /// Idempotent: the durable recovery runs once; repeat calls just refresh diagnostics, which
    /// is what makes it safe to call from every entry point (launch, foreground, BGProcessing).
    public func recoverIfNeeded() async {
        await recoverBeforeReceiving()
        await recoverRemainder()
    }

    /// The ONLY part of recovery the receiver has to wait for, split out so it is the only part
    /// that can delay the microphone.
    ///
    /// `SegmentStore.recover()` carries `precondition(current == nil)` — it must run before any
    /// segment is opened — so the receiver genuinely cannot start until it and the legacy import
    /// that feeds it are done. Nothing else in the order has that constraint: the transcription
    /// queue, the retention sweep and the closed-segment enqueue are all catch-up work on audio
    /// that is already durable.
    ///
    /// That distinction is load-bearing on a background launch. A Core Bluetooth relaunch gets
    /// roughly ten seconds of runtime, and the whole order over a real container is far slower
    /// than that (`recover()` alone parses and rewrites every sidecar on disk; the recovery test
    /// over the user's own container takes ~16 s on a Mac). Running all of it before starting the
    /// receiver meant a background wake could expire with the link restored, the watch streaming,
    /// and nobody consuming — and because each wake is a fresh process, the next one started the
    /// same sweep from the beginning and got no further.
    public func recoverBeforeReceiving() async {
        guard !recovered else { return }
        recovered = true

        onStep(.legacyImport)
        do { _ = try await steps.runLegacyImportIfNeeded() } catch {
            // A failed import must never block the app: the old container is left untouched and
            // the marker is not written, so the next launch retries.
            log.failure("legacy import", error)
        }

        onStep(.storeRecover)
        do { try await steps.recoverStore() } catch { log.failure("store recover", error) }
        // Immediately after, because `recoverStore` is the only thing that PUTS anything in
        // quarantine, and nothing has ever taken anything back out.
        await steps.sweepQuarantine()
    }

    /// Everything the receiver does not have to wait for. Safe to call repeatedly; the caller
    /// runs it after the receiver is up.
    public func recoverRemainder() async {
        guard !remainderDone else {
            onStep(.refreshDiagnostics)
            await steps.refreshDiagnostics()
            return
        }
        remainderDone = true

        onStep(.queueRecover)
        do { try await steps.recoverQueue() } catch { log.failure("queue recover", error) }

        onStep(.retentionEnforce)
        do {
            for deleted in try await steps.enforceRetention() {
                await steps.cascadeDeleted(deleted)
            }
        } catch {
            log.failure("retention enforce", error)
        }

        onStep(.enqueueClosedSegments)
        do { try await steps.enqueueClosedSegments() } catch {
            log.failure("enqueue closed segments", error)
        }

        onStep(.refreshDiagnostics)
        await steps.refreshDiagnostics()
    }
}

/// Builds the `RetentionManager` config from settings — this is where `retentionDays` stops being
/// a placebo. The free-space floors stay at their ported defaults; only the user-visible caps move.
public func retentionConfig(for settings: any RuntimeSettings) -> RetentionConfig {
    let inputs = settings.retentionConfig
    return RetentionConfig(
        maxTotalBytes: inputs.maxTotalBytes,
        maxAgeMs: inputs.maxAgeMs
    )
}

/// One-shot legacy import (plan Part 4.8 / M8). Wraps the importer so the runtime only sees
/// "did it run", and so a missing old container is a normal outcome rather than an error.
public struct LegacyImportRunner: Sendable {
    private let importer: LegacyImporter?
    private let log: RuntimeLog

    public init(importer: LegacyImporter?, log: RuntimeLog = .silent) {
        self.importer = importer
        self.log = log
    }

    /// Returns true when segments were actually imported.
    @discardableResult
    public func runIfNeeded() async throws -> Bool {
        guard let importer else { return false }
        switch try await importer.run() {
        case .completed(let stats):
            log.write(
                "legacy import: \(stats.segmentsIndexed) segments, "
                    + "\(stats.tasksEnqueued) tasks, \(stats.elapsedMs) ms"
            )
            return stats.segmentsIndexed > 0
        case .alreadyComplete:
            return false
        }
    }
}
