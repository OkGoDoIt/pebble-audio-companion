import AppDB
import AppIntents
import Foundation
import Intelligence
import SearchKit
import Testing
import Transcription

// The phone's own Siri / Spotlight / Shortcuts path: what the entities carry, what the
// "Siri & Spotlight can see" setting lets out, the change gate in front of the system index,
// and Ask My Archive's answer. Everything here runs against fakes — no Spotlight index is
// written and no model is called. The iOS 27 entity checks return early on iOS 26, where the
// types do not exist.

// MARK: - Fakes

private final class FakeSystemIndex: SpotlightIndexing, @unchecked Sendable {
    var donateCalls: [[SpotlightDonation]] = []
    var removed: [String] = []

    func donate(_ donations: [SpotlightDonation]) async throws { donateCalls.append(donations) }
    func remove(uniqueIdentifiers: [String]) async throws { removed += uniqueIdentifiers }
    func removeAll() async throws {}
}

private final class FakeAppIndex: TranscriptIndexing, @unchecked Sendable {
    var upserts: [[IndexItem]] = []
    func upsert(_ items: [IndexItem]) throws { upserts.append(items) }
    func search(_ query: String, limit: Int) throws -> [IndexHit] { [] }
    func remove(id: String, kind: IndexKind) throws {}
    func remove(id: String) throws {}
    func removeAll() throws {}
    var isAvailable: Bool { true }
}

private final class FakeConversations: EntityDataSource, @unchecked Sendable {
    var visibilityValue: SystemSearchVisibility = .full
    var scoped: [ConversationEntitySnapshot] = []
    var followUpList: [FollowUpEntitySnapshot] = []
    var askedForConversations = false

    func visibility() async -> SystemSearchVisibility { visibilityValue }
    func conversation(id: String) async -> ConversationEntitySnapshot? { nil }
    func conversations(scope: EntityScope, tag: String?, limit: Int) async
        -> [ConversationEntitySnapshot]
    {
        askedForConversations = true
        // What the live source does: the transcript only under `.full`.
        return scoped.map { snapshot in
            var copy = snapshot
            if !visibilityValue.includesText { copy.transcript = nil }
            return copy
        }
    }
    func conversations(matching query: String, limit: Int) async -> [ConversationEntitySnapshot] { [] }
    func note(id: String) async -> NoteEntitySnapshot? { nil }
    func notes(limit: Int) async -> [NoteEntitySnapshot] { [] }
    func notes(matching query: String, limit: Int) async -> [NoteEntitySnapshot] { [] }
    func recap(dateKey: String) async -> RecapEntitySnapshot? { nil }
    func recaps(limit: Int) async -> [RecapEntitySnapshot] { [] }
    func followUp(id: String) async -> FollowUpEntitySnapshot? { nil }
    func followUps(scope: EntityScope, includeDone: Bool, limit: Int) async
        -> [FollowUpEntitySnapshot]
    { followUpList }
    func followUps(matching query: String, limit: Int) async -> [FollowUpEntitySnapshot] { [] }
    func todayDateKey() async -> String { "2026-10-20" }
    func libraryDayKeys(limit: Int) async -> [String] { [] }
    func reindex(conversationIds: [String]) async {}
    func reindex(noteIds: [String]) async {}
    func reindex(followUpIds: [String]) async {}
    func reindex(recapDateKeys: [String]) async {}
    func reindexEverything() async {}
    func nudgePipeline() async -> PipelineBacklog? { nil }
}

@Suite("Siri path: entities, visibility, the index gate, Ask My Archive", .serialized) @MainActor
struct SiriPathTests {
    private static let snapshot = ConversationEntitySnapshot(
        id: "conv-1",
        title: "Lease call with Sam",
        summary: "Agreed to send the revised lease by Friday.",
        startMs: 1_792_500_000_000,
        endMs: 1_792_500_000_000 + 18 * 60_000,
        timeZoneID: "America/New_York",
        dateKey: "2026-10-20",
        tags: ["home"],
        isLive: false,
        transcript: "So I'll send you the lease by Friday.",
        people: [" Sam ", "sam", "Dana", ""]
    )

    private func withSource<T>(_ fake: FakeConversations, _ body: () async throws -> T)
        async rethrows -> T
    {
        let previous = EntityDataSources.current
        EntityDataSources.current = fake
        defer { EntityDataSources.current = previous }
        return try await body()
    }

    // MARK: - Entity mapping

    @Test func theDayIsAlwaysWrittenOutNeverRelative() {
        let today = LogicalDay.dateKey(
            forMs: Int64(Date().timeIntervalSince1970 * 1000),
            timeZoneID: TimeZone.current.identifier)
        let name = EntityMapping.dayName(dateKey: today, timeZoneID: TimeZone.current.identifier)
        #expect(name != "Today")
        #expect(name.contains(String(today.prefix(4))))
        // The recorded zone decides the calendar date, not the phone's.
        let tuesday = EntityMapping.dayName(dateKey: "2026-10-20", timeZoneID: "Asia/Tokyo")
        #expect(tuesday.contains("2026"))
        #expect(tuesday.contains("20"))
        #expect(EntityMapping.dayName(dateKey: "not-a-day", timeZoneID: "UTC") == "not-a-day")
    }

    @Test func aRecapInSpotlightIsNamedByItsDayNotItsKey() {
        let title = SpotlightDonator.recapTitle(dateKey: "2026-10-20")
        #expect(title.hasPrefix("Recap · "))
        #expect(title.contains("2026"))
        #expect(!title.contains("2026-10-20"))
        #expect(SpotlightDonator.recapTitle(dateKey: "junk") == "Recap · junk")
    }

    @Test func peopleAreTrimmedAndCountedOnce() {
        #expect(EntityMapping.people([" Sam ", "sam", "Dana", "", "  "]) == ["Sam", "Dana"])
    }

    @Test func theConversationEntityCarriesPeopleAndTheDay() {
        guard #available(iOS 27, *) else { return }
        let entity = ConversationEntity(snapshot: Self.snapshot, visibility: .full)
        #expect(entity.people == ["Sam", "Dana"])
        #expect(entity.day == EntityMapping.dayName(dateKey: "2026-10-20", timeZoneID: "America/New_York"))
        // Names are searchable: participants, and among the keywords next to the tags.
        let attributes = entity.attributeSet
        #expect(attributes.participants == ["Sam", "Dana"])
        #expect(attributes.keywords == ["home", "Sam", "Dana"])
    }

    @Test func anEntityBuiltFromADonationKeepsItsPeopleAndItsLength() {
        guard #available(iOS 27, *) else { return }
        let donation = SpotlightDonation(
            entityId: "conv-2", kind: .conversation, title: "Standup", people: ["Ana"],
            deepLinkURL: "companion://conversation/conv-2", contentCreationDateMs: 1_000,
            startDateMs: 1_000, endDateMs: 1_000 + 25 * 60_000)
        let entity = ConversationEntity(donation: donation, visibility: .summaries)
        #expect(entity?.people == ["Ana"])
        // It used to end the moment it began: zero minutes, modified at its start.
        #expect(entity?.durationMinutes == 25)
        #expect(entity?.modificationDate == Date(timeIntervalSince1970: 1 + 25 * 60))
    }

    /// The entity attached to a conversation's item is filed under the day it was RECORDED,
    /// in the zone it was recorded in — not the phone's zone at indexing time.
    @Test func anEntityFromADonationUsesTheRecordedZone() async throws {
        // 06:00 UTC: mid-afternoon in Tokyo, the evening before in Los Angeles.
        let startMs: Int64 = 1_792_476_000_000
        let tokyoDay = LogicalDay.dateKey(forMs: startMs, timeZoneID: "Asia/Tokyo")
        let laDay = LogicalDay.dateKey(forMs: startMs, timeZoneID: "America/Los_Angeles")
        #expect(tokyoDay != laDay)

        // The zone travels from the pipeline's donation onto the item.
        let system = FakeSystemIndex()
        try await SpotlightDonator(index: FakeAppIndex(), spotlight: system).donateConversations([
            .init(
                conversationId: "c1", title: "Ramen with Ken", startDateMs: startMs,
                endDateMs: startMs + 60_000, createdAtMs: startMs, timeZoneID: "Asia/Tokyo")
        ])
        let donation = try #require(system.donateCalls.first?.first)
        #expect(donation.timeZoneID == "Asia/Tokyo")

        guard #available(iOS 27, *) else { return }
        #expect(ConversationEntity(donation: donation, visibility: .full)?.folder?.id == tokyoDay)
        var elsewhere = donation
        elsewhere.timeZoneID = "America/Los_Angeles"
        #expect(ConversationEntity(donation: elsewhere, visibility: .full)?.folder?.id == laDay)
        // An item from before the zone was carried falls back to the phone's zone.
        elsewhere.timeZoneID = nil
        #expect(
            ConversationEntity(donation: elsewhere, visibility: .full)?.folder?.id
                == LogicalDay.dateKey(forMs: startMs, timeZoneID: TimeZone.current.identifier))
    }

    private static let doneFollowUp = FollowUp(
        id: "fu-9", text: "Send Sam the lease", done: true, sourceConversationId: "conv-1",
        sourceSegmentId: "s1", createdAtMs: 1_000, why: "He asked for it by Friday.",
        dueAtMs: 1_792_800_000_000, priority: .high, completedAtMs: 1_792_700_000_000)

    /// A follow-up's item carries its state, so the entity resolved from Spotlight agrees with
    /// the list: it used to be rebuilt as open, undated and unflagged whatever the row said.
    @Test func aFollowUpsIndexDocumentCarriesItsState() async throws {
        let system = FakeSystemIndex()
        let donator = SpotlightDonator(index: FakeAppIndex(), spotlight: system)
        try await donator.donateFollowUp(Self.doneFollowUp)
        let donation = try #require(system.donateCalls.first?.first)
        #expect(donation.isCompleted)
        #expect(donation.isFlagged)
        #expect(donation.dueDateMs == 1_792_800_000_000)
        #expect(donation.completionDateMs == 1_792_700_000_000)
        #expect(donation.contentDescription == "He asked for it by Friday.")
        #expect(donation.deepLinkURL == "companion://followup/fu-9")

        // Reopened: no completion date is left behind on the document.
        var reopened = Self.doneFollowUp
        reopened.done = false
        try await donator.donateFollowUp(reopened)
        let open = try #require(system.donateCalls.last?.first)
        #expect(!open.isCompleted)
        #expect(open.completionDateMs == nil)
        #expect(SpotlightIndexGate.fingerprint(open) != SpotlightIndexGate.fingerprint(donation))

        guard #available(iOS 27, *) else { return }
        let entity = try #require(FollowUpEntity(donation: donation))
        #expect(entity.isCompleted)
        #expect(entity.isFlagged == true)
        #expect(entity.dueDate?.day != nil)
        #expect(entity.completionDate == Date(timeIntervalSince1970: 1_792_700_000))
        #expect(entity.note.map { String($0.characters) } == "He asked for it by Friday.")
    }

    // MARK: - Visibility

    /// What a Shortcut piping Get Conversations into Use Model receives, at each setting.
    @Test func getConversationsHandsOverTheTranscriptOnlyUnderEverything() async throws {
        guard #available(iOS 27, *) else { return }
        let fake = FakeConversations()
        fake.scoped = [Self.snapshot]
        try await withSource(fake) {
            let intent = GetConversationsIntent()
            intent.scope = .today
            intent.tag = nil

            fake.visibilityValue = .full
            let full = try #require(try await intent.perform().value?.first)
            #expect(full.transcript == "So I'll send you the lease by Friday.")
            #expect(full.summary == "Agreed to send the revised lease by Friday.")
            #expect(full.people == ["Sam", "Dana"])

            fake.visibilityValue = .summaries
            let summaries = try #require(try await intent.perform().value?.first)
            #expect(summaries.transcript == nil)
            #expect(summaries.content.map { String($0.characters) } == summaries.summary)
            #expect(summaries.people == ["Sam", "Dana"])

            fake.visibilityValue = .off
            fake.askedForConversations = false
            #expect(try await intent.perform().value?.isEmpty == true)
            #expect(!fake.askedForConversations)
        }
    }

    @Test func getFollowUpsHandsOverNothingUnderOff() async throws {
        guard #available(iOS 27, *) else { return }
        let fake = FakeConversations()
        fake.followUpList = [
            FollowUpEntitySnapshot(
                id: "fu-1", text: "Send Sam the lease", done: false, dueAtMs: nil,
                priority: .normal, createdAtMs: 1, completedAtMs: nil,
                sourceConversationId: nil, why: nil)
        ]
        try await withSource(fake) { () async throws in
            let intent = GetFollowUpsIntent()
            intent.scope = .everything
            intent.includeDone = false
            #expect(try await intent.perform().value?.map(\.id) == ["fu-1"])
            fake.visibilityValue = .off
            #expect(try await intent.perform().value?.isEmpty == true)
        }
    }

    @Test func theOffLineNamesTheSetting() {
        #expect(Copy.Siri.offForSiri("answers").contains("set to Off"))
        #expect(Copy.Siri.offForSiri("answers").contains("answers stay in Pebble Audio"))
    }

    // MARK: - The change gate in front of the system index

    private static func donation(
        _ id: String, title: String = "Lease call", text: String? = "words",
        people: [String] = []
    ) -> SpotlightDonation {
        SpotlightDonation(
            entityId: id, kind: .conversation, title: title, contentDescription: "summary",
            textContent: text, keywords: ["home"], people: people,
            deepLinkURL: "companion://conversation/\(id)", contentCreationDateMs: 10,
            startDateMs: 10)
    }

    private static func outcome(
        _ visibility: SystemSearchVisibility, _ donations: [SpotlightDonation]
    ) -> SpotlightVisibilityGate.Outcome {
        SpotlightVisibilityGate.apply(visibility, to: donations)
    }

    @Test func unchangedContentIsNeverSentTwice() {
        var gate = SpotlightIndexGate()
        let first = gate.plan(Self.outcome(.full, [Self.donation("a"), Self.donation("b")]))
        #expect(first.index.map(\.entityId) == ["a", "b"])
        gate.didIndex(first.index)

        // The same content again — the foreground pass, a relaunch, a reindex request.
        #expect(gate.plan(Self.outcome(.full, [Self.donation("a"), Self.donation("b")])).isEmpty)

        // One field moves: only that document goes.
        let changed = gate.plan(
            Self.outcome(.full, [Self.donation("a", people: ["Sam"]), Self.donation("b")]))
        #expect(changed.index.map(\.entityId) == ["a"])
        #expect(changed.remove.isEmpty)
    }

    @Test func withinOneBatchTheLastDonationOfADocumentWins() {
        let gate = SpotlightIndexGate()
        let plan = gate.plan(
            Self.outcome(
                .full, [Self.donation("a", title: "old"), Self.donation("a", title: "new")]))
        #expect(plan.index.map(\.title) == ["new"])
    }

    /// Turning the setting down re-indexes without the transcript; turning it back up restores
    /// it. No special case: the gated content is what the gate fingerprints.
    @Test func aVisibilityChangeReindexesWhatItChanges() {
        var gate = SpotlightIndexGate()
        let full = gate.plan(Self.outcome(.full, [Self.donation("a")]))
        gate.didIndex(full.index)
        let summaries = gate.plan(Self.outcome(.summaries, [Self.donation("a")]))
        #expect(summaries.index.count == 1)
        #expect(summaries.index.first?.textContent == nil)
        gate.didIndex(summaries.index)
        #expect(gate.plan(Self.outcome(.summaries, [Self.donation("a")])).isEmpty)
        #expect(gate.plan(Self.outcome(.full, [Self.donation("a")])).index.count == 1)
    }

    @Test func underOffEachDocumentIsRemovedOnce() {
        var gate = SpotlightIndexGate()
        gate.didIndex([Self.donation("a")])
        let off = gate.plan(Self.outcome(.off, [Self.donation("a")]))
        #expect(off.index.isEmpty)
        #expect(off.remove == ["conversation:a"])
        gate.didRemove(off.remove)
        // Re-enriched again under Off: nothing to do.
        #expect(gate.plan(Self.outcome(.off, [Self.donation("a")])).isEmpty)
        // A document the gate has never seen may be left over from before: removed, once.
        #expect(gate.plan(Self.outcome(.off, [Self.donation("z")])).remove == ["conversation:z"])
        // After the whole domain is emptied, nothing unseen can be there.
        gate.didRemoveAll()
        #expect(gate.plan(Self.outcome(.off, [Self.donation("z")])).isEmpty)
        #expect(!gate.isPossiblyIndexed("conversation:a"))
    }

    @Test func aFailedWriteIsSentAgain() {
        var gate = SpotlightIndexGate()
        gate.didIndex([Self.donation("a")])
        gate.didFail(["conversation:a"])
        #expect(gate.plan(Self.outcome(.full, [Self.donation("a")])).index.count == 1)
        #expect(gate.isPossiblyIndexed("conversation:a"))
    }

    @Test func theFingerprintCoversEveryIndexedField() {
        let base = Self.donation("a")
        var variants: [SpotlightDonation] = []
        var d = base; d.title = "x"; variants.append(d)
        d = base; d.contentDescription = nil; variants.append(d)
        d = base; d.textContent = ""; variants.append(d)
        d = base; d.keywords = ["work"]; variants.append(d)
        d = base; d.people = ["Sam"]; variants.append(d)
        d = base; d.deepLinkURL = "companion://conversation/b"; variants.append(d)
        d = base; d.contentCreationDateMs = 11; variants.append(d)
        d = base; d.startDateMs = nil; variants.append(d)
        d = base; d.endDateMs = 99; variants.append(d)
        d = base; d.timeZoneID = "Asia/Tokyo"; variants.append(d)
        d = base; d.dueDateMs = 99; variants.append(d)
        d = base; d.completionDateMs = 99; variants.append(d)
        d = base; d.isCompleted = true; variants.append(d)
        d = base; d.isFlagged = true; variants.append(d)
        let reference = SpotlightIndexGate.fingerprint(base)
        #expect(SpotlightIndexGate.fingerprint(base) == reference)
        for variant in variants {
            #expect(SpotlightIndexGate.fingerprint(variant) != reference)
        }
        // Never one of the two markers the gate stores for absent/unknown.
        #expect(reference > 1)
    }

    @Test func theGateSurvivesARelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("siri-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gate.json")
        var gate = SpotlightIndexGate()
        gate.didIndex([Self.donation("a")])
        gate.didRemove(["conversation:gone"])
        gate.didRemoveAll()
        gate.didIndex([Self.donation("b")])
        FileSpotlightIndexGateStore(url: url).save(gate)

        let reloaded = FileSpotlightIndexGateStore(url: url).load()
        #expect(reloaded == gate)
        #expect(reloaded.plan(Self.outcome(.full, [Self.donation("b")])).isEmpty)

        // Anything unreadable starts from nothing known, which re-sends rather than skips.
        try Data("{".utf8).write(to: url)
        #expect(FileSpotlightIndexGateStore(url: url).load() == SpotlightIndexGate())
    }

    // MARK: - Batched donation

    @Test func manyConversationsAreOneWriteAndLiveOnesWaitForTheSystemIndex() async throws {
        let app = FakeAppIndex()
        let system = FakeSystemIndex()
        let donator = SpotlightDonator(index: app, spotlight: system)
        try await donator.donateConversations([
            .init(conversationId: "c1", title: "One", people: ["Sam"], createdAtMs: 1),
            .init(conversationId: "c2", title: "Two (live)", createdAtMs: 2, systemIndex: false),
            .init(conversationId: "c3", title: "Three", createdAtMs: 3, excluded: true),
        ])
        // The app's own search gets all three in one transaction.
        #expect(app.upserts.count == 1)
        #expect(app.upserts.first?.map(\.id) == ["c1", "c2", "c3"])
        // The system index: one call, the closed conversation only, with its people.
        #expect(system.donateCalls.count == 1)
        #expect(system.donateCalls.first?.map(\.entityId) == ["c1"])
        #expect(system.donateCalls.first?.first?.people == ["Sam"])
        #expect(system.removed == ["conversation:c3"])
    }

    /// The foreground pass used to build its own, unconfigured indexer: it indexed transcripts
    /// whatever "Siri & Spotlight can see" said. It now hands its conversations to the
    /// pipeline's donation and writes nothing to the system index of its own.
    @Test func theForegroundPassGoesThroughThePipelinesDonation() async throws {
        let database = try AppDatabase.inMemory()
        let start: Int64 = 1_790_000_000_000
        try await database.writer.write { db in
            for (index, id) in ["c1", "c2"].enumerated() {
                let begins = start + Int64(index) * 3_600_000
                try db.execute(
                    sql: """
                        INSERT INTO conversations (id, startMs, endMs, timezone, state)
                        VALUES (?, ?, ?, 'UTC', 'closed')
                        """,
                    arguments: [id, begins, begins + 1_800_000])
                try db.execute(
                    sql: "INSERT INTO annotations (conversationId, title) VALUES (?, ?)",
                    arguments: [id, "Title \(id)"])
                try db.execute(
                    sql: """
                        INSERT INTO conversation_segments
                            (conversationId, segmentId, ordinal, transcriptionState)
                        VALUES (?, ?, 0, 'Complete')
                        """,
                    arguments: [id, "seg-\(id)"])
            }
        }
        final class Routed: @unchecked Sendable { var batches: [[String]] = [] }
        let routed = Routed()
        let system = FakeSystemIndex()
        let suite = "siri-path-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SpotlightService(
            database: database,
            donator: SpotlightDonator(index: FakeAppIndex(), spotlight: system),
            defaults: defaults,
            donateConversations: { routed.batches.append($0) })

        await service.donateOnForeground()
        #expect(routed.batches.count == 1)
        #expect(Set(routed.batches.first ?? []) == ["c1", "c2"])
        #expect(system.donateCalls.isEmpty)

        // Nothing ended since: the next pass hands over nothing.
        await service.donateOnForeground()
        #expect(routed.batches.last == [])
    }

    // MARK: - Ask My Archive

    @Test func thePeriodComesFromTheQuestionWhenNoneIsPicked() {
        #expect(AskArchivePeriod.inferred(from: "What did I agree with Sam yesterday?") == .yesterday)
        #expect(AskArchivePeriod.inferred(from: "what did we say last night") == .yesterday)
        #expect(AskArchivePeriod.inferred(from: "What did Dana say on Tuesday?") == .last7Days)
        #expect(AskArchivePeriod.inferred(from: "anything about the budget this week") == .last7Days)
        #expect(AskArchivePeriod.inferred(from: "What did I promise Sam?") == .today)
        #expect(AskArchivePeriod.yesterday.askScope == .yesterday)
        #expect(AskArchivePeriod.last7Days.askScope.routeKey == "last7")
    }

    @Test func spokenAnswersLoseTheirCitationMarkers() {
        #expect(
            AskArchiveText.plain("You agreed to Friday [1]. Sam checks the date [2][3] , too.")
                == "You agreed to Friday. Sam checks the date, too.")
        #expect(AskArchiveText.plain("  No markers here.  ") == "No markers here.")
    }

    private struct Recorder: @unchecked Sendable {
        final class Box: @unchecked Sendable {
            /// Questions sent to the corpus WITH transcripts.
            var asked: [(String, AskScope)] = []
            /// Questions sent to the titles-and-summaries corpus.
            var summaryAsked: [(String, AskScope)] = []
        }
        let box = Box()
    }

    private func answerer(
        visibility: SystemSearchVisibility = .full,
        ready: Bool = true,
        hasContent: Bool = true,
        recorder: Recorder = Recorder(),
        deadline: Duration = .seconds(5),
        ask: @escaping @MainActor @Sendable (String, AskScope) async throws -> AskEntry
    ) -> AskArchiveAnswerer {
        let start = Date(timeIntervalSince1970: 1_792_500_000)
        return AskArchiveAnswerer(
            isReady: { ready },
            visibility: { visibility },
            hasContent: { hasContent },
            ask: { question, scope in
                recorder.box.asked.append((question, scope))
                return try await ask(question, scope)
            },
            askSummaries: { question, scope in
                recorder.box.summaryAsked.append((question, scope))
                return try await ask(question, scope)
            },
            target: { citation in
                // Segments s1 and s2 are one conversation; s3 is another.
                let conversation = citation.segmentId == "s3" ? "conv-b" : "conv-a"
                return CitationTarget(
                    conversationId: conversation,
                    conversationTitle: conversation == "conv-a" ? "Lease call with Sam" : " ",
                    focus: TranscriptFocus(segmentId: citation.segmentId),
                    mediaOffsetMs: 4_000,
                    startedAt: start)
            },
            deadline: deadline
        )
    }

    private static func entry(read: Int? = 6, inScope: Int? = 6) -> AskEntry {
        AskEntry(
            id: "e1", threadId: "t1",
            question: "What did I agree with Sam yesterday?",
            answerText: "You agreed to send Sam the lease by Friday [1]. He checks the date [2][3].",
            citations: [
                AskCitation(segmentId: "s1", number: 1),
                AskCitation(segmentId: "s2", number: 2),
                AskCitation(segmentId: "s3", number: 3),
            ],
            scopeDescription: "yesterday",
            conversationsRead: read, conversationsInScope: inScope, createdAtMs: 1)
    }

    @Test func anAnswerIsSpokenWholeAndCardsItsConversations() async {
        let recorder = Recorder()
        let outcome = await answerer(recorder: recorder) { _, _ in Self.entry() }
            .answer(question: "  What did I agree with Sam yesterday? ", period: nil)

        #expect(recorder.box.asked.count == 1)
        #expect(recorder.box.asked.first?.0 == "What did I agree with Sam yesterday?")
        #expect(recorder.box.asked.first?.1 == .yesterday)
        #expect(outcome.full == "You agreed to send Sam the lease by Friday. He checks the date.")
        #expect(outcome.supporting == "From 6 conversations yesterday")
        let card = outcome.card
        #expect(card.isAnswer)
        #expect(card.periodLabel == "Yesterday")
        #expect(card.partialNote == nil)
        // One row per conversation, in first-cited order; a blank title reads as a conversation.
        #expect(card.sources.map(\.id) == ["conv-a", "conv-b"])
        #expect(card.sources.map(\.title) == ["Lease call with Sam", "Conversation"])
        // A row opens at the cited moment, like a chip on the Ask screen.
        #expect(
            card.sources.first.flatMap { Route.parse($0.link) }
                == .conversation(id: "conv-a", atMs: 4_000, focus: TranscriptFocus(segmentId: "s1")))
        #expect(card.action?.label == "Open in Ask")
        #expect(card.action.flatMap { Route.parse($0.link) } == .askThread(id: "t1", question: nil))
    }

    @Test func aPartialAnswerSaysSoAloudAndOnTheCard() async {
        let outcome = await answerer { _, _ in Self.entry(read: 4, inScope: 9) }
            .answer(question: "what about the budget", period: .last7Days)
        #expect(outcome.full.hasSuffix("Pebble Audio read 4 of the 9 conversations in the last 7 days."))
        #expect(outcome.card.partialNote == Copy.Ask.partialCoverage(read: 4, inScope: 9))
    }

    @Test func offMeansSiriHearsNothingFromTheArchive() async {
        let recorder = Recorder()
        let outcome = await answerer(visibility: .off, recorder: recorder) { _, _ in Self.entry() }
            .answer(question: "anything", period: .today)
        #expect(recorder.box.asked.isEmpty)
        #expect(recorder.box.summaryAsked.isEmpty)
        #expect(outcome.full == Copy.Siri.offForSiri("answers"))
        #expect(!outcome.card.isAnswer)
        #expect(outcome.card.action?.label == "Ask in Pebble Audio")
    }

    @Test func noAnswerAlwaysSaysWhy() async {
        // Not started yet.
        var outcome = await answerer(ready: false) { _, _ in Self.entry() }
            .answer(question: "q", period: .today)
        #expect(outcome.full == Copy.Siri.notReady)
        // Nothing recorded.
        outcome = await answerer(hasContent: false) { _, _ in Self.entry() }
            .answer(question: "q", period: .today)
        #expect(outcome.full == Copy.Siri.nothingRecorded)
        // The heading says it all; the card adds no line repeating it.
        #expect(outcome.supporting == Copy.Siri.nothingRecordedHeading)
        #expect(outcome.card.body == nil)
        // No AI set up: Ask's own failure sentence, and a way to ask in the app.
        outcome = await answerer { _, _ in throw AiError.providerUnavailable(providerId: "none") }
            .answer(question: "q", period: .today)
        #expect(outcome.full == Copy.Siri.couldNotAnswer(AiFailureKind.notConfigured.reason))
        #expect(outcome.card.body == AiFailureKind.notConfigured.reason)
        #expect(outcome.card.action.flatMap { Route.parse($0.link) } == .ask(scope: "today", query: "q"))
        // No card heading ends in a period, the answer's included.
        for heading in [
            Copy.Siri.notReadyHeading, Copy.Siri.offHeading, Copy.Siri.nothingRecordedHeading,
            Copy.Siri.tookTooLongHeading, Copy.Siri.noAnswerHeading,
            Copy.Siri.supporting(read: 3, period: .today),
        ] {
            #expect(!heading.hasSuffix("."))
        }
    }

    @Test func siriIsNotKeptWaitingPastTheDeadline() async {
        let started = ContinuousClock.now
        let outcome = await answerer(deadline: .milliseconds(100)) { _, _ in
            try await Task.sleep(for: .seconds(30))
            return Self.entry()
        }
        .answer(question: "a long one", period: .last7Days)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(outcome.full == Copy.Siri.tookTooLong)
        // The heading above the card is not the card's own line said twice.
        #expect(outcome.supporting == Copy.Siri.tookTooLongHeading)
        #expect(outcome.card.body == "Ask in Pebble Audio for the full answer.")
        #expect(outcome.card.action.flatMap { Route.parse($0.link) } == .ask(scope: "last7", query: "a long one"))
    }

    /// Under "Titles and summaries" the answer is built from titles, summaries, tags and recaps:
    /// the corpus with transcripts is never asked, and the card says what was read.
    @Test func underTitlesAndSummariesTheAnswerReadsSummariesOnly() async {
        let recorder = Recorder()
        let outcome = await answerer(visibility: .summaries, recorder: recorder) { _, _ in
            Self.entry(read: 4, inScope: 9)
        }
        .answer(question: "what about the budget", period: .yesterday)
        #expect(recorder.box.asked.isEmpty)
        #expect(recorder.box.summaryAsked.count == 1)
        #expect(outcome.supporting == "From summaries of 4 conversations yesterday")
        #expect(outcome.card.partialNote == Copy.Siri.partialSummaries(read: 4, inScope: 9))
        #expect(
            outcome.full.hasSuffix(
                "Pebble Audio read the summaries of 4 of the 9 conversations yesterday."))

        // Everything reads transcripts, never the summaries corpus.
        let everything = Recorder()
        _ = await answerer(visibility: .full, recorder: everything) { _, _ in Self.entry() }
            .answer(question: "q", period: .today)
        #expect(everything.box.asked.count == 1)
        #expect(everything.box.summaryAsked.isEmpty)
    }

    /// The model's whole input under "Titles and summaries", built from a real database with a
    /// transcript on disk beside it: the title, the summary and the day's recap are in it, and
    /// not one word of what was said.
    @Test func underTitlesAndSummariesNoTranscriptTextReachesTheModelsInput() async throws {
        let database = try AppDatabase.inMemory()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = nowMs - 2 * 3_600_000
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, startMs, endMs, timezone, state)
                    VALUES ('c1', ?, ?, 'UTC', 'closed')
                    """,
                arguments: [startMs, startMs + 1_800_000])
            try db.execute(
                sql: "INSERT INTO annotations (conversationId, title, summary) VALUES (?, ?, ?)",
                arguments: ["c1", "Lease call with Sam", "Agreed to send the lease by Friday."])
            try db.execute(
                sql: """
                    INSERT INTO conversation_segments
                        (conversationId, segmentId, ordinal, transcriptionState)
                    VALUES ('c1', 'seg-c1', 0, 'Complete')
                    """)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("siri-summaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcripts = FileTranscriptStore(root: directory, nowMs: { nowMs })
        _ = try transcripts.save(
            "seg-c1",
            result: RoutedTranscription(
                text: "the door code is pineapple", modeUsed: .localOnly, providerId: "fake",
                modelUsed: nil))
        #expect(transcripts.load("seg-c1")?.text.contains("pineapple") == true)
        let recaps = DailyRecapStore(db: database, nowMs: { nowMs })
        _ = try await recaps.save(
            DailyRecap(
                dateKey: LogicalDay.dateKey(forMs: nowMs, timeZoneID: TimeZone.current.identifier),
                text: "A day of lease talk.", segmentIds: ["seg-c1"]))

        let corpus = await SummaryAskCorpus.load(
            queries: ConversationQueries(db: database), recaps: recaps, scope: .lastSevenDays,
            nowMs: nowMs)
        let plan = AskCorpusPlanner.plan(
            stretches: corpus.stretches, budget: AskBudget.forMode(.remoteFirst, modelId: nil),
            relevance: { _ in .none }, policy: .keywordFirst,
            conversationOf: { corpus.conversationOf($0) })
        let rendered = AskRetriever().formatForPrompt(
            stretches: plan.batches.first ?? [], whenLabel: { corpus.whenLabels[$0.segmentId] },
            gapSummary: { _ in nil })
        let input = SummaryAskCorpus.content(
            header: corpus.header(nowMs: nowMs, scopeDescription: "the last 7 days"),
            coverageLine: plan.coverage.promptLine, question: "What did I agree with Sam?",
            rendered: rendered)

        #expect(input.contains("Lease call with Sam"))
        #expect(input.contains("Agreed to send the lease by Friday."))
        #expect(input.contains("A day of lease talk."))
        #expect(input.contains(SummaryAskCorpus.sourcesNote))
        #expect(!input.contains("pineapple"))
        #expect(!input.contains("door code"))
        #expect(plan.coverage.conversationsRead == 1)
        // A citation of the stretch opens the conversation's own recording, at its start.
        let key = try #require(corpus.stretches.first?.segmentId)
        let cited = corpus.realCitation(AskCitation(segmentId: key, number: 1))
        #expect(cited.segmentId == "seg-c1")
        #expect(cited.startMs == startMs)
    }

    /// Past Siri's wait the question carries on in the app, on the Ask screen.
    @Test func pastTheDeadlineTheQuestionCarriesOnInTheApp() async {
        final class Opened: @unchecked Sendable { var urls: [URL] = [] }
        let opened = Opened()
        var slow = answerer(deadline: .milliseconds(100)) { _, _ in
            try await Task.sleep(for: .seconds(30))
            return Self.entry()
        }
        slow.continueInApp = { url in
            opened.urls.append(url)
            return true
        }
        let outcome = await slow.answer(question: "a long one", period: .last7Days)
        #expect(opened.urls.compactMap(Route.parse) == [.ask(scope: "last7", query: "a long one")])
        #expect(outcome.supporting == Copy.Siri.continuingHeading)
        #expect(outcome.full == Copy.Siri.continuingInApp)
        #expect(outcome.card.action == nil)
    }

    /// "Ask Pebble Audio …" is Siri's answer, opening the Ask screen is worded as an open, and
    /// no two shortcuts share a phrase (Siri would pick one of them at random).
    @Test func askPebbleAudioIsAnsweredBySiriAndNoPhraseIsUsedTwice() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Intents/AppShortcuts.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        var phrases: [String: [String]] = [:]
        for block in source.components(separatedBy: "AppShortcut(").dropFirst() {
            guard let intent = block.firstMatch(of: /intent:\s*(\w+)\(/)?.output.1 else {
                continue
            }
            let list = block.components(separatedBy: "shortTitle:").first ?? ""
            phrases[String(intent), default: []] +=
                list.matches(of: /"([^"]*)"/).map { String($0.output.1) }
        }
        let all = phrases.values.flatMap { $0 }.map { $0.lowercased() }
        #expect(all.count >= 20)
        #expect(Set(all).count == all.count)
        let ask = #"Ask \(.applicationName)"#
        #expect(phrases["AskArchiveIntent"]?.contains(ask) == true)
        let openAsk = phrases["AskCompanionIntent"] ?? []
        #expect(!openAsk.isEmpty)
        #expect(openAsk.allSatisfy { $0.hasPrefix("Open Ask") || $0.hasPrefix("Show Ask") })
    }

    @Test func theCardsButtonsOpenOnlyRoutesTheAppKnows() async throws {
        #expect(OpenAppLinkIntent.isDiscoverable == false)
        let intent = OpenAppLinkIntent(link: URL(string: "https://example.com")!)
        // Refused: not a companion:// route. (It returns an empty result instead of opening.)
        _ = try await intent.perform()
        #expect(Route.parse(URL(string: intent.link)!) == nil)
    }
}
