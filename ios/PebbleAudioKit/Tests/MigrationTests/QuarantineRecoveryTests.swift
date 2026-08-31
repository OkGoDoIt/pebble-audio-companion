import AppDB
import Foundation
import GRDB
import SegmentStore
import Testing
import Transcription

@testable import Migration

// Phase 4: orphan audio in `quarantine/` — logs whose sidecar was lost — is restored to
// `segments/` with reconstructed metadata. On the real container this is 298 logs / ~40 h of
// audio reaching back to 2026-06-12, which is the difference between "my library starts on
// August 2" and the library Roger expected.

@Suite struct QuarantineRecoveryTests {

    // MARK: - Id parsing

    @Test func segmentIdCarriesReceiveTimeAndStream() throws {
        let parsed = try #require(ParsedSegmentId.parse("seg-1781303238897-5dd250fc-1"))
        #expect(parsed.receivedAtMs == 1_781_303_238_897)
        #expect(parsed.streamId == 0x5DD2_50FC)
    }

    @Test func malformedIdsAreRejectedRatherThanGuessed() {
        // Truncated copies and stray files really are present in the container.
        #expect(ParsedSegmentId.parse("seg-1782517475186-e4c62ed5-15.spxlo") == nil)
        #expect(ParsedSegmentId.parse("seg-1781303238897-5dd250fc-1-action") == nil)
        #expect(ParsedSegmentId.parse("seg-1781303238897-5dd250fc") == nil)
        #expect(ParsedSegmentId.parse("seg-notanumber-5dd250fc-1") == nil)
        #expect(ParsedSegmentId.parse("seg-1781303238897-zzzzzzzz-1") == nil)
    }

    // MARK: - Reconstruction

    @Test func orphanLogIsRestoredWithMetadataDerivedFromItsFrames() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let id = "seg-1781303238897-5dd250fc-1"
        let written = try writeQuarantinedLog(
            root: env.root, id: id, firstSampleIndex: 3_200, frameCount: 50)

        let outcome = try await env.importer().run()

        #expect(outcome.stats.quarantineRecovered == 1)
        #expect(outcome.stats.quarantineFramesRecovered == 50)
        // 50 frames × 320 samples ÷ 16 kHz = 1 s.
        #expect(outcome.stats.quarantineAudioMs == 1_000)

        let meta = try readMetaFile(root: env.root, id: id)
        #expect(meta.frameCount == 50)
        #expect(meta.logBytes == Int64(written.data.count))
        #expect(meta.firstSampleIndex == 3_200)
        #expect(meta.lastSampleIndexExclusive == 3_200 + 50 * 320)
        #expect(meta.firstSequence == 10)
        #expect(meta.lastSequence == 59)
        #expect(meta.streamId == 0x5DD2_50FC)
        #expect(meta.receivedAtMs == 1_781_303_238_897)
        #expect(meta.frameSamples == 320)
        #expect(meta.closeReason == .interrupted)
        #expect(meta.transcriptionState == .pending)
        #expect(meta.recordedTimeZone == "America/New_York")
        #expect(meta.isRecovered)

        // The anchored start (the store's wall-clock rule) lands exactly on the receive time,
        // which is also what the phase-1 clamp would have enforced.
        let anchored =
            Int64(meta.startTimeMs) + Int64(meta.firstSampleIndex ?? 0) * 1000
            / Int64(meta.sampleRateHz)
        #expect(anchored == meta.receivedAtMs)
        #expect(LegacyImporter.clampedStartTimeMs(meta) == nil)

        // The audio itself moved, byte for byte, and nothing is left behind to double-import.
        let restored = try Data(
            contentsOf: env.root
                .appendingPathComponent("segments", isDirectory: true)
                .appendingPathComponent("\(id)\(SegmentStore.logSuffix)"))
        #expect(restored == written.data)
        #expect(quarantineContents(root: env.root).isEmpty)
    }

    @Test func unrecordedHolesBecomeExplicitLossNotQuiet() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let id = "seg-1781303238897-5dd250fc-1"
        // 20 frames, with 7 missing after the 10th.
        try writeQuarantinedLog(
            root: env.root, id: id, frameCount: 20, holeAfter: 10, holeFrames: 7)

        _ = try await env.importer().run()

        let meta = try readMetaFile(root: env.root, id: id)
        #expect(meta.frameCount == 20)
        let gap = try #require(meta.gaps.first)
        #expect(meta.gaps.count == 1)
        #expect(gap.firstMissingSequence == 10)
        #expect(gap.missingFrameCount == 7)
        #expect(gap.firstMissingSampleIndex == 10 * 320)
        // `sequence_skip` with no reason is ALWAYS visible loss (CoverageComputer): a lost
        // sidecar cannot prove the hole was VAD silence, and coverage would otherwise render it
        // as calm "quiet" — claiming clean coverage this audio has not earned.
        #expect(gap.origin == GapMeta.originSequenceSkip)
        #expect(gap.reasonRaw == nil)
    }

    @Test func sidecarQuarantinedBesideItsLogKeepsItsRealGaps() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let id = "seg-1781326115813-17f563c9-3"
        try writeQuarantinedLog(
            root: env.root, id: id, frameCount: 20, holeAfter: 10, holeFrames: 7)
        // The real container has 11 such pairs. Their gap records are REAL — every one in this
        // container is a spool-overflow loss (reason 1) — so nothing may be synthesized over
        // them, and the watch's own attribution survives instead of a generic sequence_skip.
        let realGap = GapMeta(
            firstMissingSequence: 10, missingFrameCount: 7, firstMissingSampleIndex: 3_200,
            origin: GapMeta.originWatch, reasonRaw: 1)
        let sidecar = makeLegacyMeta(
            id: id, startTimeMs: 1_781_326_115_813, receivedAtMs: 1_781_326_115_813,
            frameCount: 20, logBytes: 0, transcriptionState: .complete)
        var stored = sidecar
        stored.gaps = [realGap]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(
            to: env.root
                .appendingPathComponent("quarantine", isDirectory: true)
                .appendingPathComponent("\(id)\(SegmentStore.metaSuffix)"))

        let outcome = try await env.importer().run()

        #expect(outcome.stats.quarantineRecovered == 1)
        #expect(outcome.stats.quarantineSidecarsRestored == 1)
        let meta = try readMetaFile(root: env.root, id: id)
        #expect(meta.gaps == [realGap])
        #expect(meta.isRecovered)
        // Extents still reconcile against the log.
        #expect(meta.frameCount == 20)
        #expect(quarantineContents(root: env.root).isEmpty)
    }

    @Test func recoveredSegmentWithATranscriptIsNeverRetranscribed() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let transcribed = "seg-1781303238897-5dd250fc-1"
        let untranscribed = "seg-1781309068556-375637ed-1"
        try writeQuarantinedLog(root: env.root, id: transcribed, frameCount: 30)
        try writeQuarantinedLog(root: env.root, id: untranscribed, frameCount: 30)
        // Transcripts are keyed by segment id, which is why recovery must keep the original id.
        try writeLegacyTranscript(root: env.root, segmentId: transcribed, text: "already done")

        let outcome = try await env.importer().run()

        #expect(outcome.stats.quarantineRecovered == 2)
        #expect(outcome.stats.quarantineAlreadyTranscribed == 1)
        #expect(outcome.stats.quarantineQueuedForTranscription == 1)
        #expect(try readMetaFile(root: env.root, id: transcribed).transcriptionState == .complete)
        #expect(try readMetaFile(root: env.root, id: untranscribed).transcriptionState == .pending)

        let queue = TranscriptionQueue(database: env.db, nowMs: { [now = env.now] in now })
        #expect(try queue.load(untranscribed)?.state == .pending)
        // The already-transcribed one gets the terminal row that keeps the Library honest, not
        // a Pending one that would re-bill the provider for work already paid for.
        #expect(try queue.load(transcribed)?.state == .complete)
    }

    @Test func recoveredSegmentsQueueBehindTheExistingBacklog() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let waiting = "seg-1781000000000-aaaaaaaa-1"
        let recovered = "seg-1780000000000-5dd250fc-1"  // ~2 weeks older
        try writeLegacySegment(
            root: env.root, id: waiting,
            startTimeMs: 1_781_000_000_000, receivedAtMs: 1_781_000_000_000)
        try writeQuarantinedLog(root: env.root, id: recovered, frameCount: 30)

        _ = try await env.importer().run()

        let queue = TranscriptionQueue(database: env.db, nowMs: { [now = env.now] in now })
        // `nextRunnable` takes the NEWEST pending task. A recovered task is stamped with the age
        // of its own audio, so the recording the user is actually waiting on transcribes first
        // and 40 h of recovered June audio drains behind it — a visible backlog, not a queue
        // jump and not a silent spend.
        #expect(try queue.nextRunnable()?.segmentId == waiting)
        #expect(try queue.load(recovered)?.createdAtMs == 1_780_000_000_000)
        #expect(try queue.all().count == 2)
    }

    @Test func malformedQuarantineFilenamesAreSkippedNotGuessed() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        try writeQuarantinedLog(root: env.root, id: "seg-1781303238897-5dd250fc-1", frameCount: 10)
        let dir = env.root.appendingPathComponent("quarantine", isDirectory: true)
        for junk in [
            "seg-1782517475186-e4c62ed5-15.spxlo", "seg-1782347899700-bb0033b8-4.meta.j",
            "seg-1783789079415-336a9b09-2.meta.js", "seg-1781303238897-5dd250fc-1-action",
        ] {
            try Data("truncated".utf8).write(to: dir.appendingPathComponent(junk))
        }

        let outcome = try await env.importer().run()

        #expect(outcome.stats.quarantineRecovered == 1)
        #expect(outcome.stats.quarantineSkippedMalformed == 4)
        // Untouched, not deleted — a truncated name is not ours to interpret.
        #expect(quarantineContents(root: env.root).count == 4)
    }

    @Test func emptyOrGarbageLogIsSkipped() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let dir = env.root.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(
            to: dir.appendingPathComponent("seg-1781303238897-5dd250fc-1\(SegmentStore.logSuffix)"))

        let outcome = try await env.importer().run()

        #expect(outcome.stats.quarantineRecovered == 0)
        #expect(outcome.stats.quarantineSkippedUnreadable == 1)
    }

    // MARK: - Retention

    @Test func recoveredAudioSurvivesTheRetentionAgeSweep() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let recovered = "seg-1781303238897-5dd250fc-1"  // 2026-06-12, far outside 30 days
        let ordinary = "seg-1781400000000-bbbbbbbb-1"
        try writeQuarantinedLog(root: env.root, id: recovered, frameCount: 30)
        try writeLegacySegment(
            root: env.root, id: ordinary, startTimeMs: 1_781_400_000_000,
            receivedAtMs: 1_781_400_000_000)

        _ = try await env.importer().run()

        // "Now" is ~2.5 months after both segments: the age rule would delete them both.
        let now: Int64 = 1_788_000_000_000
        let store = SegmentStore(root: env.root, nowMs: { now })
        try await store.recover()
        let retention = RetentionManager(
            store: store, freeSpace: PlentyOfSpace(), nowMs: { now },
            config: RetentionConfig(maxAgeMs: 30 * 24 * 60 * 60 * 1000))

        let deleted = try await retention.enforce()

        // Recovering June audio and then deleting it on the next sweep would be worse than not
        // recovering it. The retention SETTING is untouched — only the files this recovery
        // restored are exempt, and only from the age rule.
        #expect(deleted == [ordinary])
        #expect(await store.listSegments().map(\.segmentId) == [recovered])
    }

    // MARK: - Idempotence

    @Test func secondRunRecoversNothingTwice() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        try writeQuarantinedLog(root: env.root, id: "seg-1781303238897-5dd250fc-1", frameCount: 30)

        let first = try await env.importer().run()
        guard case .completed(let stats) = first else {
            Issue.record("expected a completed import")
            return
        }
        #expect(stats.quarantineRecovered == 1)

        let second = try await env.importer().run()
        #expect(second == .alreadyComplete(stats))
        #expect(try await env.db.reader.read { try ConversationGrouper.fetchAll($0) }.count == 1)
    }

    /// A v1 marker (the state Roger's phone is in: migration finished, before this phase
    /// existed) must run the NEW phase on the live container without redoing — or undoing —
    /// anything the v1 run did.
    @Test func alreadyMigratedContainerRunsOnlyTheNewPhases() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        try writeLegacySegment(
            root: env.root, id: "seg-1786000000000-aaaaaaaa-1",
            startTimeMs: 1_786_000_000_000, receivedAtMs: 1_786_000_000_000,
            transcriptionState: .complete)
        try writeLegacyTranscript(root: env.root, segmentId: "seg-1786000000000-aaaaaaaa-1")

        // Simulate the v1 marker exactly as the shipped importer wrote it.
        let v1: [String: Any] = [
            "version": 1, "segmentsDone": true, "databaseDone": true, "settingsDone": true,
            "completedAtMs": 1_787_000_000_000,
        ]
        try JSONSerialization.data(withJSONObject: v1, options: [.sortedKeys]).write(
            to: env.root.appendingPathComponent(LegacyImporter.markerFileName))

        try writeQuarantinedLog(root: env.root, id: "seg-1781303238897-5dd250fc-1", frameCount: 30)

        let outcome = try await env.importer().run()

        guard case .completed(let stats) = outcome else {
            Issue.record("a v1 marker must not short-circuit as already complete")
            return
        }
        #expect(stats.quarantineRecovered == 1)
        // The v1 phases stayed done: no re-normalization, no re-bootstrap counters.
        #expect(stats.segmentsIndexed == 0)
        #expect(stats.transcriptsVerified == 0)
        #expect(!stats.receiverIdMigrated)
        // …but the v2 phases did their work on the live container.
        #expect(stats.terminalTasksBackfilled == 1)
        #expect(stats.conversationsFormed == 2)
    }
}

private struct PlentyOfSpace: FreeSpaceProvider {
    func freeBytes() -> Int64 { 100 * 1024 * 1024 * 1024 }
}

// MARK: - Real quarantine gate

// Runs the recovery against a COPY of the real `quarantine/` directory and checks every restored
// sidecar against an independent scan of the ORIGINAL log (opened read-only, never written).
private let realQuarantinePath =
    ProcessInfo.processInfo.environment["PEBBLE_LEGACY_QUARANTINE"]
    ?? "/Users/roger/Desktop/PebbleAudioBackup/audio-companion-20260831-110954/quarantine"

private var realQuarantineAvailable: Bool {
    FileManager.default.fileExists(atPath: realQuarantinePath, isDirectory: nil)
}

@Suite struct RealQuarantineRecoveryTests {

    /// Independent reference scan of the raw record layout, deliberately NOT sharing code with
    /// the importer so the assertions test the recovery rather than agree with it.
    private func referenceScan(_ url: URL) -> (frames: Int, validBytes: Int, span: Int)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        var offset = 0
        var sequences: [UInt32] = []
        while offset + 14 <= bytes.count {
            var sequence: UInt32 = 0
            for index in 0..<4 { sequence |= UInt32(bytes[offset + index]) << (8 * index) }
            var length = 0
            for index in 0..<2 { length |= Int(bytes[offset + 12 + index]) << (8 * index) }
            if length > 200 || offset + 14 + length > bytes.count { break }
            sequences.append(sequence)
            offset += 14 + length
        }
        guard let low = sequences.min(), let high = sequences.max() else { return nil }
        return (sequences.count, offset, Int(high - low) + 1)
    }

    @Test(.enabled(if: realQuarantineAvailable))
    func recoversTheRealQuarantineDirectory() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let source = URL(fileURLWithPath: realQuarantinePath)
        try FileManager.default.copyItem(
            at: source, to: env.root.appendingPathComponent("quarantine", isDirectory: true))

        let originals = try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)
        let logs = originals.filter { $0.lastPathComponent.hasSuffix(SegmentStore.logSuffix) }
        var reference: [String: (frames: Int, validBytes: Int, span: Int)] = [:]
        var emptyLogs = 0
        for url in logs {
            let id = String(url.lastPathComponent.dropLast(SegmentStore.logSuffix.count))
            if let scan = referenceScan(url) { reference[id] = scan } else { emptyLogs += 1 }
        }
        // Sidecars that were quarantined alongside their log keep their REAL gap records; only
        // the rest have holes synthesized, so the two are asserted differently below.
        let withSidecar = Set(
            originals.filter { $0.lastPathComponent.hasSuffix(SegmentStore.metaSuffix) }
                .map { String($0.lastPathComponent.dropLast(SegmentStore.metaSuffix.count)) })
        #expect(logs.count >= 100, "the real quarantine directory should be substantial")

        let outcome = try await env.importer().run()
        guard case .completed(let stats) = outcome else {
            Issue.record("expected a completed import")
            return
        }
        print(
            "real quarantine recovery: \(stats.quarantineRecovered) segments, "
                + "\(stats.quarantineFramesRecovered) frames, "
                + "\(stats.quarantineAudioMs / 60_000) min of audio, "
                + "\(stats.quarantineSidecarsRestored) sidecars restored, "
                + "\(stats.quarantineAlreadyTranscribed) already transcribed, "
                + "\(stats.quarantineQueuedForTranscription) queued, "
                + "\(stats.quarantineSkippedMalformed) malformed names skipped, "
                + "\(stats.quarantineSkippedUnreadable) unreadable, "
                + "\(stats.conversationsFormed) conversations")

        #expect(stats.quarantineRecovered == reference.count)
        var totalFrames: Int64 = 0
        for (id, scan) in reference {
            let meta = try readMetaFile(root: env.root, id: id)
            #expect(meta.frameCount == Int64(scan.frames), "\(id) frame count")
            #expect(meta.logBytes == Int64(scan.validBytes), "\(id) log bytes")
            #expect(meta.isRecovered, "\(id) missing the recovery marker")
            #expect(meta.recordedTimeZone != nil, "\(id) missing timezone backfill")
            #expect(meta.closeReason != nil, "\(id) left open")
            // Duration follows the frames: 20 ms each at 320 samples / 16 kHz.
            let audioMs = meta.frameCount * Int64(meta.frameDurationMs)
            #expect(audioMs == Int64(scan.frames) * 20, "\(id) duration")
            // The anchored start obeys the same invariant phase 1 enforces on every sidecar.
            let anchored =
                Int64(meta.startTimeMs) + Int64(meta.firstSampleIndex ?? 0) * 1000
                / Int64(meta.sampleRateHz)
            #expect(anchored <= meta.receivedAtMs + LegacyImporter.futureToleranceMs, "\(id)")
            #expect(anchored >= meta.receivedAtMs - LegacyImporter.pastToleranceMs, "\(id)")
            // Every unexplained hole is accounted for as loss, never left to read as quiet.
            if !withSidecar.contains(id) {
                let missing = meta.gaps.reduce(0) { $0 + Int($1.missingFrameCount) }
                #expect(missing == scan.span - scan.frames, "\(id) unaccounted holes")
                #expect(
                    meta.gaps.allSatisfy { $0.origin == GapMeta.originSequenceSkip },
                    "\(id) synthesized a gap that is not explicit loss")
            }
            totalFrames += meta.frameCount
        }
        #expect(stats.quarantineFramesRecovered == totalFrames)
        #expect(stats.quarantineAudioMs == totalFrames * 20)

        // Every log with audio in it is consumed. What stays behind is exactly what has nothing
        // to recover: zero-byte logs, truncated file names from an interrupted copy, and the
        // sidecars belonging to those. Nothing is deleted — a name we cannot read is not ours
        // to interpret, and an empty file is not evidence of anything.
        #expect(stats.quarantineSkippedUnreadable == emptyLogs)
        let leftBehind = quarantineContents(root: env.root)
        #expect(
            leftBehind.filter { $0.hasSuffix(SegmentStore.logSuffix) }.count == emptyLogs)
        #expect(stats.quarantineSidecarsRestored == withSidecar.count - leftBehind.filter {
            $0.hasSuffix(SegmentStore.metaSuffix)
        }.count)

        // And a second run recovers nothing twice.
        let second = try await env.importer().run()
        #expect(second == .alreadyComplete(stats))
    }
}
