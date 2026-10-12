import CompanionRuntime
import Foundation
import SegmentStore
import Testing

/// The Storage card on Diagnostics: which measured buckets land in which row, and that the two
/// storage faults are worded as what they mean for the audio rather than as alarms.
@Suite struct DiagnosticStorageTests {
    /// The phone on 2026-10-12, in round numbers.
    private var phone: StorageFootprint {
        var f = StorageFootprint()
        f.audioBytes = 2_100_000_000
        f.audioFiles = 3_799
        f.sidecarBytes = 12_000_000
        f.transcriptBytes = 300_000_000
        f.databaseBytes = 26_000_000
        f.diagnosticsBytes = 2_000_000
        f.otherBytes = 100_000
        f.modelBytes = 1_170_000_000
        f.cacheBytes = 1_190_000_000
        f.temporaryBytes = 6_190_000_000
        f.freeBytes = 14_400_000_000
        f.capacityBytes = 512_000_000_000
        return f
    }

    @Test func theRowsSplitTheContainerTheWayAPersonAsks() {
        let card = DiagnosticStorage.describe(
            phone, pauseRequested: false, lowStorage: false,
            pauseFloorBytes: RetentionConfig.defaultPauseFloorBytes, writeFailure: nil)
        #expect(card.recordings.hasPrefix("2.1 GB"))
        #expect(card.recordings.hasSuffix("3,799 files"))
        // Transcripts + database + sidecars + diagnostics + loose files, never the audio.
        #expect(card.textAndIndex.hasPrefix("340"))
        #expect(card.model.hasPrefix("2.3") || card.model.hasPrefix("2.4"))
        #expect(card.temporary.hasPrefix("6.2 GB"))
        #expect(card.free.contains(" of "))
        #expect(card.pausedLine == nil)
        #expect(card.lowLine == nil)
        #expect(card.writeFailure == nil)
    }

    /// The pause floor is the one protective step now that nothing is deleted by default, so
    /// it is named with its threshold — and "low" gives way to "paused" rather than stacking.
    @Test func theFloorsAreNamedWithTheirThreshold() {
        let low = DiagnosticStorage.describe(
            phone, pauseRequested: false, lowStorage: true,
            pauseFloorBytes: RetentionConfig.defaultPauseFloorBytes, writeFailure: nil)
        #expect(low.lowLine?.contains("1 GB") == true)
        #expect(low.pausedLine == nil)

        let paused = DiagnosticStorage.describe(
            phone, pauseRequested: true, lowStorage: true,
            pauseFloorBytes: RetentionConfig.defaultPauseFloorBytes, writeFailure: nil)
        #expect(paused.pausedLine?.contains("1 GB") == true)
        #expect(paused.lowLine == nil, "paused already says it; a second row is noise")
    }

    /// "Couldn't save" on its own reads as "lost". The detail has to say the audio is still on
    /// the watch, because it is: nothing was acknowledged.
    @Test func aRefusedWriteSaysTheAudioIsNotLost() {
        let failure = StoreWriteFailure(
            atMs: 1_791_000_000_000, segmentId: "seg-1", operation: "frame log append",
            reason: "ENOSPC", isStorageFull: true)
        let card = DiagnosticStorage.describe(
            phone, pauseRequested: true, lowStorage: true,
            pauseFloorBytes: RetentionConfig.defaultPauseFloorBytes, writeFailure: failure)
        let fault = try! #require(card.writeFailure)
        #expect(fault.title == "Couldn’t save a recording")
        #expect(fault.detail.contains("Phone storage was full"))
        #expect(fault.detail.contains("the watch keeps that audio"))

        let other = DiagnosticStorage.describe(
            phone, pauseRequested: false, lowStorage: false,
            pauseFloorBytes: RetentionConfig.defaultPauseFloorBytes,
            writeFailure: StoreWriteFailure(
                atMs: 1_791_000_000_000, segmentId: "seg-1", operation: "flush", reason: "EIO",
                isStorageFull: false))
        #expect(other.writeFailure?.detail.contains("refused a write") == true)
    }

    /// The support report carries the same rows, so a reader who was not there sees them.
    @Test func theReportBlockCarriesEveryRow() {
        let card = DiagnosticStorage.describe(
            phone, pauseRequested: true, lowStorage: true,
            pauseFloorBytes: RetentionConfig.defaultPauseFloorBytes,
            writeFailure: StoreWriteFailure(
                atMs: 1_791_000_000_000, segmentId: "seg-1", operation: "frame log append",
                reason: "ENOSPC", isStorageFull: true))
        let block = card.reportLines
        #expect(block.hasPrefix("Storage: recordings 2.1 GB"))
        #expect(block.contains("temporary 6.2 GB"))
        #expect(block.contains("\nRecording paused: "))
        #expect(block.contains("\nCouldn’t save a recording: "))
        #expect(block.hasSuffix("\n"))
    }
}
