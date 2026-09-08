import Foundation
import Intelligence
import Testing

// The state machine behind "generating notes no longer holds up the app".
//
// The old flow had no state machine at all: `TemplateSheet` awaited the model with the sheet
// disabled, and the failure path was `try?` into `if let` — a generation that failed dismissed
// nothing and said nothing. Everything that replaced it is here, because none of it is visible
// from a screenshot: whether a second tap costs a second model call, whether a job survives the
// view that started it, where "View" navigates from each tab, and whether a failure is reported
// as something a person can act on rather than swallowed.
//
// The generator is a seam (`NoteJobCenter.generate`) precisely so these can run without the
// database, the watch, or a paid model.

@Suite("note jobs") @MainActor
struct NoteJobCenterTests {

    // MARK: - Fixtures

    /// A generation that can be held open, then finished or failed on demand — the only way to
    /// observe the running state, which is otherwise a few microseconds long.
    @MainActor
    final class Gate {
        private(set) var calls = 0
        private var waiting: [CheckedContinuation<NoteDisplay, Error>] = []

        var isWaiting: Bool { !waiting.isEmpty }

        func run() async throws -> NoteDisplay {
            calls += 1
            return try await withCheckedThrowingContinuation { waiting.append($0) }
        }

        func finish(_ note: NoteDisplay) {
            let pending = waiting
            waiting = []
            for continuation in pending { continuation.resume(returning: note) }
        }

        func fail(_ error: Error) {
            let pending = waiting
            waiting = []
            for continuation in pending { continuation.resume(throwing: error) }
        }
    }

    static func note(
        id: String = "note-1", conversationId: String = "c1",
        conversationTitle: String = "Dinner with Sam"
    ) -> NoteDisplay {
        NoteDisplay(
            id: id, conversationId: conversationId, conversationTitle: conversationTitle,
            title: "Extended summary", provenance: "", body: "", momentsLabel: "", citations: [])
    }

    static let extendedSummary = NoteTemplate(
        id: "extended-summary", title: "Extended summary")
    static let meetingNotes = NoteTemplate(id: "meeting-notes", title: "Meeting notes")

    /// A center wired to `gate`, with the UIKit background assertion off — `UIApplication.shared`
    /// does not exist in a test bundle with no host app, and touching it there is a crash.
    static func center(_ gate: Gate) -> NoteJobCenter {
        let center = NoteJobCenter()
        center.holdsBackgroundAssertion = false
        center.generate = { _, _, _ in try await gate.run() }
        return center
    }

    /// Lets the job's task run until it parks. Everything here is main-actor isolated, so a
    /// handful of yields is the whole scheduler.
    static func settle(until condition: () -> Bool = { false }, limit: Int = 200) async {
        for _ in 0..<limit {
            if condition() { return }
            await Task.yield()
        }
    }

    /// Resumes anything still parked so the test does not leak a checked continuation, and drops
    /// the jobs.
    static func drain(_ center: NoteJobCenter, _ gate: Gate) async {
        gate.fail(CancellationError())
        await settle(until: { !gate.isWaiting })
        center.reset()
    }

    // MARK: - Enqueue and dedupe

    /// The point of the whole change: `enqueue` returns before any work has happened, so the
    /// caller can dismiss itself on the next line.
    @Test func enqueueReturnsImmediatelyWithTheJobRunning() async {
        let gate = Gate()
        let center = Self.center(gate)

        let id = center.enqueue(conversationId: "c1", template: Self.extendedSummary)

        #expect(center.jobs.count == 1)
        #expect(center.jobs.first?.id == id)
        #expect(center.jobs.first?.state == .running)
        #expect(center.focused?.id == id)

        await Self.drain(center, gate)
    }

    /// Two taps on the same row are one request. Without this the user pays twice and ends up
    /// with two identical notes in the conversation.
    @Test func identicalRequestsAreOneJob() async {
        let gate = Gate()
        let center = Self.center(gate)

        let first = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.calls == 1 })
        let second = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.calls > 1 }, limit: 20)

        #expect(first == second)
        #expect(center.jobs.count == 1)
        #expect(gate.calls == 1)

        await Self.drain(center, gate)
    }

    @Test func differentTemplatesAndConversationsAreDifferentJobs() async {
        let gate = Gate()
        let center = Self.center(gate)

        center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        center.enqueue(conversationId: "c1", template: Self.meetingNotes)
        center.enqueue(conversationId: "c2", template: Self.extendedSummary)

        #expect(center.jobs.count == 3)

        await Self.drain(center, gate)
    }

    /// Every ad-hoc prompt arrives under the same `custom-draft` template id, so without the
    /// prompt in the key the second question about a conversation would be folded into the first
    /// and silently never asked.
    @Test func customPromptsAreKeyedByTheirText() async {
        let gate = Gate()
        let center = Self.center(gate)
        let draft = NoteTemplate(id: "custom-draft", title: "Custom", isCustom: true)

        center.enqueue(
            conversationId: "c1", template: draft, customPrompt: "What did we agree about the car?")
        center.enqueue(
            conversationId: "c1", template: draft, customPrompt: "Who else was in the room?")

        #expect(center.jobs.count == 2)

        await Self.drain(center, gate)
    }

    // MARK: - Completion

    @Test func finishingRecordsTheNoteAndTheConversationItCameFrom() async {
        let gate = Gate()
        let center = Self.center(gate)
        let id = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.isWaiting })

        gate.finish(Self.note(id: "note-9", conversationTitle: "Dinner with Sam"))
        await Self.settle(until: { center.focused?.state.isTerminal == true })

        #expect(center.jobs.first?.state == .finished(noteId: "note-9"))
        // The caller never told us the title (the conversation screen does not have to know the
        // dock exists) — it comes off the finished note.
        #expect(center.jobs.first?.conversationTitle == "Dinner with Sam")
        #expect(center.focused?.id == id)

        center.reset()
    }

    /// A finished job waits to be collected — it must not evaporate the way a snackbar would,
    /// because the user may be three screens away when it lands.
    @Test func aFinishedJobStaysUntilItIsDealtWith() async {
        let gate = Gate()
        let center = Self.center(gate)
        let id = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.isWaiting })
        gate.finish(Self.note())
        await Self.settle(until: { center.focused?.state.isTerminal == true })

        await Self.settle(limit: 50)
        #expect(center.focused?.id == id)

        center.dismiss(id)
        #expect(center.isEmpty)
    }

    /// A resolved job outranks a running one: it is the only one of the two with something for
    /// the user to do. The rest are counted, and each surfaces in turn as the one in front of it
    /// is cleared.
    @Test func theDockShowsTheResolvedJobBeforeARunningOne() async {
        let gate = Gate()
        let center = Self.center(gate)

        let finished = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.isWaiting })
        gate.finish(Self.note(id: "note-9"))
        await Self.settle(until: { center.focused?.state.isTerminal == true })

        // Now start a second one, which is still running.
        let running = center.enqueue(conversationId: "c2", template: Self.extendedSummary)
        await Self.settle(until: { gate.calls == 2 })

        #expect(center.jobs.count == 2)
        #expect(center.focused?.id == finished)
        #expect(center.queuedBehind == 1)

        center.dismiss(finished)
        #expect(center.focused?.id == running)
        #expect(center.queuedBehind == 0)

        await Self.drain(center, gate)
    }

    // MARK: - Failure

    /// The old code's `try?` meant a failed generation looked exactly like one that had not
    /// started. A failure is now a state, with a sentence the user can act on and a way to try
    /// again.
    @Test func failureIsReportedWithAReasonAndCanBeRetried() async {
        let gate = Gate()
        let center = Self.center(gate)
        let id = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.isWaiting })

        gate.fail(AiError.providerUnavailable(providerId: "openai-chat"))
        await Self.settle(until: { center.focused?.state.isTerminal == true })

        #expect(center.jobs.first?.state == .failed(reason: Copy.NoteJobs.providerUnavailable))

        let retried = center.retry(id)
        #expect(retried == id)
        #expect(center.jobs.count == 1)
        #expect(center.jobs.first?.state == .running)

        await Self.drain(center, gate)
    }

    /// The provider id is a diagnostic, not a sentence. `EnrichmentWorker` writes
    /// "AI provider unavailable: openai-chat" to a database column; putting that on the dock
    /// would be the app talking to itself.
    @Test func reasonsAreSentencesRatherThanDiagnostics() {
        #expect(
            NoteJobCenter.reason(for: AiError.providerUnavailable(providerId: "openai-chat"))
                == Copy.NoteJobs.providerUnavailable)
        #expect(
            NoteJobCenter.reason(for: AiError.consentRequired(providerId: "openai-chat"))
                == Copy.NoteJobs.consentRequired)
        // A provider's own message is the only thing that ever explains a 401 or a rate limit,
        // so it survives rather than being flattened.
        #expect(NoteJobCenter.reason(for: AiError.providerFailed("Rate limited", underlying: nil))
            == "Rate limited")
        #expect(
            NoteJobCenter.reason(for: AiError.providerFailed("   ", underlying: nil))
                == Copy.NoteJobs.unknown)
        // What `LiveWorld` throws when the conversation has nothing to read.
        #expect(
            NoteJobCenter.reason(for: CocoaError(.fileNoSuchFile))
                == Copy.NoteJobs.nothingToWorkFrom)
    }

    /// Cancellation is the user's own doing, so it is not reported as a failure — the card is
    /// simply gone.
    @Test func stoppingRemovesTheJobWithoutReportingAFailure() async {
        let gate = Gate()
        let center = Self.center(gate)
        let id = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.isWaiting })

        center.stop(id)
        #expect(center.isEmpty)

        // The parked call still has to unwind; it must not resurrect the job as a failure.
        gate.fail(CancellationError())
        await Self.settle(limit: 50)
        #expect(center.isEmpty)

        center.reset()
    }

    /// Asking again for something that already finished is a real request, not a duplicate — the
    /// old card gives way to a fresh run rather than colliding with it on the shared key.
    @Test func askingAgainAfterItFinishedStartsAFreshRun() async {
        let gate = Gate()
        let center = Self.center(gate)
        let id = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.isWaiting })
        gate.finish(Self.note())
        await Self.settle(until: { center.focused?.state.isTerminal == true })

        let again = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        #expect(again == id)
        #expect(center.jobs.count == 1)
        #expect(center.jobs.first?.state == .running)

        await Self.drain(center, gate)
    }

    /// The sheet reads this so a row can say "Writing…". A tap that is folded into an existing
    /// job and shows nothing reads as a dead button.
    @Test func theSheetCanSeeThatARequestIsAlreadyRunning() async {
        let gate = Gate()
        let center = Self.center(gate)
        center.enqueue(conversationId: "c1", template: Self.extendedSummary)

        #expect(center.isRunning(conversationId: "c1", template: Self.extendedSummary))
        #expect(!center.isRunning(conversationId: "c1", template: Self.meetingNotes))
        #expect(!center.isRunning(conversationId: "c2", template: Self.extendedSummary))

        await Self.drain(center, gate)
    }

    // MARK: - Getting back to it

    /// From Today or Library, "View" pushes: the conversation the note came from stays
    /// underneath, and Back returns to it.
    @Test func viewPushesOntoAStackThatKnowsAboutNotes() async {
        let gate = Gate()
        let center = Self.center(gate)
        let router = AppRouter()
        router.selectedTab = .library
        let id = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.isWaiting })
        gate.finish(Self.note(id: "note-9"))
        await Self.settle(until: { center.focused?.state.isTerminal == true })

        center.open(id, router: router)

        #expect(router.libraryPath == [.note(id: "note-9")])
        #expect(center.isEmpty)
    }

    /// Only Today and Library register a `.note` destination. Pushing onto Ask, Follow-ups or
    /// Settings would put a blank screen on the stack, so from there this is the deep link — the
    /// same one a widget or a Spotlight hit uses.
    @Test func viewDeepLinksFromAStackThatDoesNot() async {
        let gate = Gate()
        let center = Self.center(gate)
        let router = AppRouter()
        router.selectedTab = .settings
        router.settingsPath = [.settings(.storage)]
        let id = center.enqueue(conversationId: "c1", template: Self.extendedSummary)
        await Self.settle(until: { gate.isWaiting })
        gate.finish(Self.note(id: "note-9"))
        await Self.settle(until: { center.focused?.state.isTerminal == true })

        center.open(id, router: router)

        #expect(router.selectedTab == .library)
        #expect(router.libraryPath == [.note(id: "note-9")])
        #expect(center.isEmpty)
    }

    /// Nothing to open while it is still being written.
    @Test func viewDoesNothingForAJobThatHasNotFinished() async {
        let gate = Gate()
        let center = Self.center(gate)
        let router = AppRouter()
        router.selectedTab = .library
        let id = center.enqueue(conversationId: "c1", template: Self.extendedSummary)

        center.open(id, router: router)

        #expect(router.libraryPath.isEmpty)
        #expect(center.jobs.count == 1)

        await Self.drain(center, gate)
    }
}

// MARK: - The built-in template list

/// The app names templates by id and the kit owns the prompts. Nothing checks the join at
/// compile time, and the failure is silent in the worst way: `LiveWorld.prompt(for:)` falls back
/// to `meetingNotes`, so a row would run the wrong prompt under the right title.
@Suite("note templates")
struct NoteTemplateCatalogTests {

    @Test func everyBuiltInRowResolvesToAKitPrompt() {
        let kitIds = Set(AiPromptTemplates.builtIn.map(\.id))
        for template in NoteTemplate.builtIns {
            #expect(kitIds.contains(template.id), "no kit prompt for \(template.id)")
        }
    }

    @Test func extendedSummaryIsOfferedFirst() throws {
        let first = try #require(NoteTemplate.builtIns.first)
        #expect(first.id == "extended-summary")
        #expect(first.title == Copy.Notes.templateExtendedSummary)
    }

    @Test func rowIdsAreUnique() {
        let ids = NoteTemplate.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
