import AppDB
import Foundation
import GRDB
import Testing

@testable import CompanionRuntime

/// The archive sync asks which conversations may still move (`provisionalConversationIds`) for
/// every conversation it sends. The answer used to live only in the grouping held in memory, so
/// a process that had not regrouped yet — just launched, or backgrounded on battery, where the
/// pass never regroups — said "none", and a conversation whose end the segmenter had not
/// committed went to the server as settled.
@Suite("provisional conversations after a relaunch")
struct ProvisionalAfterRelaunchTests {
    private func conversation(_ id: String, provisional: Bool) -> GroupedConversation {
        GroupedConversation(
            id: id, startMs: 1_788_000_000_000, endMs: 1_788_000_600_000,
            timeZoneID: "UTC", isLive: false,
            members: [ConversationMember(segmentId: String(id.dropFirst("conv-".count)))],
            isProvisional: provisional)
    }

    @Test("with no grouping in memory, the last grouping's own record answers")
    func theOutboxAnswersUntilTheFirstRegroup() async throws {
        let fixture = try RuntimeFixture()
        try await ArchiveOutbox(db: fixture.database).setActive(true)
        // What an earlier process's grouping wrote: one conversation still provisional, one
        // settled.
        try await fixture.database.writer.write { db in
            _ = try ConversationGrouper.apply(
                [
                    conversation("conv-seg-a", provisional: false),
                    conversation("conv-seg-b", provisional: true),
                ], in: db)
        }

        // This process has not regrouped.
        #expect(await fixture.enrichment.provisionalConversationIds() == ["conv-seg-b"])

        // Once it has, its own grouping is the answer (here: an empty store, so nothing).
        _ = try await fixture.enrichment.regroup()
        #expect(await fixture.enrichment.provisionalConversationIds().isEmpty)
    }

    @Test("an unlinked phone has no record and says none")
    func unlinkedSaysNone() async throws {
        let fixture = try RuntimeFixture()
        try await fixture.database.writer.write { db in
            _ = try ConversationGrouper.apply(
                [conversation("conv-seg-b", provisional: true)], in: db)
        }
        #expect(await fixture.enrichment.provisionalConversationIds().isEmpty)
    }
}
