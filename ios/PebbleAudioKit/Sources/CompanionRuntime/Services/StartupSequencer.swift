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
    public var recoverQueue: @Sendable () async throws -> Void
    /// Returns the segment ids retention deleted, so the caller can cascade over them.
    public var enforceRetention: @Sendable () async throws -> [String]
    public var cascadeDeleted: @Sendable (String) async -> Void
    public var enqueueClosedSegments: @Sendable () async throws -> Void
    public var refreshDiagnostics: @Sendable () async -> Void

    public init(
        runLegacyImportIfNeeded: @escaping @Sendable () async throws -> Bool = { false },
        recoverStore: @escaping @Sendable () async throws -> Void = {},
        recoverQueue: @escaping @Sendable () async throws -> Void = {},
        enforceRetention: @escaping @Sendable () async throws -> [String] = { [] },
        cascadeDeleted: @escaping @Sendable (String) async -> Void = { _ in },
        enqueueClosedSegments: @escaping @Sendable () async throws -> Void = {},
        refreshDiagnostics: @escaping @Sendable () async -> Void = {}
    ) {
        self.runLegacyImportIfNeeded = runLegacyImportIfNeeded
        self.recoverStore = recoverStore
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
    private var recovered = false

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
        if recovered {
            onStep(.refreshDiagnostics)
            await steps.refreshDiagnostics()
            return
        }
        recovered = true

        onStep(.legacyImport)
        do { _ = try await steps.runLegacyImportIfNeeded() } catch {
            // A failed import must never block the app: the old container is left untouched and
            // the marker is not written, so the next launch retries.
            log.failure("legacy import", error)
        }

        onStep(.storeRecover)
        do { try await steps.recoverStore() } catch { log.failure("store recover", error) }

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
