import Foundation
import Testing

@testable import LiveAudio

// Port of `app/src/commonTest/.../SegmentPlaybackControllerTest.kt` — both cases, same names.
@Suite struct SegmentPlaybackControllerTests {

    private final class FakeDecoder: LiveFrameDecoder, @unchecked Sendable {
        private let lock = NSLock()
        private var _batchSizes: [Int] = []
        var batchSizes: [Int] { lock.withLock { _batchSizes } }

        func decode(_ frames: [[UInt8]]) async -> [Int16] {
            lock.withLock { _batchSizes.append(frames.count) }
            return frames.map { Int16($0[0]) }
        }
    }

    private final class FakePlayer: PcmAudioPlayer, @unchecked Sendable {
        private let lock = NSLock()
        private let onWrite: @Sendable (Int) async -> Void
        private var _writeSizes: [Int] = []
        private var _playbackSpeed: Float = 1
        private var _stopped = false

        var writeSizes: [Int] { lock.withLock { _writeSizes } }
        var playbackSpeed: Float { lock.withLock { _playbackSpeed } }
        var stopped: Bool { lock.withLock { _stopped } }

        init(onWrite: @escaping @Sendable (Int) async -> Void = { _ in }) {
            self.onWrite = onWrite
        }

        func start(sampleRateHz: Int) {
            lock.withLock { _stopped = false }
        }

        func write(_ pcm: [Int16]) async {
            let index: Int = lock.withLock {
                let value = _writeSizes.count
                _writeSizes.append(pcm.count)
                return value
            }
            await onWrite(index)
        }

        func setSpeed(_ speed: Float) {
            lock.withLock { _playbackSpeed = speed }
        }

        func stop() {
            lock.withLock { _stopped = true }
        }
    }

    @Test func playDecodesAndWritesInBoundedBatches() async throws {
        let firstWriteStarted = AsyncGate()
        let releaseFirstWrite = AsyncGate()
        let player = FakePlayer(onWrite: { index in
            if index == 0 {
                firstWriteStarted.open()
                await releaseFirstWrite.wait()
            }
        })
        let decoder = FakeDecoder()
        let controller = SegmentPlaybackController(
            playerFactory: { player },
            decoder: decoder,
            frameSource: { segmentId in
                precondition(segmentId == "seg-1")
                return (0..<30).map { [UInt8($0)] }
            }
        )

        controller.play("seg-1")
        await firstWriteStarted.wait()

        #expect(controller.state.playing)
        #expect(controller.state.segmentId == "seg-1")
        #expect(controller.state.durationMs == 600)
        #expect(decoder.batchSizes == [25])

        releaseFirstWrite.open()
        #expect(await waitUntil { !controller.state.playing })

        #expect(decoder.batchSizes == [25, 5])
        #expect(player.writeSizes == [25, 5])
        #expect(controller.state.positionMs == 0)
        #expect(player.stopped)
    }

    @Test func seekAndSpeedUpdateStateAndPlayer() async throws {
        let firstWriteStarted = AsyncGate()
        let releaseFirstWrite = AsyncGate()
        let player = FakePlayer(onWrite: { index in
            if index == 0 {
                firstWriteStarted.open()
                await releaseFirstWrite.wait()
            }
        })
        let controller = SegmentPlaybackController(
            playerFactory: { player },
            decoder: FakeDecoder(),
            frameSource: { _ in (0..<50).map { _ in [UInt8(1)] } }
        )

        controller.seekTo("seg-2", positionMs: 260)
        #expect(controller.state.positionMs == 260)

        controller.play("seg-2")
        await firstWriteStarted.wait()
        controller.seekTo("seg-2", positionMs: 800)
        controller.cycleSpeed()

        #expect(controller.state.speed == 1.5)
        #expect(player.playbackSpeed == 1.5)

        releaseFirstWrite.open()
        #expect(await waitUntil { !controller.state.playing })
    }
}
