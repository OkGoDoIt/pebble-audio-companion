import AppDB
import AppIntents
import Foundation
import SearchKit
import Testing

// The entity queries and the Get* intents, driven directly against a fake `EntityDataSource`
// (iOS 27 only — the types do not exist below it; on iOS 26 every test here returns early,
// which is itself the point: nothing of this exists there).
//
// Not AppIntentsTesting: that framework resolves intents through the system's registered
// metadata for an installed, running app, and `AppTests` compiles the app sources unhosted
// on purpose (see project.yml). Calling `perform()` and the query methods directly exercises
// the same code the system would, minus the parameter resolution the framework owns.

private final class FakeEntityDataSource: EntityDataSource, @unchecked Sendable {
    var visibilityValue: SystemSearchVisibility = .full
    var conversationsById: [String: ConversationEntitySnapshot] = [:]
    var scoped: [EntityScope: [ConversationEntitySnapshot]] = [:]
    var matches: [ConversationEntitySnapshot] = []
    var notesById: [String: NoteEntitySnapshot] = [:]
    var recapsByDay: [String: RecapEntitySnapshot] = [:]
    var followUpsById: [String: FollowUpEntitySnapshot] = [:]
    var followUpList: [FollowUpEntitySnapshot] = []
    var today = "2026-09-18"
    var backlog: PipelineBacklog? = PipelineBacklog(queued: 0, awaitingEnrichment: 0)
    var reindexed: [String] = []
    var lastScopeAsked: (scope: EntityScope, tag: String?)?
    var lastIncludeDone: Bool?

    func visibility() async -> SystemSearchVisibility { visibilityValue }
    func conversation(id: String) async -> ConversationEntitySnapshot? { conversationsById[id] }
    func conversations(scope: EntityScope, tag: String?, limit: Int) async -> [ConversationEntitySnapshot] {
        lastScopeAsked = (scope, tag)
        return Array((scoped[scope] ?? []).prefix(limit))
    }
    func conversations(matching query: String, limit: Int) async -> [ConversationEntitySnapshot] {
        Array(matches.prefix(limit))
    }
    func note(id: String) async -> NoteEntitySnapshot? { notesById[id] }
    func notes(limit: Int) async -> [NoteEntitySnapshot] { Array(notesById.values.prefix(limit)) }
    func notes(matching query: String, limit: Int) async -> [NoteEntitySnapshot] { [] }
    func recap(dateKey: String) async -> RecapEntitySnapshot? { recapsByDay[dateKey] }
    func recaps(limit: Int) async -> [RecapEntitySnapshot] { Array(recapsByDay.values.prefix(limit)) }
    func followUp(id: String) async -> FollowUpEntitySnapshot? { followUpsById[id] }
    func followUps(scope: EntityScope, includeDone: Bool, limit: Int) async -> [FollowUpEntitySnapshot] {
        lastIncludeDone = includeDone
        return Array(followUpList.filter { includeDone || !$0.done }.prefix(limit))
    }
    func followUps(matching query: String, limit: Int) async -> [FollowUpEntitySnapshot] { [] }
    func todayDateKey() async -> String { today }
    func libraryDayKeys(limit: Int) async -> [String] { [today] }
    func reindex(conversationIds: [String]) async { reindexed += conversationIds }
    func reindex(noteIds: [String]) async { reindexed += noteIds }
    func reindex(followUpIds: [String]) async { reindexed += followUpIds }
    func reindex(recapDateKeys: [String]) async { reindexed += recapDateKeys }
    func reindexEverything() async { reindexed.append("*") }
    func nudgePipeline() async -> PipelineBacklog? { backlog }
}

@Suite("entity queries and intents", .serialized) @MainActor
struct EntityQueryTests {
    private static let conversation = ConversationEntitySnapshot(
        id: "conv-1",
        title: "Coffee with Dana",
        summary: "Talked about the roadmap.",
        startMs: 1_789_689_600_000,
        endMs: 1_789_689_600_000 + 25 * 60_000,
        timeZoneID: "Asia/Tokyo",
        dateKey: "2026-09-18",
        tags: ["work"],
        isLive: false,
        transcript: "So the roadmap slips a week."
    )

    /// Installs the fake for the test and puts the live source back afterwards.
    private func withFake<T>(_ fake: FakeEntityDataSource, _ body: () async throws -> T) async rethrows -> T {
        let previous = EntityDataSources.current
        EntityDataSources.current = fake
        defer { EntityDataSources.current = previous }
        return try await body()
    }

    // MARK: - Conversation entity

    @Test func theConversationEntityMapsTheSnapshot() throws {
        guard #available(iOS 27, *) else { return }
        let entity = ConversationEntity(snapshot: Self.conversation, visibility: .full)
        #expect(entity.id == "conv-1")
        #expect(String(entity.name.characters) == "Coffee with Dana")
        #expect(entity.content.map { String($0.characters) } == "Talked about the roadmap.\n\nSo the roadmap slips a week.")
        #expect(entity.transcript == "So the roadmap slips a week.")
        #expect(entity.summary == "Talked about the roadmap.")
        #expect(entity.tags == ["work"])
        #expect(entity.durationMinutes == 25)
        #expect(entity.folder?.id == "2026-09-18")
        #expect(entity.creationDate == Date(timeIntervalSince1970: 1_789_689_600))
        #expect(entity.attachments.isEmpty)
        #expect(!entity.isPinned)
        // The subtitle's time is Tokyo's, whatever zone the simulator is in.
        #expect(entity.subtitle.hasSuffix(EntityMapping.time(ms: 1_789_689_600_000, timeZoneID: "Asia/Tokyo")))
    }

    @Test func underSummariesTheEntityKeepsTheSummaryAndDropsTheTranscript() {
        guard #available(iOS 27, *) else { return }
        let entity = ConversationEntity(snapshot: Self.conversation, visibility: .summaries)
        #expect(entity.content.map { String($0.characters) } == "Talked about the roadmap.")
        #expect(entity.transcript == nil)
        #expect(entity.summary == "Talked about the roadmap.")
    }

    /// The attribute set Spotlight would hold for the entity matches the donation's shape.
    @Test func theEntityAttributeSetMirrorsTheDonation() {
        guard #available(iOS 27, *) else { return }
        let entity = ConversationEntity(snapshot: Self.conversation, visibility: .full)
        let attributes = entity.attributeSet
        #expect(attributes.title == "Coffee with Dana")
        #expect(attributes.contentDescription == "Talked about the roadmap.")
        #expect(attributes.textContent == "So the roadmap slips a week.")
        #expect(attributes.keywords == ["work"])
        #expect(attributes.contentURL?.absoluteString == "companion://conversation/conv-1")
    }

    /// Built from a donation alone — what the association hook does inside the indexing pass.
    @Test func anEntityFromADonationCarriesTheDonationsFields() {
        guard #available(iOS 27, *) else { return }
        let donation = SpotlightDonation(
            entityId: "conv-7", kind: .conversation, title: "Standup",
            contentDescription: "Blockers.", textContent: "words", keywords: ["team"],
            deepLinkURL: "companion://conversation/conv-7", contentCreationDateMs: 5_000,
            startDateMs: 4_000)
        let entity = ConversationEntity(donation: donation, visibility: .full)
        #expect(entity?.id == "conv-7")
        #expect(entity.map { String($0.name.characters) } == "Standup")
        #expect(entity?.transcript == "words")
        #expect(entity?.tags == ["team"])
        // A note donation is not a conversation.
        let note = SpotlightDonation(
            entityId: "n", kind: .note, title: "t", deepLinkURL: "companion://note/n",
            contentCreationDateMs: 1)
        #expect(ConversationEntity(donation: note, visibility: .full) == nil)
        #expect(SavedNoteEntity(donation: note, visibility: .full)?.id == "n")
    }

    // MARK: - Queries

    @Test func theQueryResolvesIdsAndAppliesTheVisibility() async throws {
        guard #available(iOS 27, *) else { return }
        let fake = FakeEntityDataSource()
        fake.conversationsById["conv-1"] = Self.conversation
        fake.visibilityValue = .summaries
        try await withFake(fake) {
            let entities = try await ConversationEntityQuery().entities(for: ["conv-1", "conv-missing"])
            #expect(entities.map(\.id) == ["conv-1"])
            #expect(entities.first?.transcript == nil)
        }
    }

    @Test func suggestionsAreTodaysConversations() async throws {
        guard #available(iOS 27, *) else { return }
        let fake = FakeEntityDataSource()
        fake.scoped[.today] = [Self.conversation]
        fake.scoped[.everything] = [Self.conversation, Self.conversation]
        try await withFake(fake) {
            let suggested = try await ConversationEntityQuery().suggestedEntities()
            #expect(suggested.count == 1)
            #expect(fake.lastScopeAsked?.scope == .today)
        }
    }

    @Test func theSystemsReindexRequestsReachTheDataSource() async throws {
        guard #available(iOS 27, *) else { return }
        let fake = FakeEntityDataSource()
        try await withFake(fake) {
            try await ConversationEntityQuery().reindexEntities(for: ["conv-1"], indexDescription: .init())
            try await RecapEntityQuery().reindexEntities(for: ["day-2026-09-18", "junk"], indexDescription: .init())
            try await SavedNoteEntityQuery().reindexAllEntities(indexDescription: .init())
            #expect(fake.reindexed == ["conv-1", "2026-09-18", "*"])
        }
    }

    @Test func recapIdsRoundTripAndRejectNonDays() {
        guard #available(iOS 27, *) else { return }
        #expect(RecapEntity.id(dateKey: "2026-09-18") == "day-2026-09-18")
        #expect(RecapEntity.dateKey(id: "day-2026-09-18") == "2026-09-18")
        #expect(RecapEntity.dateKey(id: "conv-1") == nil)
        #expect(RecapEntity.dateKey(id: "day-nonsense") == nil)
    }

    // MARK: - Get intents

    @Test func getConversationsAsksForTheScopeAndTrimsTheTag() async throws {
        guard #available(iOS 27, *) else { return }
        let fake = FakeEntityDataSource()
        fake.scoped[.lastSevenDays] = [Self.conversation]
        try await withFake(fake) {
            let intent = GetConversationsIntent()
            intent.scope = .last7Days
            intent.tag = "  work "
            let result = try await intent.perform()
            #expect(result.value?.map(\.id) == ["conv-1"])
            #expect(fake.lastScopeAsked?.scope == .lastSevenDays)
            #expect(fake.lastScopeAsked?.tag == "work")

            intent.tag = "   "
            _ = try await intent.perform()
            #expect(fake.lastScopeAsked?.tag == nil)
        }
    }

    @Test func todaysRecapReturnsTheTextAndSpeaksTheShortForm() async throws {
        guard #available(iOS 27, *) else { return }
        let recap = RecapEntitySnapshot(
            dateKey: "2026-09-18", text: "A long day. Many things.", shortText: "A long day.",
            updatedAtMs: 10)
        #expect(
            GetTodaysRecapIntent.answer(recap: recap, visibility: .full)
                == .init(value: "A long day. Many things.", spoken: "A long day."))
        // No short form: the recap itself is spoken.
        var plain = recap
        plain.shortText = "  "
        #expect(GetTodaysRecapIntent.answer(recap: plain, visibility: .summaries).spoken == "A long day. Many things.")

        // Through the intent, against the fake: today's key is what is asked for.
        let fake = FakeEntityDataSource()
        fake.recapsByDay["2026-09-18"] = recap
        try await withFake(fake) {
            let result = try await GetTodaysRecapIntent().perform()
            #expect(result.value == "A long day. Many things.")
        }
    }

    @Test func todaysRecapSaysNoRecapYetAndSaysWhenTheSettingIsOff() {
        guard #available(iOS 27, *) else { return }
        let none = GetTodaysRecapIntent.answer(recap: nil, visibility: .full)
        #expect(none.value == "")
        #expect(none.spoken.hasPrefix("No recap yet"))
        let blank = GetTodaysRecapIntent.answer(
            recap: RecapEntitySnapshot(dateKey: "d", text: " ", shortText: nil, updatedAtMs: 0),
            visibility: .full)
        #expect(blank.spoken.hasPrefix("No recap yet"))

        let off = GetTodaysRecapIntent.answer(
            recap: RecapEntitySnapshot(dateKey: "d", text: "exists", shortText: nil, updatedAtMs: 0),
            visibility: .off)
        #expect(off.value == "")
        #expect(off.spoken.contains("set to Off"))
    }

    @Test func getFollowUpsMapsDoneDueAndPriority() async throws {
        guard #available(iOS 27, *) else { return }
        let fake = FakeEntityDataSource()
        fake.conversationsById["conv-1"] = Self.conversation
        fake.followUpList = [
            FollowUpEntitySnapshot(
                id: "fu-1", text: "Send Dana the build", done: false,
                dueAtMs: 1_789_689_600_000, priority: .high, createdAtMs: 1,
                completedAtMs: nil, sourceConversationId: "conv-1", why: "she asked"),
            FollowUpEntitySnapshot(
                id: "fu-2", text: "Book the room", done: true, dueAtMs: nil,
                priority: .normal, createdAtMs: 2, completedAtMs: 3,
                sourceConversationId: nil, why: nil),
        ]
        try await withFake(fake) {
            let intent = GetFollowUpsIntent()
            intent.scope = .everything
            intent.includeDone = true
            let entities = try #require(try await intent.perform().value)
            #expect(entities.map(\.id) == ["fu-1", "fu-2"])
            let first = try #require(entities.first)
            #expect(first.title == "Send Dana the build")
            #expect(first.isFlagged == true)
            #expect(first.isCompleted == false)
            #expect(first.dueDate?.day != nil)
            #expect(first.note.map { String($0.characters) } == "she asked")
            #expect(first.conversation?.id == "conv-1")
            #expect(first.list.id == EntityMapping.followUpListId)
            let second = try #require(entities.last)
            #expect(second.isCompleted)
            #expect(second.completionDate != nil)
            #expect(second.conversation == nil)

            intent.includeDone = false
            #expect(try await intent.perform().value?.map(\.id) == ["fu-1"])
        }
    }

    @Test func catchUpNowSaysSoWhenNothingIsRunning() {
        guard #available(iOS 27, *) else { return }
        #expect(ProcessNowIntent.dialog(for: nil).contains("not running"))
    }

    @Test func theAskScopeEnumMapsOntoTheEntityScope() {
        #expect(AskScopeAppEnum.today.entityScope == .today)
        #expect(AskScopeAppEnum.yesterday.entityScope == .yesterday)
        #expect(AskScopeAppEnum.last7Days.entityScope == .lastSevenDays)
        #expect(AskScopeAppEnum.everything.entityScope == .everything)
        #expect(EntityScope.lastSevenDays.kitScope == .lastSevenDays)
    }
}
