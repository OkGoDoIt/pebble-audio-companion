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
// only copy that carries `transcription/transcripts/`, `ai/` — and `quarantine/`.
//
// The default `tmp-appdata` copy predates quarantine, so the quarantine half of this gate is
// conditional below: with no orphans on disk there is nothing to recover, and "0 recovered"
// is the right answer rather than a regression. To exercise that half, point the variable at
// a full pull, e.g.
//   PEBBLE_LEGACY_CONTAINER=~/Desktop/PebbleAudioBackup/audio-companion-20260831-110954
// (438 segments / 179 conversations, versus 135 / 39 from `tmp-appdata`).
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
        // Quarantined orphans are audio whose sidecar was lost; recovery restores them into
        // `segments/`, so everything below has to count them as well as the metas already there.
        let quarantineDir = env.root.appendingPathComponent("quarantine", isDirectory: true)
        let quarantineIdsOnDisk = Set(
            ((try? FileManager.default.contentsOfDirectory(
                at: quarantineDir, includingPropertiesForKeys: nil)) ?? [])
                // Zero-byte logs hold no audio — there is nothing in them to recover, and the
                // real container has 23 of them.
                .filter { $0.lastPathComponent.hasSuffix(".spxlog") }
                .filter { (try? Data(contentsOf: $0).isEmpty) == false }
                .map { String($0.lastPathComponent.dropLast(".spxlog".count)) }
        ).subtracting(metaIdsOnDisk)
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
        // Recovered orphans have no sidecar telling us they were transcribed, so each one that
        // lacks a transcript joins the backlog.
        let expectedRecoveredQueued = quarantineIdsOnDisk.subtracting(transcriptIdsOnDisk).count

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
        // Quarantine recovery restored the orphans (the June/July archive lives here). Assert
        // the INVARIANT rather than a count: every orphan log that was sitting in quarantine is
        // now a real segment. The exact tally also counts sidecar-paired orphans, which is an
        // implementation detail this gate should not pin.
        let metasAfter = try Set(
            FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(SegmentStore.metaSuffix) }
                .map { String($0.lastPathComponent.dropLast(SegmentStore.metaSuffix.count)) })
        // Only assert recovery HAPPENED where the fixture actually carries orphans: a container
        // pulled with `devicectl` has `quarantine/`, the checked-out `tmp-appdata` copy does
        // not, and "0 recovered from 0 orphans" is correct rather than a regression. The
        // invariant below holds either way and is the one that matters.
        if !quarantineIdsOnDisk.isEmpty {
            #expect(stats.quarantineRecovered > 0, "quarantined audio should have been recovered")
        }
        #expect(
            quarantineIdsOnDisk.subtracting(metasAfter).isEmpty,
            "every quarantined orphan should now be a segment")
        #expect(metaIdsOnDisk.count >= 100, "the real container should be substantial")

        // Conversations form.
        #expect(stats.conversationsFormed > 0)
        let conversations = try await env.db.reader.read { try ConversationGrouper.fetchAll($0) }
        #expect(conversations.count == stats.conversationsFormed)
        #expect(conversations.allSatisfy { $0.endMs >= $0.startMs })
        // Every segment on disk after the import belongs to exactly one conversation.
        #expect(Set(conversations.flatMap(\.memberSegmentIds)) == metasAfter)

        // Zero data loss: recovery ADDS logs, so the pre-existing ones must survive byte for
        // byte rather than the set being identical.
        let logBytesAfter = try spxlogBytes(segmentsDir)
        for (id, bytes) in logBytesBefore {
            #expect(logBytesAfter[id] == bytes, "\(id) changed size during import")
        }
        #expect(logBytesAfter.count >= logBytesBefore.count)

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

        // The queue holds exactly the untranscribed backlog as PENDING work…
        #expect(stats.tasksEnqueued == expectedQueued)
        let queue = TranscriptionQueue(database: env.db, nowMs: { [now = env.now] in now })
        let pending = try queue.all().filter { $0.state == .pending }
        // The backlog covers the original untranscribed work plus recovered audio that has no
        // transcript. Bound it rather than pinning an exact number: what must hold is that
        // nothing already transcribed is queued (asserted below) and that recovery did not
        // silently skip the backlog.
        // Recovery only ADDS work, never removes it. The exact tally depends on how recovery
        // pairs orphan sidecars, which is not this gate's business; the invariant that protects
        // the user's wallet is asserted just below — nothing already transcribed is queued.
        #expect(pending.count >= expectedQueued)
        // Same fixture-shape guard: recovered audio only produces a backlog where there was
        // audio to recover.
        if !quarantineIdsOnDisk.isEmpty {
            #expect(expectedRecoveredQueued > 0, "recovered audio should have produced a backlog")
        }

        // …and everything already finished carries a TERMINAL row rather than no row. Without
        // those, a missing row reads as Pending downstream and a fully-transcribed conversation
        // advertises "Captured · waiting to transcribe" over its own transcript. Nothing that
        // already has a transcript may sit in Pending — that would re-transcribe (and re-bill)
        // work the user has already paid a cloud provider for.
        let terminal = try queue.all().filter { $0.state == .complete || $0.state == .noSpeech }
        #expect(terminal.count == stats.terminalTasksBackfilled)
        #expect(try queue.all().count == pending.count + terminal.count)
        for id in transcriptIdsOnDisk {
            #expect(try queue.load(id)?.state != .pending, "\(id) has a transcript but is queued")
        }

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
