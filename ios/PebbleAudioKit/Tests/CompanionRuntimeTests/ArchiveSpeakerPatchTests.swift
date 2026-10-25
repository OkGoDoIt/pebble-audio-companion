import AppDB
import Foundation
import GRDB
import SegmentStore
import Testing
import Transcription
@testable import CompanionRuntime

@Suite struct ArchiveSpeakerPatchTests {
    @Test func automaticProvenanceSurvivesExportButManualNamesHaveNoRevocableEvidence() async throws {
        let pieces = try ArchiveTranscriptExportTests.pieces()
        let piece = pieces[1]
        let transcript = try #require(piece.transcript)
        let turn = try #require(transcript.piece(piece.member).segments.first)
        let person = Person(id: UUID().uuidString.lowercased(), name: "Alex")
        let automatic = VoiceResolvedAttribution(attribution: VoiceAutomaticAttribution(
            personId: person.id, segmentId: piece.member.segmentId,
            startMediaMs: turn.startMs, endMediaMs: turn.endMs,
            sourceRevision: "digest", recipeID: "test", score: 0.9, margin: 0.2,
            calibrationID: "test", runID: "history-run", archiveOriginID: "local-store", archiveGeneration: 7), person: person)
        var identity = SpeakerIdentitySnapshot(automaticAttributions: [automatic])
        func export(_ identity: SpeakerIdentitySnapshot) -> ArchiveTranscriptPayload {
            ArchiveExport.transcript(conversationId: "c", pieces: [piece], gaps: [], speakerNames: [:],
                sourceHash: "identity", identity: identity)
        }
        let named = try #require(export(identity).speakerRanges.first { $0.personId == person.id })
        #expect(named.voiceEvidence == [ArchiveVoiceEvidence(originID: "local-store", generation: 7, runID: "history-run")])
        identity.corrections = [SpeakerCorrection(id: "human", segmentId: piece.member.segmentId,
            startMediaMs: turn.startMs, endMediaMs: turn.endMs, person: person, createdAtMs: 1)]
        let manual = try #require(export(identity).speakerRanges.first { $0.personId == person.id })
        #expect(manual.voiceEvidence.isEmpty)

        let db = try AppDatabase.inMemory()
        let outbox = ArchiveOutbox(db: db)
        try await outbox.setActive(true)
        try await VoiceIdentityStore(db: db).clearAutomatic()
        let row = try #require(try await outbox.pending(limit: 20).first { $0.kind == .voiceRevocation })
        let builder = ArchivePayloadBuilder(sources: .init(database: db,
            readMeta: { _ in nil }, listSegments: { [] }, transcript: { _ in nil }, transcriptVersion: { _ in "" }))
        guard case .payload(let data, _, _) = try await builder.build(row) else {
            Issue.record("Durable revocations need an archive payload even without retained recordings")
            return
        }
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["scope"] as? String == "all")
        #expect(object["generation"] as? Int64 == 1)
        #expect(object["targetID"] is NSNull)
        #expect(try await ArchiveScopeGate.date(of: .voiceRevocation, id: row.entityId, in: db) == .undated)
    }

    @Test func retainedTailSendsOnlySpeakerOverlayAndKeepsTheFullServerPieceKey() async throws {
        let db = try AppDatabase.inMemory()
        let pieces = try ArchiveTranscriptExportTests.pieces()
        let tail = pieces[1]
        let transcript = try #require(tail.transcript)
        let firstTurn = try #require(transcript.piece(tail.member).segments.first)
        let fullKey = ConversationSourceKey.key(of: pieces.map(\.member))
        let id = ArchiveTranscriptExportTests.conversationId
        let group = GroupedConversation(id: id, startMs: ArchiveExport.wallExtent(tail).lowerBound,
            endMs: ArchiveTranscriptExportTests.endMs, timeZoneID: "UTC", isLive: false, members: [tail.member])
        try await db.writer.write { d in _ = try ConversationGrouper.apply([group], in: d) }
        let person = try await PeopleStore(db: db).createPerson(name: "Alex")
        let corrections = SpeakerCorrectionStore(db: db)
        try await corrections.set(segmentId: tail.member.segmentId, startMediaMs: firstTurn.startMs,
                                  endMediaMs: firstTurn.endMs, personId: person.id)
        let builder = ArchivePayloadBuilder(sources: .init(database: db,
            readMeta: { $0 == tail.member.segmentId ? tail.meta : nil }, listSegments: { [tail.meta] },
            transcript: { $0 == tail.member.segmentId ? transcript : nil }, transcriptVersion: { _ in "fixed" }))
        var row = ArchiveOutboxRow(kind: .transcript, entityId: id, version: 2, op: .upsert,
            changedAtMs: 100, pending: true, sentHash: "old-full-transcript", sentKey: fullKey)
        guard case .speakerPatch(let data, let hash, let key) = try await builder.build(row) else {
            Issue.record("A retained tail must produce a names-only patch, never a shortened upsert")
            return
        }
        #expect(key == fullKey)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["text"] == nil && json["items"] == nil)
        let ranges = try #require(json["ranges"] as? [[String: Any]])
        #expect(ranges.allSatisfy { $0["segmentId"] as? String == tail.member.segmentId })
        #expect(ranges.contains { $0["personId"] as? String == person.id && $0["name"] as? String == "Alex" })
        let item = ArchiveBatchItem(key: .init(kind: .transcript, entityId: id, version: 2), op: .speakerPatch,
            changedAtMs: 100, payload: data, hash: hash, pieceKey: key)
        let encoded = try #require(try JSONSerialization.jsonObject(with: item.encoded()) as? [String: Any])
        #expect(encoded["op"] as? String == "speakerPatch")

        row.sentHash = hash
        guard case .unchanged(_, let retainedKey) = try await builder.build(row) else {
            Issue.record("An accepted identity overlay should not be sent repeatedly")
            return
        }
        #expect(retainedKey == fullKey) // losing this would make the next edit a destructive tail upsert
        try await corrections.set(segmentId: tail.member.segmentId, startMediaMs: firstTurn.startMs,
                                  endMediaMs: firstTurn.endMs, personId: nil)
        guard case .speakerPatch(let cleared, _, let clearedKey) = try await builder.build(row) else {
            Issue.record("Clearing a name must also patch retained history")
            return
        }
        #expect(clearedKey == fullKey)
        let clearJSON = try #require(try JSONSerialization.jsonObject(with: cleared) as? [String: Any])
        #expect((clearJSON["ranges"] as? [[String: Any]])?.contains { $0["name"] as? String == "Alex" } == false)

        // An older server rejects the new operation. Keep the correction pending, without
        // ever falling back to sending only the tail as a replacement transcript.
        let outbox = ArchiveOutbox(db: db)
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploads = ArchiveFakeUploads { body in
            let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let items = root["items"] as? [[String: Any]] ?? []
            let rejected = items.filter { $0["op"] as? String == "speakerPatch" }.map {
                ["kind": $0["kind"] ?? "", "id": $0["id"] ?? "", "reason": "op: 'speakerPatch' is not known"]
            }
            let accepted = items.filter { $0["op"] as? String != "speakerPatch" }.map {
                ["kind": $0["kind"] ?? "", "id": $0["id"] ?? "", "version": $0["version"] ?? 0]
            }
            let response: [String: Any] = ["serverTime": "2026-10-20T00:00:00.000Z", "accepted": accepted,
                "ignored": [], "rejected": rejected, "pendingRequests": 0]
            return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
        }
        let service = ArchiveSyncService(.init(outbox: outbox, builder: builder,
            requests: ArchiveRequestHandler(sources: .init(builder: builder, readFrames: { _ in [] }, temporaryDirectory: directory,
                nowMs: { clock.nowMs })),
            http: ArchiveFakeHTTP(), uploads: uploads,
            settings: { ArchiveSyncSettings(origin: "https://example.test", deviceId: "test-device", enabled: true) },
            token: { "pad_test" }, directory: directory, clock: clock, isForeground: { true }, isCharging: { false }))
        await service.start()
        try await db.writer.write { d in
            try d.execute(sql: "UPDATE sync_outbox SET sentKey = ?, sentHash = 'old', pending = 1 WHERE entityId = ?",
                          arguments: [fullKey, id])
        }
        await service.pass(.userAsked)
        // Repeated rejection can park the row, so inspect durable pending state rather than
        // the next-drain queue (which intentionally excludes exhausted attempts).
        let pending = try #require(try await outbox.row(kind: .transcript, id: id))
        #expect(pending.pending)
        #expect(pending.sentKey == fullKey)
        #expect(pending.lastError?.contains("speakerPatch") == true)
        let bodies = try uploads.bodies.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let sentTranscripts = bodies.flatMap { $0?["items"] as? [[String: Any]] ?? [] }
            .filter { $0["kind"] as? String == "transcript" }
        #expect(!sentTranscripts.isEmpty)
        #expect(sentTranscripts.allSatisfy { $0["op"] as? String == "speakerPatch" })
        await service.setForeground(false)
    }
}
