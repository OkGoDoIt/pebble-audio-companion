import Foundation
import SegmentStore
import StatusUI
import WireProtocol

// Q9 — the ONE notification type in this product (plan Part 6.10). Everything about it is
// conservative: it fires retroactively, at most once an hour, only for losses a person would
// actually care about, and never for time the user deliberately paused or the watch spent quiet.

/// What caused the missing audio, in the only two flavours Q9 recognises.
public enum LossCause: String, Sendable, Equatable, Codable {
    /// The watch's spool filled while it could not reach the phone. Terminal by construction:
    /// the watch has already discarded that audio and told us how much.
    case spoolOverflow
    /// A visible-loss gap (link interruption / sequence discontinuity) at or over the threshold.
    case interruption
}

/// One qualifying loss, handed to the app layer to render as a notification.
public struct LossEvent: Sendable, Equatable {
    public let segmentId: String
    public let cause: LossCause
    /// Approximate wall duration of the missing audio.
    public let durationMs: Int64
    /// When the loss was *detected* (gap persisted), not when the audio went missing.
    public let detectedAtMs: Int64

    public init(segmentId: String, cause: LossCause, durationMs: Int64, detectedAtMs: Int64) {
        self.segmentId = segmentId
        self.cause = cause
        self.durationMs = durationMs
        self.detectedAtMs = detectedAtMs
    }
}

/// The app layer's notification seam.
///
/// The implementation (UNUserNotificationCenter) must request notification authorization on the
/// FIRST call, not during onboarding (Q9) — a permission prompt only makes sense once there is
/// something to say. It deep-links to `companion://today`.
public protocol LossNotifier: Sendable {
    func notifyAudioMissed(_ event: LossEvent) async
}

/// A `LossNotifier` that does nothing — the default when the app has not wired notifications.
public struct NoopLossNotifier: LossNotifier {
    public init() {}
    public func notifyAudioMissed(_ event: LossEvent) async {}
}

/// Q9 trigger mechanics (plan 6.10), evaluated retroactively at gap-persist time.
///
/// Qualifying: a single visible-loss record ≥ `thresholdMs` (30 s), OR a spool-overflow gap of
/// **any** length.
///
/// Excluded:
/// - **quiet** — VAD-suppressed silence is not loss; it never fires (`visibleLossGaps` filter).
/// - **paused** — while capture intent is not `.active`, missing audio is the user's own choice.
/// - **open segment (B21)** — a gap in the still-recording segment is deferred, not dropped:
///   B21's misfire was flagging an in-progress recording over a blip whose extent was not yet
///   settled. Deferred candidates are re-evaluated when the segment closes. The single exception
///   is spool overflow, which the watch has already finalized — waiting up to a rotation to say
///   "your watch couldn't reach the phone" would make the notification useless.
/// - **rate limit** — at most one notification per `rateLimitMs` (1 hour).
public actor LossEventEvaluator {
    public static let thresholdMs: Int64 = 30_000
    public static let rateLimitMs: Int64 = 60 * 60 * 1000

    private let notifier: any LossNotifier
    private let thresholdMs: Int64
    private let rateLimitMs: Int64
    /// Capture intent at evaluation time; `.paused`/`.off` suppress.
    private let captureIsActive: @Sendable () -> Bool
    /// True while the user is inside a pause interval (belt-and-braces with `captureIsActive`,
    /// since a pause journal row can outlive an intent flip during teardown).
    private let isPaused: @Sendable () async -> Bool

    private var lastFiredAtMs: Int64?
    /// segmentId -> best deferred candidate for that still-open segment.
    private var deferred: [String: LossEvent] = [:]

    public init(
        notifier: any LossNotifier,
        captureIsActive: @escaping @Sendable () -> Bool = { true },
        isPaused: @escaping @Sendable () async -> Bool = { false },
        thresholdMs: Int64 = LossEventEvaluator.thresholdMs,
        rateLimitMs: Int64 = LossEventEvaluator.rateLimitMs
    ) {
        self.notifier = notifier
        self.captureIsActive = captureIsActive
        self.isPaused = isPaused
        self.thresholdMs = thresholdMs
        self.rateLimitMs = rateLimitMs
    }

    /// Call once per persisted gap, AFTER the gap is durable in `meta` (so the visible-loss
    /// classifier sees the full gap list). Returns the event that fired, if any.
    @discardableResult
    public func gapPersisted(
        meta: SegmentMeta,
        gap: GapMeta,
        isSegmentOpen: Bool,
        nowMs: Int64
    ) async -> LossEvent? {
        guard let candidate = qualify(meta: meta, gap: gap, nowMs: nowMs) else { return nil }
        if await isSuppressedByPause() { return nil }

        // B21: defer an in-flight interruption to segment close; spool overflow is already final.
        if isSegmentOpen && candidate.cause != .spoolOverflow {
            let existing = deferred[meta.segmentId]
            if existing == nil || existing!.durationMs < candidate.durationMs {
                deferred[meta.segmentId] = candidate
            }
            return nil
        }
        return await fire(candidate)
    }

    /// Call when a segment closes: releases the deferred (B21-suppressed) candidate, if any.
    @discardableResult
    public func segmentClosed(segmentId: String, nowMs: Int64) async -> LossEvent? {
        guard var candidate = deferred.removeValue(forKey: segmentId) else { return nil }
        if await isSuppressedByPause() { return nil }
        candidate = LossEvent(
            segmentId: candidate.segmentId,
            cause: candidate.cause,
            durationMs: candidate.durationMs,
            detectedAtMs: nowMs
        )
        return await fire(candidate)
    }

    /// Drops deferred candidates for a segment that is going away (delete / retention).
    public func forget(segmentId: String) {
        deferred.removeValue(forKey: segmentId)
    }

    // --- internals ------------------------------------------------------------------------------

    private func qualify(meta: SegmentMeta, gap: GapMeta, nowMs: Int64) -> LossEvent? {
        // Quiet exclusion: VAD-suppressed silence is calm "quiet", never loss.
        guard isVisibleLossGap(gap, allGaps: meta.gaps) else { return nil }

        let reason = gap.reasonRaw
            .flatMap { $0 >= 0 && $0 <= Int(UInt8.max) ? GapReason(rawValue: UInt8($0)) : nil }
        // Paused exclusion in wire form: the watch stopped because the user asked it to.
        if reason == .userDisabled { return nil }

        let durationMs = gapDurationMs(gap, frameDurationMs: meta.frameDurationMs)
        let isSpoolOverflow = gap.origin == GapMeta.originWatch && reason == .spoolOverflow

        if isSpoolOverflow {
            return LossEvent(
                segmentId: meta.segmentId, cause: .spoolOverflow,
                durationMs: durationMs, detectedAtMs: nowMs
            )
        }
        guard durationMs >= thresholdMs else { return nil }
        return LossEvent(
            segmentId: meta.segmentId, cause: .interruption,
            durationMs: durationMs, detectedAtMs: nowMs
        )
    }

    private func isSuppressedByPause() async -> Bool {
        if !captureIsActive() { return true }
        return await isPaused()
    }

    private func fire(_ event: LossEvent) async -> LossEvent? {
        if let last = lastFiredAtMs, event.detectedAtMs - last < rateLimitMs { return nil }
        lastFiredAtMs = event.detectedAtMs
        await notifier.notifyAudioMissed(event)
        return event
    }
}
