import Foundation
import SegmentStore

// Port of the `LiveAudioEvent` / `LiveAudioTap` half of `app/.../CloudLiveTranscriber.kt`.

/// Events teed off the receive path so a live cloud transcriber can stream the open segment.
public enum LiveAudioEvent: Sendable, Equatable {
    public struct SegmentOpened: Sendable, Equatable {
        public let segmentId: String
        public let sampleRateHz: Int
        public let bitRateBps: Int
        public let frameSamples: Int

        public init(segmentId: String, sampleRateHz: Int, bitRateBps: Int, frameSamples: Int) {
            self.segmentId = segmentId
            self.sampleRateHz = sampleRateHz
            self.bitRateBps = bitRateBps
            self.frameSamples = frameSamples
        }
    }

    case segmentOpened(SegmentOpened)
    case framesAppended(segmentId: String, frames: [SegmentFrame])
    case segmentClosed(segmentId: String)
}

/// Cheap fan-out of live audio events from the receive path (no decode on the receive path).
/// Kotlin used a `MutableSharedFlow(extraBufferCapacity = 512, DROP_OLDEST)`; each subscriber
/// stream here buffers the newest 512 events the same way.
public final class LiveAudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<LiveAudioEvent>.Continuation] = [:]

    public init() {}

    /// Events emitted after this call. The subscription is registered synchronously.
    public func events() -> AsyncStream<LiveAudioEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func emit(_ event: LiveAudioEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets {
            continuation.yield(event)
        }
    }
}
