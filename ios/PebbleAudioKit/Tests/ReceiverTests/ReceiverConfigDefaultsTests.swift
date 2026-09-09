import Receiver
import Testing

/// The production checkpoint cadence, pinned.
///
/// The cadence tests in `AudioReceiverSessionTests` construct their sessions with an explicit
/// 2 s / 500 ms schedule so they can drive the mechanism on virtual time. What ships is what the
/// composition root gets from the DEFAULTS, and those are a battery decision: a checkpoint is an
/// fsync, a GATT write and an ACK, and the old 500 ms wall rule made it two of each per second.
@Suite struct ReceiverConfigDefaultsTests {
    private let receiverId: [UInt8] = (0..<32).map { UInt8($0) }

    @Test func productionCheckpointsEveryThreeSecondsNotTwiceASecond() {
        let config = ReceiverConfig(receiverId: receiverId, receiverName: "Audio Companion")
        #expect(config.checkpointAudioMs == 3_000)
        #expect(config.checkpointMinIntervalMs == 3_000)
    }

    /// The watch's receiver-liveness window is 15 s and is re-armed only by our control traffic,
    /// of which checkpoints are the whole of a streaming session's share. The cadence must
    /// therefore stay well inside that window, and inside the 5 s keepalive that covers idle.
    @Test func checkpointCadenceStaysInsideTheWatchLivenessWindow() {
        let config = ReceiverConfig(receiverId: receiverId, receiverName: "Audio Companion")
        #expect(config.checkpointAudioMs <= config.keepaliveIntervalMs)
        #expect(config.checkpointMinIntervalMs <= config.keepaliveIntervalMs)
        #expect(config.keepaliveIntervalMs * 3 <= 15_000)
    }
}
