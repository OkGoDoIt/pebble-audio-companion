import AppDB
import Foundation
import Testing

@testable import CompanionRuntime

// A follow-up's stage on the archive server (`sync-protocol.md` §2.5, `docs/reminders.md`). What
// these pin is what an assistant would otherwise get wrong: a follow-up the app only noticed read
// as something the person committed to, a skip that never reaches the server, and an assistant
// that puts a follow-up back into review or brings a filed-away reminder back with a repeat.

/// 2026-10-21, mid-morning UTC.
private let now: Int64 = 1_792_576_800_000

@Suite("archive follow-up stage")
struct ArchiveFollowUpStageTests {
    func builder(_ db: AppDatabase) -> ArchivePayloadBuilder {
        ArchivePayloadBuilder(
            sources: .init(
                database: db, readMeta: { _ in nil }, listSegments: { [] },
                transcript: { _ in nil }, transcriptVersion: { _ in "absent" }))
    }

    func handler(_ db: AppDatabase) -> ArchiveRequestHandler {
        ArchiveRequestHandler(
            sources: .init(
                builder: builder(db), readFrames: { _ in [] },
                temporaryDirectory: FileManager.default.temporaryDirectory, nowMs: { now },
                permissions: { ArchivePreferences(edits: true) }))
    }

    func noticed(_ id: String, _ stage: FollowUpStage, in db: AppDatabase) async throws {
        try await FollowUpStore(db: db).upsertExtracted(
            FollowUp(
                id: id, text: "Send Priya the press kit", done: false, sourceConversationId: nil,
                sourceSegmentId: nil, createdAtMs: now - 3_600_000, stage: stage,
                decidedAtMs: stage == .suggested ? nil : now - 60_000))
    }

    func update(_ id: String, _ fields: [String: ArchiveJSONValue]) -> ArchiveServerRequest {
        ArchiveServerRequest(
            id: "r-\(id)", kind: "followUp.update", createdAt: nil, expiresAt: nil,
            payload: .object(fields.merging(["id": .string(id)]) { $1 }))
    }

    @Test func thePayloadSaysEachStageAndASkipIsNotSentAsArchived() async throws {
        let db = try AppDatabase.inMemory()
        try await noticed("fu-suggested", .suggested, in: db)
        try await noticed("fu-skipped", .skipped, in: db)
        _ = try await FollowUpStore(db: db).add(text: "Call the plumber", nowMs: now)
        let reminder = try #require(try await FollowUpStore(db: db).list(scope: .open).first)

        func payload(_ id: String) async throws -> [String: Any] {
            let data = try #require(try await builder(db).followUp(id))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try await payload("fu-suggested")["stage"] as? String == "suggested")
        #expect(try await payload(reminder.id)["stage"] as? String == "reminder")
        let skipped = try await payload("fu-skipped")
        #expect(skipped["stage"] as? String == "skipped")
        #expect(skipped["archivedAt"] is NSNull, "a skip is a stage, not a filing")
    }

    @Test func anAssistantMayMakeItAReminderOrSkipItNeverPutItBackIntoReview() async throws {
        let db = try AppDatabase.inMemory()
        let store = FollowUpStore(db: db)
        let handler = handler(db)
        try await noticed("fu-press", .suggested, in: db)

        #expect(await handler.handle(update("fu-press", ["stage": .string("reminder")])) == .result(.init(status: .done)))
        let accepted = try #require(try await store.load(id: "fu-press"))
        #expect(accepted.stage == .reminder)
        #expect(accepted.decidedAtMs == now, "the day's summary lists it as decided")
        #expect(try await store.list(scope: .open).map(\.id) == ["fu-press"])

        // Filed away since: the same answer again neither re-stamps it nor brings it back.
        try await store.setArchived(id: "fu-press", true, nowMs: now + 1_000)
        #expect(await handler.handle(update("fu-press", ["stage": .string("reminder")])) == .result(.init(status: .done)))
        let repeated = try #require(try await store.load(id: "fu-press"))
        #expect(repeated.archivedAtMs != nil && repeated.decidedAtMs == now)

        // A new answer is the person's: out of the archive, as on the phone.
        #expect(await handler.handle(update("fu-press", ["stage": .string("skipped")])) == .result(.init(status: .done)))
        let skipped = try #require(try await store.load(id: "fu-press"))
        #expect(skipped.stage == .skipped && skipped.archivedAtMs == nil)

        for refused in ["suggested", "maybe"] {
            let answer = await handler.handle(update("fu-press", ["stage": .string(refused)]))
            #expect(answer == .result(.init(status: .failed, detail: "A follow-up can only become a reminder or be skipped.")))
        }
        #expect(try await store.load(id: "fu-press")?.stage == .skipped)
    }
}
