import Foundation
import Intelligence
import UIKit

/// Every AI note the app is currently writing, and every one it has finished or failed to write
/// and not yet handed back.
///
/// Why this exists at all: tapping a template used to `await` the model call inside
/// `TemplateSheet`, with the sheet disabled and interactive dismissal off for the whole run. The
/// user's report was exactly that — "it gets kind of stuck while the AI goes and generates the
/// notes I asked for, and I can't do anything else during that time". A model call over a long
/// conversation is tens of seconds; a modal sheet is the wrong place to spend them.
///
/// It is a job model and not just a detached `Task` for three reasons, each of which is a bug we
/// would otherwise have shipped:
///
///  1. **The work must outlive the view that asked for it.** A `.task` on the sheet — or on the
///     conversation screen behind it — is cancelled the moment that view goes away, which is the
///     very first thing the user does now that they are free to leave. The `Task`s live here, in
///     a singleton, and nothing about navigation touches them.
///  2. **The result needs somewhere to land.** The old flow pushed the note from inside the
///     sheet's completion. With the user gone, there is no screen to push from and no promise
///     that pushing would even be welcome — so a finished job waits in `jobs` until the user
///     asks for it, and the dock is what asks.
///  3. **Failures have to be visible.** The old code was `try?` into `if let`: a generation that
///     failed dismissed nothing, said nothing, and left the user looking at a spinner that had
///     stopped. Here a failure is a state with a reason and a retry.
///
/// Lifetime is the process. A job is in memory only, so force-quitting the app mid-generation
/// loses it — the note is written to the database only once the model has answered, so nothing
/// half-made survives either. Re-running an AI request automatically at the next launch would
/// spend the user's tokens on something they did not ask for twice, so we do not.
@MainActor
@Observable
final class NoteJobCenter {
    static let shared = NoteJobCenter()

    // MARK: - The job

    struct Job: Identifiable, Equatable {
        /// Also the dedupe key — see `Self.key(...)`. Two taps on the same template for the same
        /// conversation are one job, not two model calls and two identical notes.
        let id: String
        let conversationId: String
        /// Known up front only when the screen that opened the sheet had it; filled in from the
        /// finished note otherwise. Never invented.
        var conversationTitle: String?
        let template: NoteTemplate
        let customPrompt: String?
        let startedAt: Date
        var state: State

        var templateTitle: String { template.title }

        enum State: Equatable {
            case running
            case finished(noteId: String)
            case failed(reason: String)

            var isRunning: Bool { self == .running }

            /// Finished or failed: the two states that have something for the user to do.
            var isTerminal: Bool { !isRunning }

            var noteId: String? {
                if case .finished(let id) = self { return id }
                return nil
            }
        }
    }

    /// Oldest first, except that a job is moved to the end when it reaches a terminal state — so
    /// the last element is always the one the dock should be showing. See `focused`.
    private(set) var jobs: [Job] = []

    /// Not observed: the dock renders `jobs`, and a task handle changing is not a reason to
    /// re-render anything.
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    // MARK: - Seams

    typealias Generator = @MainActor (String, NoteTemplate, String?) async throws -> NoteDisplay

    /// The work a job performs. A property, not a hard-wired call, so the state machine below can
    /// be tested without a database, a watch, or a paid model behind
    /// `AskLibraryDataSources.current`.
    @ObservationIgnored
    var generate: Generator = { conversationId, template, customPrompt in
        try await AskLibraryDataSources.current.notes.generate(
            conversationId: conversationId, template: template, customPrompt: customPrompt)
    }

    /// Whether a running job holds a UIKit background assertion. Always true in the app. Tests
    /// turn it off: `UIApplication.shared` does not exist in a unit-test bundle with no host
    /// application, and touching it there is a crash rather than a failed expectation.
    @ObservationIgnored var holdsBackgroundAssertion = true

    // MARK: - Starting work

    /// The dedupe key. The custom prompt is part of it because every ad-hoc prompt arrives under
    /// the same `custom-draft` template id — without it, asking two different questions of one
    /// conversation would silently drop the second.
    static func key(conversationId: String, template: NoteTemplate, customPrompt: String?) -> String
    {
        let prompt = customPrompt ?? template.prompt ?? ""
        return "\(conversationId)|\(template.id)|\(prompt.hashValue)"
    }

    /// Starts writing a note, or returns the id of the identical one already being written.
    ///
    /// Returns immediately — this is the whole point. The caller's next move is to dismiss
    /// itself; the dock takes it from here.
    @discardableResult
    func enqueue(
        conversationId: String,
        conversationTitle: String? = nil,
        template: NoteTemplate,
        customPrompt: String? = nil
    ) -> String {
        let id = Self.key(
            conversationId: conversationId, template: template, customPrompt: customPrompt)

        if let existing = jobs.first(where: { $0.id == id }) {
            // Already running: the second tap is the same request, so it joins the first rather
            // than paying for it twice.
            if existing.state.isRunning { return id }
            // Finished or failed and still on the dock: asking again is a real request, so the
            // old card gives way to a new run rather than colliding with it.
            remove(id)
        }

        let job = Job(
            id: id,
            conversationId: conversationId,
            conversationTitle: conversationTitle,
            template: template,
            customPrompt: customPrompt,
            startedAt: Date(),
            state: .running
        )
        jobs.append(job)
        start(job)
        return id
    }

    private func start(_ job: Job) {
        let id = job.id
        let conversationId = job.conversationId
        let template = job.template
        let customPrompt = job.customPrompt

        tasks[id] = Task { [weak self] in
            guard let self else { return }
            // Roughly thirty seconds of runtime if the user locks the phone on the way out of the
            // sheet. Not a promise — iOS grants one budget and a long model call can outlive it,
            // which is what the failed state and its Retry are for.
            let grace = NoteJobBackgroundGrace()
            if self.holdsBackgroundAssertion { grace.begin() }
            // Only the assertion is released here. The handle in `tasks` is cleared by
            // `remove(_:)`, so it lives exactly as long as the job does — clearing it from this
            // `defer` would let a finishing run wipe the handle of the retry that replaced it.
            defer { grace.end() }
            do {
                let note = try await self.generate(conversationId, template, customPrompt)
                guard !Task.isCancelled else { return }
                self.finish(id: id, with: note)
            } catch is CancellationError {
                // The user stopped it; `stop(_:)` has already taken the card away.
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.fail(id: id, reason: Self.reason(for: error))
            }
        }
    }

    // MARK: - Finishing

    private func finish(id: String, with note: NoteDisplay) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .finished(noteId: note.id)
        // The conversation's title is on the produced note whether or not the caller knew it, so
        // the "ready" card can always say which recording it came from.
        if !note.conversationTitle.isEmpty {
            jobs[index].conversationTitle = note.conversationTitle
        }
        promote(index)
    }

    private func fail(id: String, reason: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .failed(reason: reason)
        promote(index)
    }

    /// Moves a just-resolved job to the end, which is where `focused` looks first. Keeps "the
    /// most recently resolved job is the one on the dock" true without a second timestamp to
    /// keep in step.
    private func promote(_ index: Int) {
        let job = jobs.remove(at: index)
        jobs.append(job)
    }

    // MARK: - What the dock shows

    /// The one job on the dock. A resolved job outranks a running one — it is the only one with
    /// something for the user to do — and among resolved jobs the most recent wins. Everything
    /// else is counted by `queuedBehind` and surfaces in turn as each card is dealt with.
    var focused: Job? {
        jobs.last(where: { $0.state.isTerminal }) ?? jobs.last
    }

    /// How many jobs are not on the dock right now.
    var queuedBehind: Int { max(0, jobs.count - 1) }

    /// Is this exact request already being written? The template sheet asks so a row can say
    /// "Writing…" — `enqueue` folds the second tap into the first, and a tap that silently does
    /// nothing reads as a broken button.
    func isRunning(
        conversationId: String, template: NoteTemplate, customPrompt: String? = nil
    ) -> Bool {
        let id = Self.key(
            conversationId: conversationId, template: template, customPrompt: customPrompt)
        return jobs.contains { $0.id == id && $0.state.isRunning }
    }

    var isEmpty: Bool { jobs.isEmpty }

    // MARK: - User actions

    /// Stops a running generation and takes it off the dock.
    ///
    /// Honest about the edge: the model call is cancelled through the URL session, which normally
    /// aborts it before anything is written. If the answer had already come back, the note is
    /// saved and shows up in the conversation's own notes list — stopping means "stop waiting for
    /// this", not "unwrite it".
    func stop(_ id: String) {
        tasks[id]?.cancel()
        remove(id)
    }

    /// Takes a finished or failed card off the dock without opening it.
    func dismiss(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }), job.state.isTerminal else { return }
        remove(id)
    }

    /// Runs a failed job again, with the same conversation, template and prompt.
    @discardableResult
    func retry(_ id: String) -> String? {
        guard let job = jobs.first(where: { $0.id == id }), case .failed = job.state else {
            return nil
        }
        remove(id)
        return enqueue(
            conversationId: job.conversationId,
            conversationTitle: job.conversationTitle,
            template: job.template,
            customPrompt: job.customPrompt
        )
    }

    /// Where "View" goes.
    ///
    /// A push keeps whatever the user was looking at underneath — from the conversation they
    /// generated from, the note lands on top of it and Back returns there — but only the Today
    /// and Library stacks register a `.note` destination. Pushing onto any of the other three
    /// would put a blank screen on the stack, so from those this is the deep link instead, which
    /// is the same thing every widget, Spotlight hit and notification does.
    func open(_ id: String, router: AppRouter) {
        guard let job = jobs.first(where: { $0.id == id }), let noteId = job.state.noteId else {
            return
        }
        switch router.selectedTab {
        case .today, .library:
            router.push(.note(id: noteId))
        case .followUps, .ask, .settings:
            router.navigate(to: .note(id: noteId))
        }
        remove(id)
    }

    private func remove(_ id: String) {
        jobs.removeAll { $0.id == id }
        tasks[id] = nil
    }

    /// Test seam: drops every job and cancels the work behind it.
    func reset() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        jobs = []
    }

    // MARK: - Why it did not finish

    /// The user-facing reason. Mirrors `EnrichmentWorker.errorMessage` in shape, but every branch
    /// here has to be a sentence a person can act on — the enrichment one is a diagnostic string
    /// for a database column, and shipping it to the dock would put "AI provider unavailable:
    /// openai-chat" in front of the user.
    static func reason(for error: Error) -> String {
        if error is CancellationError { return Copy.NoteJobs.cancelled }
        if let aiError = error as? AiError {
            switch aiError {
            case .providerUnavailable:
                return Copy.NoteJobs.providerUnavailable
            case .consentRequired:
                return Copy.NoteJobs.consentRequired
            case .providerFailed(let message, _):
                // The provider's own message is the only thing that ever explains a 401, a rate
                // limit or a context overflow, so it is shown rather than flattened into
                // "Something went wrong" — trimmed, because some of them arrive as a wall.
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? Copy.NoteJobs.unknown : trimmed
            }
        }
        // The conversation had nothing to read: `LiveWorld` throws this when the note row or its
        // transcripts are missing.
        if let cocoa = error as? CocoaError, cocoa.code == .fileNoSuchFile {
            return Copy.NoteJobs.nothingToWorkFrom
        }
        if let urlError = error as? URLError {
            return urlError.localizedDescription
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return Copy.NoteJobs.unknown
    }
}

// MARK: - Background grace

/// Keeps the app awake for the tail of one note generation.
///
/// Split out of the job so the `UIApplication` call has one home and one expiry path. Leaking a
/// background task is what iOS kills an app for (0x8badf00d), so the expiration handler ends it
/// even though the generation itself carries on and lands — or fails — on its own.
@MainActor
final class NoteJobBackgroundGrace {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "audio-companion.note-job"
        ) { [weak self] in
            // Documented to be called on the main thread.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
