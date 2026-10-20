import AppDB
import AppIntents
import Foundation
import Intelligence
import SearchKit
import Testing

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
            var asked: [(String, AskScope)] = []
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
        #expect(outcome.supporting == "From 6 conversations yesterday.")
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
        // No AI set up: Ask's own failure sentence, and a way to ask in the app.
        outcome = await answerer { _, _ in throw AiError.providerUnavailable(providerId: "none") }
            .answer(question: "q", period: .today)
        #expect(outcome.full == Copy.Siri.couldNotAnswer(AiFailureKind.notConfigured.reason))
        #expect(outcome.card.action.flatMap { Route.parse($0.link) } == .ask(scope: "today", query: "q"))
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
        #expect(outcome.card.action.flatMap { Route.parse($0.link) } == .ask(scope: "last7", query: "a long one"))
    }

    @Test func theCardsButtonsOpenOnlyRoutesTheAppKnows() async throws {
        #expect(OpenAppLinkIntent.isDiscoverable == false)
        let intent = OpenAppLinkIntent(link: URL(string: "https://example.com")!)
        // Refused: not a companion:// route. (It returns an empty result instead of opening.)
        _ = try await intent.perform()
        #expect(Route.parse(URL(string: intent.link)!) == nil)
    }
}
