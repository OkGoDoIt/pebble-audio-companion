import AppDB
import Foundation
import GRDB
import SegmentStore
import Testing
import Transcription

@testable import Migration

// The M8 gate: import a COPY of the real legacy container (never the original). The copy at
// `tmp-appdata` is container-root-shaped (`segments/` + `queue/` at its top level; the real
// device copy also carries `transcription/transcripts/`). Skips cleanly where the directory
// is absent so CI elsewhere stays green.

// Override with PEBBLE_LEGACY_CONTAINER to run the gate against a container pulled off the
// phone (`xcrun devicectl device copy from --domain-type appDataContainer …`), which is the
// only copy that carries `transcription/transcripts/` and `ai/`.
private let realContainerPath =
    ProcessInfo.processInfo.environment["PEBBLE_LEGACY_CONTAINER"]
    ?? "/Users/roger/Repos/pebble/tmp-appdata"

private var realContainerAvailable: Bool {
    FileManager.default.fileExists(
        atPath: realContainerPath + "/segments", isDirectory: nil)
}

@Suite struct RealContainerImportTests {

    @Test(.enabled(if: realContainerAvailable))
    func importsRealContainerCopy() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        // Copy the real container into the temp root — the original is NEVER mutated.
        try FileManager.default.removeItem(at: env.root)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: realContainerPath), to: env.root)

        let segmentsDir = env.root.appendingPathComponent("segments", isDirectory: true)
        let metaIdsOnDisk = try Set(
            FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(SegmentStore.metaSuffix) }
                .map { String($0.lastPathComponent.dropLast(SegmentStore.metaSuffix.count)) })
        let logBytesBefore = try spxlogBytes(segmentsDir)
        let transcriptIdsOnDisk = transcriptIds(env.root)
        // The queue seeding expectation, computed from the PRE-import metas: every closed
        // segment that is not terminal-success-with-artifact gets a Pending row.
        let expectedQueued = try metaIdsOnDisk.filter { id in
            let meta = try readMetaFile(root: env.root, id: id)
            switch meta.transcriptionState {
            case .complete: return !transcriptIdsOnDisk.contains(id)
            case .noSpeech: return false
            default: return true
            }
        }.count

        let started = Date()
        let outcome = try await env.importer().run()
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        guard case .completed(let stats) = outcome else {
            Issue.record("expected a completed import")
            return
        }
        print(
            "real-container import: \(stats.segmentsIndexed) segments, "
                + "\(stats.conversationsFormed) conversations, "
                + "\(stats.transcriptsVerified) transcripts "
                + "(\(stats.transcriptsUnreadable) unreadable), "
                + "\(stats.tasksEnqueued) tasks (\(stats.completeMissingTranscriptRequeued) "
                + "requeued), \(stats.startTimesClamped) clamped, "
                + "\(stats.timeZonesBackfilled) zones backfilled, \(elapsedMs) ms")

        // Every segment indexes.
        #expect(stats.segmentsIndexed == metaIdsOnDisk.count)
        #expect(metaIdsOnDisk.count >= 100, "the real container should be substantial")

        // Conversations form.
        #expect(stats.conversationsFormed > 0)
        let conversations = try await env.db.reader.read { try ConversationGrouper.fetchAll($0) }
        #expect(conversations.count == stats.conversationsFormed)
        #expect(conversations.allSatisfy { $0.endMs >= $0.startMs })
        #expect(Set(conversations.flatMap(\.memberSegmentIds)) == metaIdsOnDisk)

        // Zero data loss: every frame log's byte count is unchanged (recovery found nothing to
        // truncate in the real data).
        #expect(try spxlogBytes(segmentsDir) == logBytesBefore)

        // Post-import invariants on every meta: the anchored start obeys the clamp bounds, the
        // timezone is backfilled, and audio extents are sane (longest real segment is a ~66 min
        // spool drain; rotation caps wall time, not audio time).
        for id in metaIdsOnDisk {
            let meta = try readMetaFile(root: env.root, id: id)
            #expect(meta.recordedTimeZone != nil, "\(id) missing timezone backfill")
            let rate = Int64(meta.sampleRateHz)
            let anchored =
                Int64(meta.startTimeMs) + Int64(meta.firstSampleIndex ?? 0) * 1000 / rate
            #expect(
                anchored <= meta.receivedAtMs + LegacyImporter.futureToleranceMs,
                "\(id) anchored start is in the future")
            #expect(
                anchored >= meta.receivedAtMs - LegacyImporter.pastToleranceMs,
                "\(id) anchored start is implausibly old")
            if let first = meta.firstSampleIndex, let last = meta.lastSampleIndexExclusive {
                // The sample-index span is WALL time, not audio time: the watch keeps advancing
                // sample_index across VAD-suppressed silence, so a segment can legitimately
                // span a quiet overnight with only seconds of speech in it (the real container
                // has one at 15.5 h / 6 s, and one at 4 h / 5 s with no gap records at all —
                // that hole IS the quiet, which is exactly how coverage derives it, plan 6.2).
                // Rotation caps a segment's 15 min of ACTIVITY, not the wall clock it straddles.
                // So bound the span by a logical day (real corruption looks like years or
                // negatives) and check the audio duration separately against the frame count.
                let spanMs = Int64(last - first) * 1000 / rate
                #expect(spanMs >= 0, "\(id) has a negative sample-index span \(spanMs) ms")
                #expect(spanMs <= 26 * 3_600_000,
                    "\(id) spans \(spanMs) ms — longer than a logical day")

                let audioMs = meta.frameCount * Int64(meta.frameDurationMs)
                #expect(audioMs >= 0 && audioMs <= spanMs + Int64(meta.frameDurationMs),
                    "\(id) claims \(audioMs) ms of audio inside a \(spanMs) ms span")
            }
        }

        // Every transcript that exists is still readable, in place.
        #expect(stats.transcriptsVerified == transcriptIdsOnDisk.count)
        #expect(stats.transcriptsUnreadable == 0)
        #expect(transcriptIds(env.root) == transcriptIdsOnDisk)

        // The queue holds exactly the untranscribed backlog.
        #expect(stats.tasksEnqueued == expectedQueued)
        let queue = TranscriptionQueue(database: env.db, nowMs: { [now = env.now] in now })
        #expect(try queue.all().count == expectedQueued)
        #expect(try queue.all().allSatisfy { $0.state == .pending })

        // And a second run is a no-op.
        let second = try await env.importer().run()
        #expect(second == .alreadyComplete(stats))
    }

    private func spxlogBytes(_ segmentsDir: URL) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for url in try FileManager.default.contentsOfDirectory(
            at: segmentsDir, includingPropertiesForKeys: [.fileSizeKey])
        where url.lastPathComponent.hasSuffix(SegmentStore.logSuffix) {
            out[url.lastPathComponent] =
                try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        return out
    }

    private func transcriptIds(_ root: URL) -> Set<String> {
        let dir =
            root
            .appendingPathComponent("transcription", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(
            entries
                .filter { $0.lastPathComponent.hasSuffix(FileTranscriptStore.suffix) }
                .map { String($0.lastPathComponent.dropLast(FileTranscriptStore.suffix.count)) })
    }
}
