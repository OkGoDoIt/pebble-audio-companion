#if DEBUG
import Foundation
import SegmentStore
import Transcription

/// Simulator staging for the Storage screen: fills an EMPTY spool with a season of synthetic,
/// closed, transcribed recordings — one or two a day for 240 days, at the real 7 MB/h — so the
/// overview bar and the iCloud preview can be looked at with real proportions on a simulator
/// that has never seen a watch. Launch with `-storage.seed`. DEBUG only, refuses a non-empty
/// spool, and writes nothing a real launch would mistake for audio worth transcribing: every
/// segment is already `.complete`.
enum StorageSeed {
    static func seedIfRequested(root: URL, nowMs: Int64) {
        guard ProcessInfo.processInfo.arguments.contains("-storage.seed") else { return }
        let fm = FileManager.default
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        let existing = (try? fm.contentsOfDirectory(atPath: segments.path)) ?? []
        guard existing.isEmpty else { return }
        try? fm.createDirectory(at: segments, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // A transcript per segment, or the queue sees a "complete" recording with no words,
        // re-transcribes it, and parks it as Disabled on a simulator with no provider — at
        // which point nothing is eligible for iCloud and the preview says so.
        let transcripts = root.appendingPathComponent("transcription", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try? fm.createDirectory(at: transcripts, withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        let dayMs: Int64 = 86_400_000
        for day in 1...240 {
            let perDay = day % 3 == 0 ? 2 : 1
            for slot in 0..<perDay {
                // 20–70 minutes at 39 bytes per 20 ms frame.
                let minutes = Int64.random(in: 20...70, using: &generator)
                let frames = minutes * 60 * 50
                let bytes = frames * 39
                let started = nowMs - Int64(day) * dayMs + Int64(8 + slot * 6) * 3_600_000
                let id = "seed-\(day)-\(slot)"
                let meta = SegmentMeta(
                    segmentId: id, streamId: 0x5EED_0001, protocolVersion: 1, codecIdRaw: 1,
                    channels: 1, frameSamples: 320, sampleRateHz: 16000, bitRateBps: 9800,
                    frameDurationMs: 20, startTimeMs: UInt64(started), startMonotonicMs: 0,
                    receivedAtMs: started, firstSequence: 0, lastSequence: UInt32(frames - 1),
                    firstSampleIndex: 0, lastSampleIndexExclusive: UInt64(frames) * 320,
                    frameCount: frames, logBytes: bytes,
                    closeReason: CloseReasonMeta(kind: CloseReasonMeta.kindStopped),
                    closedAtMs: started + minutes * 60_000, transcriptionState: .complete,
                    recordedTimeZone: TimeZone.current.identifier)
                guard let json = try? encoder.encode(meta) else { continue }
                try? json.write(to: segments.appendingPathComponent(id + SegmentStore.metaSuffix))
                let transcript = SegmentTranscript(
                    segmentId: id, text: "Seeded recording \(id).", modeUsed: .localOnly,
                    providerId: "seed", createdAtMs: started + minutes * 60_000,
                    segments: [
                        TranscriptSegment(
                            text: "Seeded recording \(id).", startMs: 0, endMs: minutes * 60_000)
                    ])
                if let transcriptJSON = try? encoder.encode(transcript) {
                    try? transcriptJSON.write(
                        to: transcripts.appendingPathComponent(id + FileTranscriptStore.suffix))
                }
                // Zero bytes parse as empty records, so a stray read is harmless; the size is
                // what the screen measures.
                fm.createFile(
                    atPath: segments.appendingPathComponent(id + SegmentStore.logSuffix).path,
                    contents: Data(count: Int(bytes)))
            }
        }
    }
}
#endif
