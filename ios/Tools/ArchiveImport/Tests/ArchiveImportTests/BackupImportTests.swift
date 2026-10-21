import AppDB
import CompanionRuntime
import CryptoKit
import Foundation
import GRDB
import Intelligence
import SegmentStore
import Testing
import Transcription

@testable import ArchiveImportCore

// The import reads a person's whole archive, so the two things it must never get wrong are
// guarded here against a synthetic backup: it leaves the backup exactly as it found it, and what
// it builds is what the phone's builder builds, in a shape the server's contract accepts.

/// A small backup made from nothing real: one segment with a two-turn transcript, its
/// conversation with a title and a named speaker, and one of each other kind.
struct SyntheticBackup {
    let root: URL
    static let segmentId = "seg-1792000000000-0a0b0c0d-1"
    static let conversationId = "conv-seg-1792000000000-0a0b0c0d-1"
    static let startMs: Int64 = 1_792_000_000_000  // 2026-10-15T00:26:40Z
    static let zone = "Asia/Jakarta"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "archive-import-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try populate()
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func populate() throws {
        let fm = FileManager.default
        for dir in ["db", "segments", "transcription/transcripts"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }

        // 60 s of 20 ms frames at 16 kHz, closed, transcribed.
        let frames: Int64 = 3_000
        let meta = SegmentMeta(
            segmentId: Self.segmentId, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 16_000, frameDurationMs: 20,
            startTimeMs: UInt64(Self.startMs), startMonotonicMs: 0, receivedAtMs: Self.startMs + 61_000,
            firstSequence: 0, lastSequence: UInt32(frames - 1), firstSampleIndex: 0,
            lastSampleIndexExclusive: UInt64(frames * 320), frameCount: frames, logBytes: 0,
            closeReason: CloseReasonMeta(kind: "stopped"), closedAtMs: Self.startMs + 61_000,
            transcriptionState: .complete, recordedTimeZone: Self.zone)
        try JSONEncoder().encode(meta).write(
            to: root.appendingPathComponent("segments/\(Self.segmentId).meta.json"))
        let transcript = SegmentTranscript(
            segmentId: Self.segmentId, text: "Shall we plant the tomatoes today? Yes, after lunch.",
            modeUsed: .remoteOnly, providerId: "synthetic", modelUsed: "test-1",
            createdAtMs: Self.startMs + 70_000,
            segments: [
                TranscriptSegment(
                    text: "Shall we plant the tomatoes today?", startMs: 1_000, endMs: 3_000,
                    speaker: "1", confidence: 0.9),
                TranscriptSegment(
                    text: "Yes, after lunch.", startMs: 4_000, endMs: 5_500, speaker: "2",
                    confidence: 0.8),
            ])
        try JSONEncoder().encode(transcript).write(
            to: root.appendingPathComponent(
                "transcription/transcripts/\(Self.segmentId)\(FileTranscriptStore.suffix)"))

        let dbURL = root.appendingPathComponent("db/companion.sqlite")
        let database = try AppDatabase.open(at: dbURL)
        // The annotation store adds its provenance columns on first use, as the app does.
        _ = try AnnotationStore(db: database)
        let start = Self.startMs
        try database.writer.write { d in
            try d.execute(
                sql: "INSERT INTO conversations (id, startMs, endMs, timezone, state) VALUES (?, ?, ?, ?, 'closed')",
                arguments: [Self.conversationId, start + 1_000, start + 5_500, Self.zone])
            try d.execute(
                sql: "INSERT INTO conversation_segments (conversationId, segmentId, ordinal) VALUES (?, ?, 0)",
                arguments: [Self.conversationId, Self.segmentId])
            try d.execute(
                sql: """
                    INSERT INTO annotations (conversationId, title, summary, isFinal, providerId, modelUsed, updatedAtMs)
                    VALUES (?, 'Planting tomatoes', 'Two people plan the garden.', 1, 'synthetic', 'test-1', ?)
                    """,
                arguments: [Self.conversationId, start + 80_000])
            try d.execute(sql: "INSERT INTO people (id, name) VALUES ('person-1', 'Ada')")
            try d.execute(
                sql: "INSERT INTO speaker_assignments (conversationId, label, personId) VALUES (?, '1', 'person-1')",
                arguments: [Self.conversationId])
            try d.execute(
                sql: "INSERT INTO recaps (dateKey, text, segmentIds, provider, model, updatedAtMs, headline) VALUES ('2026-10-15', 'A morning in the garden.', ?, 'synthetic', 'test-1', ?, 'Garden')",
                arguments: ["[\"\(Self.segmentId)\"]", start + 90_000])
            try d.execute(
                sql: "INSERT INTO period_briefs (periodKey, kind, text, updatedAtMs) VALUES ('week:2026-10-11', 'week', 'A week of planting.', ?)",
                arguments: [start + 95_000])
            try d.execute(
                sql: "INSERT INTO follow_ups (id, text, createdAtMs, sourceConversationId, sourceWallStartMs, sourceWallEndMs, origin) VALUES ('fu-1', 'Plant the tomatoes after lunch', ?, ?, ?, ?, 'ai')",
                arguments: [start + 100_000, Self.conversationId, start + 4_000, start + 5_500])
            try d.execute(
                sql: "INSERT INTO notes (id, conversationId, templateId, title, body, citations, createdAtMs) VALUES ('note-1', ?, 'meeting-notes', 'Garden plan', 'Tomatoes after lunch.', '[]', ?)",
                arguments: [Self.conversationId, start + 110_000])
        }
        try (database.writer as? DatabasePool)?.close()
    }

    /// Every file under the backup: its path, size, modification time, and content hash.
    func fingerprint() throws -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in walker {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            out[url.path.replacingOccurrences(of: root.path, with: "")] = "\(attributes[.size] ?? 0)|\(modified)|\(hash)"
        }
        return out
    }
}

@Test func importBuildsThePhonesPayloadsAndLeavesTheBackupAsItWas() async throws {
    let backup = try SyntheticBackup()
    defer { try? FileManager.default.removeItem(at: backup.root) }
    let before = try backup.fingerprint()

    let library = try await BackupLibrary.open(backup.root)
    let scratch = library.scratch
    let rows = try await library.everything()

    // The phone's own enumeration: one of each kind, the day's coverage included, every one at
    // the backup's version.
    let kinds = Dictionary(grouping: rows, by: \.kind).mapValues(\.count)
    #expect(kinds == [
        .conversation: 1, .transcript: 1, .recap: 1, .brief: 1, .followUp: 1, .note: 1, .person: 1,
        .coverage: 1,
    ])
    #expect(rows.allSatisfy { $0.version == library.snapshotMs && $0.op == .upsert })
    #expect(library.zoneID == SyntheticBackup.zone)

    var payloads: [ArchiveEntityKind: [String: Any]] = [:]
    for row in rows {
        guard case .payload(let data, let hash, let pieceKey) = try await library.builder.build(row) else {
            Issue.record("\(row.kind) \(row.entityId) built nothing")
            continue
        }
        let item = try ArchiveBatchItem(
            key: ArchiveItemKey(kind: row.kind, entityId: row.entityId, version: row.version),
            op: .upsert, changedAtMs: row.changedAtMs, payload: data, hash: hash, pieceKey: pieceKey
        ).encoded()
        #expect(ContractCheck.check(item: item) == nil, "\(row.kind) \(row.entityId)")
        payloads[row.kind] = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // What the phone's builder made of it: the stored title, the transcript on the wall clock with
    // the named speaker, and the recap pointing back at the conversation.
    #expect(payloads[.conversation]?["title"] as? String == "Planting tomatoes")
    #expect((payloads[.conversation]?["pieces"] as? [Any])?.count == 1)
    #expect(payloads[.transcript]?["text"] as? String
        == "Ada: Shall we plant the tomatoes today?\nSpeaker 2: Yes, after lunch.")
    let firstTurn = (payloads[.transcript]?["items"] as? [[String: Any]])?.first
    #expect(firstTurn?["at"] as? String == ArchiveTime.string(SyntheticBackup.startMs + 1_000))
    #expect(payloads[.recap]?["conversationIds"] as? [String] == [SyntheticBackup.conversationId])
    #expect(payloads[.brief]?["endDay"] as? String == "2026-10-17")

    library.close()
    #expect(!FileManager.default.fileExists(atPath: scratch.path))
    #expect(try backup.fingerprint() == before)
}

@Test func versionsComeFromTheBackupsContentsNotItsFileDates() async throws {
    // A copy that reset the file dates five days later must not outrank what the phone sent since.
    let backup = try SyntheticBackup()
    defer { try? FileManager.default.removeItem(at: backup.root) }
    let later = Date().addingTimeInterval(5 * 86_400)
    for name in ["db/companion.sqlite", "db/companion.sqlite-wal"] {
        let url = backup.root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        }
    }

    let library = try await BackupLibrary.open(backup.root)
    defer { library.close() }
    #expect(library.fileWrittenMs ?? 0 >= Int64(later.timeIntervalSince1970 * 1000) - 1_000)
    // The newest thing the synthetic backup wrote is its note, unless the app's own setup stamped a row later.
    #expect(library.snapshotMs >= SyntheticBackup.startMs + 110_000)
    #expect(library.snapshotMs <= Int64(Date().timeIntervalSince1970 * 1000))
    #expect(try await library.everything().allSatisfy { $0.version == library.snapshotMs })
}

/// The import dates every kind by the phone's own rule (`ArchiveScopeGate`), asked of the
/// backup's database: whatever the phone's sync would hold back, the import holds back too.
@Test func theScopeDatesEachKindTheWayThePhoneDoes() async throws {
    let zone = "Asia/Jakarta"
    // 2026-10-10 05:00 in Jakarta, the start of that logical day.
    let cutoff = try #require(LogicalDay.bounds(ofDateKey: "2026-10-10", timeZoneID: zone)).startMs
    let db = try AppDatabase.inMemory()
    let conversations = [("old", cutoff - 1), ("new", cutoff)].map { id, start in
        GroupedConversation(
            id: id, startMs: start, endMs: start + 60_000, timeZoneID: zone, isLive: false,
            members: [ConversationMember(segmentId: "seg-\(id)")])
    }
    try await db.writer.write { d in _ = try ConversationGrouper.apply(conversations, in: d) }
    let notes = NotesStore(db: db)
    // Dated by its conversation, whenever it was written; with the conversation gone, by when.
    let noteOld = try await notes.create(
        conversationId: "old", templateId: "t", title: "a", body: "b", nowMs: cutoff + 1)
    let noteNew = try await notes.create(
        conversationId: "new", templateId: "t", title: "a", body: "b", nowMs: cutoff - 10)
    let noteLoose = try await notes.create(
        conversationId: "gone", templateId: "t", title: "a", body: "b", nowMs: cutoff - 1)
    let followUps = FollowUpStore(db: db)
    let fuOld = try await followUps.add(text: "x", nowMs: cutoff - 1)
    let fuNew = try await followUps.add(text: "y", nowMs: cutoff + 1)
    let dates = ScopeDates(database: db, zoneID: zone)

    #expect(try await !dates.contains(.conversation, id: "old", cutoffMs: cutoff))
    #expect(try await dates.contains(.conversation, id: "new", cutoffMs: cutoff))
    #expect(try await !dates.contains(.transcript, id: "old", cutoffMs: cutoff))
    #expect(try await !dates.contains(.note, id: noteOld.id, cutoffMs: cutoff))
    #expect(try await dates.contains(.note, id: noteNew.id, cutoffMs: cutoff))
    #expect(try await !dates.contains(.note, id: noteLoose.id, cutoffMs: cutoff))
    #expect(try await !dates.contains(.followUp, id: fuOld.id, cutoffMs: cutoff))
    #expect(try await dates.contains(.followUp, id: fuNew.id, cutoffMs: cutoff))
    // Days: the day the window opens on is in it, the one before is not.
    #expect(try await dates.contains(.recap, id: "2026-10-10", cutoffMs: cutoff))
    #expect(try await !dates.contains(.recap, id: "2026-10-09", cutoffMs: cutoff))
    #expect(try await !dates.contains(.coverage, id: "2026-10-09", cutoffMs: cutoff))
    // A brief by its last day: the week from 2026-10-04 ends on the 10th.
    #expect(try await dates.contains(.brief, id: "week:2026-10-04", cutoffMs: cutoff))
    #expect(try await !dates.contains(.brief, id: "week:2026-10-03", cutoffMs: cutoff))
    #expect(try await !dates.contains(.brief, id: "month:2026-09", cutoffMs: cutoff))
    #expect(try await dates.contains(.brief, id: "month:2026-10", cutoffMs: cutoff))
    #expect(try await dates.contains(.person, id: "anyone", cutoffMs: cutoff))
    #expect(try await dates.contains(.conversation, id: "old", cutoffMs: nil))
    // A transcript of a conversation that is gone is the builder's to settle.
    #expect(try await dates.contains(.transcript, id: "gone", cutoffMs: cutoff))

    // What the phone no longer has: what is dated before its own archive on the server begins.
    #expect(try await dates.isBefore(.conversation, id: "old", boundaryMs: cutoff))
    #expect(try await !dates.isBefore(.conversation, id: "new", boundaryMs: cutoff))
    #expect(try await !dates.isBefore(.note, id: noteNew.id, boundaryMs: cutoff))
    #expect(try await dates.isBefore(.note, id: noteLoose.id, boundaryMs: cutoff))
    #expect(try await dates.isBefore(.followUp, id: fuOld.id, boundaryMs: cutoff))
    #expect(try await dates.isBefore(.recap, id: "2026-10-09", boundaryMs: cutoff))
    #expect(try await !dates.isBefore(.recap, id: "2026-10-10", boundaryMs: cutoff))
    #expect(try await dates.isBefore(.brief, id: "week:2026-10-03", boundaryMs: cutoff))
    #expect(try await !dates.isBefore(.brief, id: "week:2026-10-04", boundaryMs: cutoff))
    #expect(try await dates.isBefore(.person, id: "anyone", boundaryMs: cutoff))

    // And the phone's gate, made the way its sync makes it, gives the same answers.
    let phone = try await ArchiveScopeGate.make(.since(ms: cutoff), nowMs: cutoff, database: db)
    for (kind, id) in [
        (ArchiveEntityKind.conversation, "old"), (.conversation, "new"), (.note, noteOld.id),
        (.note, noteLoose.id), (.followUp, fuNew.id), (.recap, "2026-10-09"), (.brief, "week:2026-10-04"),
    ] {
        #expect(
            try await phone.contains(kind, id: id, in: db)
                == dates.contains(kind, id: id, cutoffMs: cutoff), "\(kind) \(id)")
    }

    let hcm = try #require(TimeZone(identifier: zone))
    #expect(ImportBoundary.parse("all") == .everything)
    #expect(ImportBoundary.parse("2026-10-10", timeZone: hcm) == .before(ms: cutoff))
    #expect(ImportBoundary.parse("soon") == nil)
    #expect(ImportScope.parse("since:2026-10-10", timeZone: hcm) == .since(ms: cutoff))
    #expect(ImportScope.parse("since:2026-10-10T00:00:00Z") == .since(ms: 1_791_590_400_000))
    #expect(ImportScope.parse("last:90") == .lastDays(90))
    #expect(ImportScope.parse("all") == .all)
    for bad in ["since:2026-02-30", "last:0", "last:x", "everything", "since:"] {
        #expect(ImportScope.parse(bad) == nil, "\(bad)")
    }
    #expect(ImportScope.lastDays(2).cutoffMs(nowMs: 3 * 86_400_000) == 86_400_000)
    #expect(ImportScope.fromServer(.object(["kind": .string("lastDays"), "days": .number(90)])) == .lastDays(90))
    #expect(ImportScope.fromServer(.object(["kind": .string("since"), "since": .string("2026-10-21T00:00:00Z")]))
        == .since(ms: 1_792_540_800_000))
    #expect(ImportScope.fromServer(nil) == nil)
}

@Test func theContractCheckRefusesWhatTheServerRefuses() async throws {
    // The phone's own conversation and transcript payloads, then broken one field at a time.
    let backup = try SyntheticBackup()
    defer { try? FileManager.default.removeItem(at: backup.root) }
    let library = try await BackupLibrary.open(backup.root)
    defer { library.close() }
    var built: [ArchiveEntityKind: Data] = [:]
    for row in try await library.everything() where [.conversation, .transcript].contains(row.kind) {
        if case .payload(let data, _, _) = try await library.builder.build(row) { built[row.kind] = data }
    }
    let good = try #require(built[.conversation])

    func item(
        _ kind: ArchiveEntityKind = .conversation, id: String = SyntheticBackup.conversationId,
        from payload: Data? = nil, _ edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: payload ?? good) as? [String: Any])
        edit(&object)
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ArchiveBatchItem(
            key: ArchiveItemKey(kind: kind, entityId: id, version: 1), op: .upsert,
            changedAtMs: 1_792_000_010_000, payload: data, hash: nil, pieceKey: nil
        ).encoded()
    }

    #expect(ContractCheck.check(item: try item()) == nil)

    // A conversation the backup caught recording goes as finished, ending where its last piece ends, so it never
    // stays live on the server; a closed one goes exactly as the phone built it.
    #expect(ImportRun.settled(good) == nil)
    var live = try #require(try JSONSerialization.jsonObject(with: good) as? [String: Any])
    live["state"] = "live"
    live["provisional"] = true
    live["endedAt"] = NSNull()
    let settled = try #require(ImportRun.settled(try JSONSerialization.data(withJSONObject: live)))
    let finished = try #require(try JSONSerialization.jsonObject(with: settled) as? [String: Any])
    #expect(finished["state"] as? String == "closed")
    #expect(finished["provisional"] as? Bool == false)
    let lastPieceEnd = try #require((live["pieces"] as? [[String: Any]])?.last?["endedAt"] as? String)
    #expect(finished["endedAt"] as? String == lastPieceEnd)
    #expect(ContractCheck.check(item: try item(from: settled)) == nil)

    #expect(ContractCheck.check(item: try item { $0["pieces"] = NSNull() }) == "payload: pieces missing")
    #expect(ContractCheck.check(item: try item { $0["pieces"] = nil })
        == "payload: pieces left out (the contract sends null)")
    #expect(ContractCheck.check(item: try item { $0["startedAt"] = "yesterday" })
        == "payload: startedAt has the wrong type")
    #expect(ContractCheck.check(item: try item { $0["state"] = "paused" }) == "payload: state 'paused' is not known")
    #expect(ContractCheck.check(item: try item {
        $0["gaps"] = [["startedAt": "2026-10-15T00:26:42.000Z", "endedAt": "2026-10-15T00:26:43.000Z", "kind": "x"]]
    }) == "payload: gaps[0].kind 'x' is not known")
    #expect(ContractCheck.check(item: try item {
        var pieces = $0["pieces"] as! [[String: Any]]
        pieces[0]["startMediaMs"] = NSNull()
        $0["pieces"] = pieces
    }) == "payload: pieces[0].startMediaMs missing")
    #expect(ContractCheck.check(item: try item { $0["recordedMs"] = 1.5 }) == "payload: recordedMs has the wrong type")
    #expect(ContractCheck.check(item: try item { $0["provisional"] = 1 }) == "payload: provisional has the wrong type")

    let transcript = try #require(built[.transcript])
    #expect(ContractCheck.check(item: try item(.transcript, from: transcript)) == nil)
    #expect(ContractCheck.check(item: try item(.transcript, id: "conv-other", from: transcript))
        == "payload: conversationId is not the item's id")
    #expect(ContractCheck.check(item: try item(.transcript, from: transcript) {
        var items = $0["items"] as! [[String: Any]]
        items[0]["at"] = NSNull()
        $0["items"] = items
    }) == "payload: items[0].at missing")

    let envelope = Data(#"{"kind":"gadget","id":"x","version":1,"op":"upsert","changedAt":"2026-10-14T13:05:09.754Z","payload":{}}"#.utf8)
    #expect(ContractCheck.check(item: envelope) == "kind: 'gadget' is not known")
    let noVersion = Data(#"{"kind":"person","id":"x","op":"upsert","changedAt":"2026-10-14T13:05:09.754Z","payload":{"name":"A"}}"#.utf8)
    #expect(ContractCheck.check(item: noVersion) == "version: missing")
}

@Test func batchesKeepThePhonesLimits() {
    func item(_ n: Int, bytes: Int) -> PreparedItem {
        PreparedItem(
            key: ArchiveItemKey(kind: .person, entityId: "p\(n)", version: 1),
            encoded: Data(repeating: 0x20, count: bytes))
    }
    // 200 items a batch, whichever is smaller.
    var assembler = BatchAssembler()
    var sizes: [Int] = []
    for n in 0..<450 {
        if let full = assembler.add(item(n, bytes: 100)) { sizes.append(full.count) }
    }
    if let last = assembler.drain() { sizes.append(last.count) }
    #expect(sizes == [200, 200, 50])

    // 8 MB a batch, envelope and commas counted: two 3 MB items fit, a third does not.
    var big = BatchAssembler()
    sizes = []
    for n in 0..<5 {
        if let full = big.add(item(n, bytes: 3 * 1024 * 1024)) { sizes.append(full.count) }
    }
    if let last = big.drain() { sizes.append(last.count) }
    #expect(sizes == [2, 2, 1])

    let limit = ArchiveSyncProtocol.maxBatchBytes
    #expect(big.fitsAlone(item(0, bytes: limit - 512)))
    #expect(!big.fitsAlone(item(0, bytes: limit - 511)))
}
