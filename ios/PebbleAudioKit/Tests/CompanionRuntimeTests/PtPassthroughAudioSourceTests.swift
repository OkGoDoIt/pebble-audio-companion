import AudioCodec
import CompanionRuntime
import Foundation
import SegmentStore
import Testing
import Transcription

// What the upload path reads off disk, run against Roger's real spool.
//
// The claim worth checking here is not "passthrough is smaller" — `PtOggSpeexTests` proves that on
// the same data — but the claim that is easy to get quietly wrong: **the silence gate still sees
// exactly the audio it used to.**
//
// Before this change the gate measured the assembled WAV, because building that WAV was the whole
// reason the segment was decoded. Passthrough removes the reason, so the gate would have been the
// first casualty of "we no longer decode for upload": measure nothing and every provably silent
// recording starts being uploaded again, paid for, and answered with the sentences a provider
// invents out of room tone (`SegmentEnergy.provableSilenceFloorRms`). The audio source therefore
// still decodes — streaming, discarding as it goes — and hands the profile over. This asserts the
// two paths produce the identical profile on real segments, so the gate's verdict cannot have
// moved.
//
// Skips cleanly where the backup is absent, like the other real-library suites.

private let backupRoot =
    ProcessInfo.processInfo.environment["PEBBLE_SEGMENT_BACKUP_ROOT"]
    ?? NSHomeDirectory() + "/Desktop/PebbleAudioBackup/audio-companion-20260901-012413"

private var backupAvailable: Bool {
    FileManager.default.fileExists(
        atPath: backupRoot + "/segments", isDirectory: nil)
}

@Suite(
    "PT — the upload audio source on the real spool",
    .enabled(if: backupAvailable, "no PebbleAudioBackup on this machine")
)
struct PtPassthroughAudioSourceTests {
    private var files: SegmentFileReader { SegmentFileReader(root: URL(fileURLWithPath: backupRoot)) }

    /// A handful of real, non-trivial segments — enough to cover different content without
    /// decoding the whole 103-hour library twice.
    private func sampleSegmentIds(_ limit: Int) -> [String] {
        files.listSegments()
            .filter { !$0.isOpen && $0.frameCount > 2_000 }
            .suffix(limit)
            .map(\.segmentId)
    }

    @Test("the passthrough body is the watch's frames and no WAV is ever assembled")
    func passthroughSkipsThePcmBody() async throws {
        let source = BackgroundUploadWiring.audioSource(files: files)
        var checked = 0
        for segmentId in sampleSegmentIds(3) {
            let audio = try #require(await source(segmentId, .oggSpeex))
            let packaged = try #require(audio.packaged)
            #expect(packaged.format == .oggSpeex)
            #expect(packaged.bytes.prefix(4).elementsEqual("OggS".utf8))
            // The 28.9 MB `Data` this path used to hold, in a background window with a jetsam
            // ceiling, is simply not created.
            #expect(audio.wav.isEmpty)
            #expect(audio.energy != nil)
            let meta = try #require(files.readMeta(segmentId))
            // Deterministic, because every frame is 25 bytes: payload plus <5% of container.
            let wavBytes = Int(meta.frameCount) * meta.frameSamples * 2
            #expect(Double(packaged.bytes.count) / Double(wavBytes) < 0.05)
            checked += 1
        }
        #expect(checked == 3)
    }

    @Test("the gate sees the identical numbers whichever container is being sent")
    func theEnergyProfileIsUnchangedByPassthrough() async throws {
        let source = BackgroundUploadWiring.audioSource(files: files)
        var checked = 0
        for segmentId in sampleSegmentIds(3) {
            let passthrough = try #require(await source(segmentId, .oggSpeex))
            let pcmPath = try #require(await source(segmentId, .flac))
            #expect(pcmPath.packaged == nil)
            #expect(!pcmPath.wav.isEmpty)

            let floor = SegmentEnergy.provableSilenceFloorRms
            let streamed = passthrough.energyProfile(floorRms: floor)
            let fromWav = pcmPath.energyProfile(floorRms: floor)
            // Not "close": the same meter over the same samples, so the same profile.
            #expect(streamed == fromWav)
            #expect(
                streamed.isProvablySilent(floorRms: floor)
                    == fromWav.isProvablySilent(floorRms: floor))
            checked += 1
        }
        #expect(checked == 3)
    }

    @Test("a segment with no audio yields nothing rather than an empty upload")
    func missingAudioIsNotUploaded() async {
        let source = BackgroundUploadWiring.audioSource(files: files)
        #expect(await source("seg-does-not-exist", .oggSpeex) == nil)
        #expect(await source("seg-does-not-exist", .wav) == nil)
    }
}
