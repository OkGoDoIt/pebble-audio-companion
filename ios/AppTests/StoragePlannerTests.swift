import CompanionRuntime
import Foundation
import SegmentStore
import Testing

/// The Storage screen's arithmetic: which bytes land in which row, and what the age picker's
/// preview says — the one number the iCloud switch turns on.
@Suite struct StoragePlannerTests {
    private static let day: Int64 = 86_400_000
    private let now: Int64 = 1_791_000_000_000

    private func segment(
        _ id: String, ageDays: Int64, bytes: Int64, state: TranscriptionState = .complete,
        cold: ColdStorageMeta? = nil, open: Bool = false
    ) -> SegmentMeta {
        let started = now - ageDays * Self.day
        return SegmentMeta(
            segmentId: id, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: UInt64(started), startMonotonicMs: 0, receivedAtMs: started,
            firstSequence: 0, lastSequence: UInt32(bytes / 39), firstSampleIndex: 0,
            lastSampleIndexExclusive: 320, frameCount: bytes / 39, logBytes: bytes,
            closeReason: open ? nil : CloseReasonMeta(kind: CloseReasonMeta.kindStopped),
            closedAtMs: open ? nil : started + 60_000, transcriptionState: state,
            coldStorage: cold)
    }

    private var library: [SegmentMeta] {
        [
            segment("a", ageDays: 200, bytes: 1_000, cold: ColdStorageMeta(movedAtMs: now, bytes: 1_000, state: ColdStorageMeta.stateEvicted)),
            segment("b", ageDays: 100, bytes: 2_000, cold: ColdStorageMeta(movedAtMs: now, bytes: 2_000)),
            segment("c", ageDays: 90, bytes: 3_000),
            segment("d", ageDays: 70, bytes: 4_000, state: .pending),
            segment("e", ageDays: 30, bytes: 5_000),
            segment("f", ageDays: 1, bytes: 6_000, open: true),
        ]
    }

    @Test func theOverviewCountsPhoneAndCloudSeparatelyAndUploadingAsBoth() {
        var footprint = StorageFootprint()
        footprint.transcriptBytes = 100
        footprint.databaseBytes = 20
        footprint.sidecarBytes = 5
        footprint.diagnosticsBytes = 1
        footprint.otherBytes = 4
        footprint.modelBytes = 700
        footprint.cacheBytes = 300
        footprint.temporaryBytes = 50
        footprint.freeBytes = 9_000
        footprint.capacityBytes = 100_000
        var cold = ColdAudioTier.Summary(available: true)
        cold.lastError = "quota"

        let overview = StoragePlanner.overview(metas: library, footprint: footprint, cold: cold)

        #expect(overview.recordingCount == 5, "the open segment is not a recording yet")
        #expect(overview.audioInCloudBytes == 1_000)
        #expect(overview.audioInCloudCount == 1)
        #expect(overview.uploadingBytes == 2_000)
        #expect(overview.uploadingCount == 1)
        // c + d + e, plus b which is still on the phone while it uploads.
        #expect(overview.audioOnPhoneBytes == 14_000)
        #expect(overview.audioBytes == 15_000)
        #expect(overview.textBytes == 130)
        #expect(overview.modelBytes == 1_000)
        #expect(overview.temporaryBytes == 50)
        #expect(overview.onPhoneBytes == 14_000 + 130 + 1_000 + 50)
        #expect(overview.cloudAvailable)
        #expect(overview.cloudError == "quota")
    }

    @Test func noFootprintAndNoTierIsStillAnHonestOverview() {
        let overview = StoragePlanner.overview(metas: library, footprint: nil, cold: nil)
        #expect(overview.audioOnPhoneBytes == 14_000)
        #expect(overview.textBytes == 0)
        #expect(overview.cloudAvailable == false)
        #expect(overview.freeBytes == 0)
    }

    /// The preview counts only what the rule WOULD move: closed, transcribed, old enough, and
    /// not already in iCloud. The share is of all audio, so it does not jump as audio moves.
    @Test func thePreviewFollowsTheAgeAndSkipsWhatCannotMove() {
        let audio: Int64 = 15_000
        let twoMonths = StoragePlanner.wouldMove(metas: library, olderThanDays: 60, nowMs: now, audioBytes: audio)
        #expect(twoMonths.bytes == 3_000, "c only: d is untranscribed, a and b already moved")
        #expect(twoMonths.count == 1)
        #expect(twoMonths.percent == 20)

        let twoWeeks = StoragePlanner.wouldMove(metas: library, olderThanDays: 14, nowMs: now, audioBytes: audio)
        #expect(twoWeeks.bytes == 8_000, "c and e; f is still open")
        #expect(twoWeeks.percent == 53)

        let year = StoragePlanner.wouldMove(metas: library, olderThanDays: 365, nowMs: now, audioBytes: audio)
        #expect(year == StoragePreview(bytes: 0, count: 0, percent: 0))
    }

    @Test func theBarNeverOverflowsAndNeverHidesASmallPart() {
        let widths = StorageBar.widths([1_000, 1, 0, 9_000], total: 10_000, in: 300)
        #expect(widths[2] == 0)
        #expect(widths[1] >= 3, "a 0.01% part is still drawn")
        #expect(widths.reduce(0, +) <= 300 - 2 * 1.5 + 0.01)
        #expect(StorageBar.widths([5, 5], total: 0, in: 300) == [0, 0])
    }

    @Test func ageLabelsReadTheWayPeopleSayThem() {
        #expect(Copy.Settings.Storage.ageLabel(14) == "2 weeks")
        #expect(Copy.Settings.Storage.ageLabel(30) == "1 month")
        #expect(Copy.Settings.Storage.ageLabel(60) == "2 months")
        #expect(Copy.Settings.Storage.ageLabel(180) == "6 months")
        #expect(Copy.Settings.Storage.ageLabel(365) == "1 year")
    }
}
