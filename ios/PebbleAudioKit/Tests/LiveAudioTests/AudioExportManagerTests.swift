import Foundation
import SegmentStore
import Testing

@testable import LiveAudio

// Port of `app/src/commonTest/.../AudioExportManagerTest.kt` — both cases, same names.
@Suite struct AudioExportManagerTests {

    private func meta(segmentId: String = "seg-1", closed: Bool = true) -> SegmentMeta {
        SegmentMeta(
            segmentId: segmentId,
            streamId: 7,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 9_800,
            frameDurationMs: 20,
            startTimeMs: 0,
            startMonotonicMs: 0,
            receivedAtMs: 1234,
            frameCount: 2,
            closeReason: closed ? .rotated : nil
        )
    }

    private func frames() -> [FrameRecord] {
        [
            FrameRecord(sequence: 0, sampleIndex: 0, payload: [1]),
            FrameRecord(sequence: 1, sampleIndex: 320, payload: [2]),
        ]
    }

    @Test func exportSegmentWritesStandardWavFile() async throws {
        let segment = meta()
        let frameRecords = frames()
        let root = try makeTempRoot("audio-export")
        let manager = AudioExportManager(
            exportRoot: root,
            listSegments: { [segment] },
            readMeta: { _ in segment },
            readFrames: { _ in frameRecords },
            decodePcm: { meta, records in
                flowOf(Data(repeating: 7, count: meta.frameSamples * 2 * records.count))
            }
        )

        let result = try await manager.exportSegment(segment.segmentId)

        #expect(result.fileCount == 1)
        let exported = try #require(result.files.first)
        #expect(exported.path.hasSuffix(".wav"))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: exported.path))
        #expect(String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE")
        #expect(bytes.count == 44 + segment.frameSamples * 2 * frameRecords.count)
    }

    @Test func exportAllSkipsOpenSegments() async throws {
        let closed = meta(segmentId: "closed", closed: true)
        let open = meta(segmentId: "open", closed: false)
        let root = try makeTempRoot("audio-export")
        let manager = AudioExportManager(
            exportRoot: root,
            listSegments: { [closed, open] },
            readMeta: { id in [closed, open].first { $0.segmentId == id } },
            readFrames: { _ in frames() },
            decodePcm: { meta, records in
                flowOf(Data(count: meta.frameSamples * 2 * records.count))
            }
        )

        let result = try await manager.exportAllClosedSegments()

        #expect(result.fileCount == 1)
        #expect(result.skippedOpenSegments == 1)
        #expect(result.files.first?.segmentId == "closed")
    }
}
