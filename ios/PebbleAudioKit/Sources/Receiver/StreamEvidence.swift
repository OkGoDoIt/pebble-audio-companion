import Foundation
import WireProtocol

// What backs the claim "Recording", separated from the claim itself.
//
// `ReceiverSessionState.streaming` is a LATCH: STREAM_START sets it and only STREAM_STOP, a link
// drop or a revoke clears it. No arriving frame refreshes it and no timer demotes it, so a watch
// that goes quiet without a clean stop leaves the phone asserting "Recording" indefinitely — when
// the link is up but starved, when a STREAM_STOP or STATE_CHANGED is lost, when the watch's own
// liveness watchdog trips, or after the app is resumed from a long suspension.
//
// A frame timeout on its own cannot fix that, because THIS PRODUCT SUPPRESSES SILENCE. While the
// watch is in voice-activity silence suppression it stops its drain timer entirely and sends
// nothing at all — no frames, no gap record — until audio resumes, which in a quiet room is
// minutes or hours. "No frames for N seconds" would therefore call ordinary quiet a failure, which
// is exactly the confusion the four-state taxonomy exists to prevent.
//
// So the discriminator is THE WATCH'S OWN ANSWER, never inference:
//   * throughout suppressed silence the watch's service state stays `streaming` (it also skips its
//     own receiver-liveness check while suppressing), and
//   * when its liveness watchdog trips it stops capture and drops to `authorizedIdle`.
// Re-reading Info during data silence therefore tells quiet apart from loss with no guessing.
// Frame age is only ever the trigger to go and ask.

/// What the phone has actually observed lately about a stream it still believes is open.
public struct StreamEvidence: Sendable, Equatable {
    /// Wall clock of the last STREAM_START / STREAM_DATA / STREAM_GAP on the open stream.
    public var lastAudioAtMs: Int64?

    /// Wall clock of the last time the WATCH reported its own service state — the Info read at
    /// handshake, a STATE_CHANGED push, or a re-verify read during data silence.
    ///
    /// Deliberately NOT refreshed by an ACK. A starved link still ACKs RECEIVER_HEALTH while
    /// sending no audio at all (that is the shape of the four-hour blackout), so "the watch
    /// answered something" is no evidence that the watch is recording. Only a reported state is.
    public var lastWatchReportAtMs: Int64?

    /// What that report said (`ServiceState` raw value), or nil when the watch has not reported.
    public var lastWatchReportRaw: Int?

    public init(
        lastAudioAtMs: Int64? = nil,
        lastWatchReportAtMs: Int64? = nil,
        lastWatchReportRaw: Int? = nil
    ) {
        self.lastAudioAtMs = lastAudioAtMs
        self.lastWatchReportAtMs = lastWatchReportAtMs
        self.lastWatchReportRaw = lastWatchReportRaw
    }

    /// Nothing observed yet (a fresh session, or one whose link just went down).
    public static let none = StreamEvidence()

    /// True when the watch's last report said it is capturing.
    public var watchReportedStreaming: Bool {
        lastWatchReportRaw.flatMap { raw -> Bool? in
            guard raw >= 0, raw <= Int(UInt8.max) else { return nil }
            return ServiceState(rawValue: UInt8(raw)) == .streaming
        } ?? false
    }

    // MARK: - Thresholds
    //
    // Every bound here sits ABOVE the watch's silence-suppression window in the only sense that
    // matters: none of them can be crossed by silence alone, because the re-verify keeps the
    // watch's own report fresh for as long as the watch keeps answering. They are crossed only
    // when the watch stops answering or answers "not streaming".

    /// How long the arrival of audio alone vouches for the stream.
    ///
    /// Comfortably longer than the session's verify cadence plus a round trip, so an ordinary
    /// quiet stretch is already covered by a fresh watch report before this lapses — the two
    /// kinds of evidence overlap rather than leaving a window where neither holds.
    public static let audioMaxAgeMs: Int64 = 60_000

    /// How long the watch's own report of its state stands before it must be re-confirmed.
    /// Three verify cycles: one missed read never flips the card.
    public static let reportMaxAgeMs: Int64 = 60_000

    /// Weighs the evidence at `nowMs`. Pure — the caller supplies the clock.
    public func verdict(
        nowMs: Int64,
        audioMaxAgeMs: Int64 = StreamEvidence.audioMaxAgeMs,
        reportMaxAgeMs: Int64 = StreamEvidence.reportMaxAgeMs
    ) -> StreamVerdict {
        if let lastAudioAtMs, nowMs - lastAudioAtMs <= audioMaxAgeMs, nowMs >= lastAudioAtMs {
            return .hearingAudio
        }
        guard let lastWatchReportAtMs, nowMs - lastWatchReportAtMs <= reportMaxAgeMs,
            nowMs >= lastWatchReportAtMs
        else {
            return .unverified
        }
        return watchReportedStreaming ? .watchSaysStreaming : .watchSaysNotStreaming
    }
}

/// Whether a latched `.streaming` still has something behind it, and what.
public enum StreamVerdict: Sendable, Equatable {
    /// Audio arrived recently. The watch is streaming and we are hearing it.
    case hearingAudio

    /// No audio recently, but the watch itself says it is still capturing. This is the silence
    /// the product suppresses on purpose: calm quiet, never loss, and never demoted.
    case watchSaysStreaming

    /// The watch answered and said it is NOT capturing. It stopped without us hearing it stop.
    case watchSaysNotStreaming

    /// Neither recent audio nor a recent answer from the watch. Nothing supports the claim; the
    /// honest thing to say is that we are not hearing anything, not that recording stopped.
    case unverified

    /// No liveness evidence is being gathered at all — previews, artboard fixtures, and unit
    /// cases about some other axis. The latch is taken at face value. Production status call
    /// sites must never pass this; `LiveTodayDataSourceStatusSourceTests` pins that they don't.
    case unchecked

    /// True while the claim "Recording" is still supported by something observed.
    public var supportsRecording: Bool {
        switch self {
        case .hearingAudio, .watchSaysStreaming, .unchecked: return true
        case .watchSaysNotStreaming, .unverified: return false
        }
    }

    /// True when the stream is alive but deliberately sending nothing — the quiet the watch
    /// suppresses. The status card says so instead of implying a microphone that went dead.
    public var isQuiet: Bool { self == .watchSaysStreaming }
}
