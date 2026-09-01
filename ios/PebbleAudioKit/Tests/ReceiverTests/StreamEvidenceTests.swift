import Foundation
import Testing
import WireProtocol

@testable import Receiver

// What may and may not retire the `.streaming` latch.
//
// The whole risk in this area is replacing one false status with another. "No frames for N
// seconds → not recording" is itself a lie in this product: the watch stops its drain timer
// entirely while suppressing voice-activity silence and sends nothing at all — no frames, no gap
// record — until audio resumes. A quiet room produces exactly the same silence on the wire as a
// dead stream. Only the watch's own reported state tells them apart, so these cases exist mostly
// to pin that quiet is never demoted.

@Suite struct StreamEvidenceTests {

    private let streamingRaw = Int(ServiceState.streaming.rawValue)
    private let idleRaw = Int(ServiceState.authorizedIdle.rawValue)

    /// THE case. Forty-five minutes of suppressed silence, not one frame in all of it, and the
    /// card must still say Recording — because the watch keeps confirming it is capturing.
    ///
    /// A naive frame-age implementation fails this outright: `lastAudioAtMs` here is 45 minutes
    /// stale, so any rule that demotes on frame age alone would call an ordinary quiet room a
    /// failure and contradict the product's own taxonomy, where suppressed silence is calm quiet.
    @Test func ordinaryVadSilenceIsNeverDemoted() {
        let now: Int64 = 3_000_000
        let evidence = StreamEvidence(
            lastAudioAtMs: now - 45 * 60 * 1000,  // 45 minutes of quiet
            lastWatchReportAtMs: now - 8_000,  // the re-verify keeps asking
            lastWatchReportRaw: streamingRaw  // and the watch keeps saying yes
        )

        #expect(evidence.verdict(nowMs: now) == .watchSaysStreaming)
        #expect(evidence.verdict(nowMs: now).supportsRecording)
        // And it is quiet, not merely recording: the sub-line gets to say so.
        #expect(evidence.verdict(nowMs: now).isQuiet)
    }

    /// The re-verify cadence is what keeps the above true indefinitely. Walk an hour of silence
    /// in verify-sized steps, refreshing the report each time exactly as the session does, and
    /// the claim must hold at every single step.
    @Test func silenceStaysRecordingForAsLongAsTheWatchKeepsAnswering() {
        var now: Int64 = 1_000_000
        var evidence = StreamEvidence(
            lastAudioAtMs: now, lastWatchReportAtMs: now, lastWatchReportRaw: streamingRaw
        )
        for step in 0..<180 {  // 180 × 20 s = one hour
            now += 20_000
            evidence.lastWatchReportAtMs = now
            evidence.lastWatchReportRaw = streamingRaw
            #expect(
                evidence.verdict(nowMs: now).supportsRecording,
                "an hour of quiet must never demote while the watch confirms it is capturing")
            // Once the opening audio has aged out, the watch's answer is the ONLY thing holding
            // the claim up — which is the point: it is enough, on its own, forever.
            if step > 3 {
                #expect(evidence.verdict(nowMs: now) == .watchSaysStreaming)
            }
        }
    }

    /// The starved link — the four-hour blackout's shape. The watch answers RECEIVER_HEALTH the
    /// whole time (which is why the keepalive's failure count never trips), but answering is not
    /// recording, and no ACK may ever be mistaken for one. Only a *state report* counts, and
    /// there has not been one.
    @Test func aStarvedLinkLosesTheClaimAlthoughTheWatchKeepsAcking() {
        let now: Int64 = 5_000_000
        let evidence = StreamEvidence(
            lastAudioAtMs: now - 4 * 60 * 60 * 1000,
            lastWatchReportAtMs: now - 4 * 60 * 60 * 1000,  // the handshake, hours ago
            lastWatchReportRaw: streamingRaw  // and what it said then is no longer evidence
        )
        #expect(evidence.verdict(nowMs: now) == .unverified)
        #expect(!evidence.verdict(nowMs: now).supportsRecording)
        #expect(!evidence.verdict(nowMs: now).isQuiet)
    }

    /// The watch's watchdog tripped and it dropped to AuthorizedIdle. It said so; believe it at
    /// once rather than waiting out a timeout.
    @Test func theWatchSayingItStoppedIsBelievedImmediately() {
        let now: Int64 = 900_000
        let evidence = StreamEvidence(
            lastAudioAtMs: now - 90_000,
            lastWatchReportAtMs: now - 500,
            lastWatchReportRaw: idleRaw
        )
        #expect(evidence.verdict(nowMs: now) == .watchSaysNotStreaming)
        #expect(!evidence.verdict(nowMs: now).supportsRecording)
    }

    /// Audio arriving is its own proof, and outranks a watch report that has not caught up. At
    /// handshake the watch legitimately reports AuthorizedIdle moments before it starts sending;
    /// hearing the stream must win over that stale answer.
    @Test func arrivingAudioOutranksAStaleWatchReport() {
        let now: Int64 = 700_000
        let evidence = StreamEvidence(
            lastAudioAtMs: now - 300,
            lastWatchReportAtMs: now - 1_000,
            lastWatchReportRaw: idleRaw
        )
        #expect(evidence.verdict(nowMs: now) == .hearingAudio)
        #expect(evidence.verdict(nowMs: now).supportsRecording)
    }

    /// A session that has observed nothing at all claims nothing.
    @Test func noEvidenceSupportsNothing() {
        #expect(StreamEvidence.none.verdict(nowMs: 1_000) == .unverified)
        #expect(!StreamEvidence.none.verdict(nowMs: 1_000).supportsRecording)
    }

    /// A clock that jumped backwards is not evidence of freshness.
    @Test func futureDatedEvidenceIsNotTreatedAsFresh() {
        let evidence = StreamEvidence(
            lastAudioAtMs: 10_000, lastWatchReportAtMs: 10_000, lastWatchReportRaw: streamingRaw
        )
        #expect(evidence.verdict(nowMs: 1_000) == .unverified)
    }

    /// The two kinds of evidence must OVERLAP, or there is a window in which a perfectly healthy
    /// quiet stream is demoted between the audio lapsing and the first re-verify landing. Audio
    /// has to vouch for the stream for longer than it takes the session to notice the silence,
    /// ask, and hear back.
    @Test func audioEvidenceOutlastsTheFirstReVerifyRoundTrip() {
        let config = ReceiverConfig(receiverId: (0..<32).map { UInt8($0) }, receiverName: "t")
        let worstCaseFirstVerifyMs =
            AudioReceiverSession.verifyAfterSilenceMs + config.streamVerifyIntervalMs
            + AudioReceiverSession.verifyReadTimeoutMs
        #expect(StreamEvidence.audioMaxAgeMs > worstCaseFirstVerifyMs)
        // And one missed read must not flip the card either.
        #expect(StreamEvidence.reportMaxAgeMs > 2 * config.streamVerifyIntervalMs)
    }

    /// A watch state that is neither streaming nor decodable is not a claim to record.
    @Test func unknownWatchStatesDoNotSupportRecording() {
        let now: Int64 = 400_000
        for raw in [-1, 999, Int(ServiceState.idle.rawValue), Int(ServiceState.error.rawValue)] {
            let evidence = StreamEvidence(
                lastAudioAtMs: nil, lastWatchReportAtMs: now - 100, lastWatchReportRaw: raw
            )
            #expect(evidence.verdict(nowMs: now) == .watchSaysNotStreaming, "raw \(raw)")
        }
    }

    /// `.unchecked` is the escape hatch for previews and fixtures. It must read as "not weighed",
    /// never as a verdict — and in particular never as quiet.
    @Test func uncheckedTakesTheLatchAtFaceValueWithoutClaimingQuiet() {
        #expect(StreamVerdict.unchecked.supportsRecording)
        #expect(!StreamVerdict.unchecked.isQuiet)
    }
}
