import AppDB
import AppIntents
import Foundation
import Intelligence
import os
import SearchKit
import UIKit

// "Ask Pebble Audio what I agreed with Sam yesterday." Siri's own answer, from the app's own
// data, with no assistant plugin in between (decided by Roger 2026-10-20).
//
// `AskCompanionIntent` ("Open Ask") opens the Ask screen; this one ("Ask Pebble Audio …")
// ANSWERS, out loud and on a card, and brings the app forward only on a tap or when the answer
// runs past Siri's wait. It is the same Ask: the question goes through the Ask data source
// the screen uses (`AskLibraryDataSources.current.ask`), so it reads the same range the same
// way, with the AI the person chose, and is saved to Ask's Recent like any other question. The
// honesty Ask gets from its scope pill and its citations is kept on the card: the period and how
// much of it was read are its first line, and the conversations the answer cites are rows that
// open at the cited moment.
//
// What the dialog says when there is no answer is always the reason, never a shrug: the
// setting is Off, nothing is recorded, the AI is not set up or failed (in `Copy.AiFailure`'s
// words), or Siri stopped waiting — and the card then offers to ask in the app instead.
//
// Available from iOS 26: none of this needs the iOS 27 schema types. Every static string is an
// inline literal for `appintentsmetadataprocessor` (see `CaptureIntents.swift`).

/// The periods Siri can ask about. Deliberately not Ask's "Everything": a whole-archive question
/// is a sweep of many model calls, which no spoken request waits for.
enum AskArchivePeriod: String, AppEnum {
    case today
    case yesterday
    case last7Days

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Period")
    static let caseDisplayRepresentations: [AskArchivePeriod: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "Today", synonyms: ["today", "this morning"]),
        .yesterday: DisplayRepresentation(title: "Yesterday", synonyms: ["last night"]),
        .last7Days: DisplayRepresentation(
            title: "Last 7 days", synonyms: ["this week", "the past week", "the last week"]),
    ]

    /// The scope the Ask data source reads.
    var askScope: AskScope {
        switch self {
        case .today: return .today
        case .yesterday: return .yesterday
        case .last7Days: return .last7Days
        }
    }

    /// The period a question names when the person did not pick one: "yesterday" or "last
    /// night" is yesterday; a week, a weekday or "a few days ago" is the last 7 days; anything
    /// else is today. Today is the default because it is the one range Siri can reliably wait
    /// for, and the card says which period was read, so a person who meant more can ask again.
    static func inferred(from question: String) -> AskArchivePeriod {
        let words = question.lowercased()
        if words.contains("yesterday") || words.contains("last night") { return .yesterday }
        let weekly = [
            "this week", "last week", "past week", "few days", "days ago", "last 7 days",
            "past 7 days", "the other day", "recently", "lately", "monday", "tuesday",
            "wednesday", "thursday", "friday", "saturday", "sunday",
        ]
        if weekly.contains(where: words.contains) { return .last7Days }
        return .today
    }
}

/// "Ask my archive" — answered by Siri, from Pebble Audio's own conversations.
struct AskArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask My Archive"
    static let description = IntentDescription(
        "Answers a question from your recorded conversations and shows which ones the answer came from."
    )
    /// Answered in the background; may continue into the foreground, and only does when the
    /// answer runs past Siri's wait (`continueInApp(_:)`). A stored literal: the metadata
    /// processor reads it off the type.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Question", requestValueDialog: "What would you like to know?")
    var question: String

    /// Optional on purpose: left empty, the period the question names is used.
    @Parameter(title: "Period")
    var period: AskArchivePeriod?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question) about \(\.$period)")
    }

    init() {}

    init(question: String, period: AskArchivePeriod? = nil) {
        self.question = question
        self.period = period
    }

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView
    {
        var answerer = await AskArchiveAnswerer.live()
        answerer.continueInApp = { url in await self.continueInApp(url) }
        let outcome = await answerer.answer(question: question, period: period)
        return .result(
            value: outcome.full,
            dialog: IntentDialog(
                full: LocalizedStringResource(stringLiteral: outcome.full),
                supporting: LocalizedStringResource(stringLiteral: outcome.supporting)),
            view: AskArchiveSnippetView(card: outcome.card)
        )
    }

    /// Continues this intent in the foreground, then opens `url` there — the app's own
    /// `companion://` route, through the same `onOpenURL` every other link takes.
    private func continueInApp(_ url: URL) async -> Bool {
        guard systemContext.currentMode.canContinueInForeground else { return false }
        do {
            try await continueInForeground(
                IntentDialog(stringLiteral: Copy.Siri.continuePrompt), alwaysConfirm: false)
        } catch {
            return false
        }
        return await Self.open(url)
    }

    @MainActor private static func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}

// MARK: - The answer, without Siri

/// What the card shows. Plain values: built and tested on both OS versions, rendered by
/// `AskArchiveSnippetView`.
struct AskArchiveCard: Equatable, Sendable {
    /// "Yesterday" — the period read, in the words of Ask's scope pill.
    var periodLabel: String
    /// The answer, citation markers taken out; or, with no answer, the one line under the
    /// heading (nil when the heading says it all).
    var body: String?
    var isAnswer: Bool
    /// Ask's own partial-coverage line, under an answer built from part of the period only. A
    /// complete answer says nothing, exactly as on the Ask screen.
    var partialNote: String?
    /// The cited conversations, in the order the answer first cites them, at most `sourceLimit`.
    var sources: [Source]
    /// Cited conversations beyond `sources`.
    var moreSources: Int
    /// The one button under the card: Open in Ask, or Ask in Pebble Audio.
    var action: Action?

    struct Source: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        /// "Yesterday · 4:12 PM"
        var when: String?
        /// The conversation, opened at the moment the answer cites.
        var link: URL
    }

    struct Action: Equatable, Sendable {
        var label: String
        var link: URL
    }

    static let sourceLimit = 3
}

/// Everything Siri receives from one question.
struct AskArchiveOutcome: Equatable, Sendable {
    /// Read in full on AirPods and returned to a Shortcut: it has to stand on its own.
    var full: String
    /// Shown above the card.
    var supporting: String
    var card: AskArchiveCard
}

/// The question → answer → card path, with every dependency a closure so tests drive it
/// without a running app. `live()` wires it to the one Ask implementation.
struct AskArchiveAnswerer: Sendable {
    var isReady: @MainActor @Sendable () -> Bool
    var visibility: @Sendable () -> SystemSearchVisibility
    var hasContent: @MainActor @Sendable () async -> Bool
    /// Ask over everything, transcripts included: only under "Everything".
    var ask: @MainActor @Sendable (String, AskScope) async throws -> AskEntry
    /// Ask over titles, summaries, tags and recaps (`SummaryAskCorpus`): under "Titles and
    /// summaries", where no transcript may reach Siri.
    var askSummaries: @MainActor @Sendable (String, AskScope) async throws -> AskEntry
    var target: @MainActor @Sendable (AskCitation) async -> CitationTarget?
    /// How long Ask may take before Siri is told to ask in the app instead. Siri does not wait
    /// indefinitely for an intent, and an answer that never arrives is worse than one that says
    /// where to find it.
    var deadline: Duration = AskArchiveAnswerer.defaultDeadline
    /// Brings the app forward on `url` once Siri has stopped waiting. False when the system
    /// cannot (or the person declines); the default, for anything that is not a live intent.
    var continueInApp: @MainActor @Sendable (URL) async -> Bool = { _ in false }

    static let defaultDeadline: Duration = .seconds(25)

    @MainActor
    static func live() -> AskArchiveAnswerer {
        AskArchiveAnswerer(
            isReady: { AppComposition.shared != nil },
            visibility: { EntityVisibility.current() },
            hasContent: { await AskLibraryDataSources.current.ask.hasContent() },
            ask: { question, scope in
                try await AskLibraryDataSources.current.ask.ask(
                    question: question, thread: nil, scope: scope)
            },
            askSummaries: { question, scope in
                try await AskLibraryDataSources.current.ask.askFromSummaries(
                    question: question, scope: scope)
            },
            target: { await AskLibraryDataSources.current.ask.citationTarget(for: $0) }
        )
    }

    func answer(question: String, period explicit: AskArchivePeriod?) async -> AskArchiveOutcome {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let period = explicit ?? AskArchivePeriod.inferred(from: trimmed)
        let askInApp = AskArchiveCard.Action(
            label: Copy.Siri.askInApp,
            link: Route.ask(scope: period.askScope.routeKey, query: trimmed.isEmpty ? nil : trimmed)
                .url)

        guard await isReady() else {
            return Self.notice(
                spoken: Copy.Siri.notReady, heading: Copy.Siri.notReadyHeading,
                line: Copy.Siri.notReadyLine, period: period, action: nil)
        }
        // The person's "Siri & Spotlight can see" choice, read once for the whole answer. Off
        // means Siri hears nothing from the archive — not even an answer built from it; Titles
        // and summaries means the answer is built from those alone, never a transcript.
        let visibility = self.visibility()
        guard visibility.donates else {
            return Self.notice(
                spoken: Copy.Siri.offForSiri("answers"), heading: Copy.Siri.offHeading,
                line: Copy.Siri.offLine, period: period, action: askInApp)
        }
        guard await hasContent() else {
            return Self.notice(
                spoken: Copy.Siri.nothingRecorded, heading: Copy.Siri.nothingRecordedHeading,
                line: nil, period: period, action: nil)
        }

        let summariesOnly = !visibility.includesText
        let entry: AskEntry
        do {
            let ask = summariesOnly ? self.askSummaries : self.ask
            guard
                let answered = try await Self.withDeadline(
                    deadline, { try await ask(trimmed, period.askScope) })
            else {
                // Past Siri's wait the question carries on in the app, on the Ask screen, where
                // it is asked again and answered with its sources. Where the system cannot bring
                // the app forward (a locked phone, a Shortcut run in the background, the person
                // declining), the card offers the same as a button instead.
                if await continueInApp(askInApp.link) {
                    return Self.notice(
                        spoken: Copy.Siri.continuingInApp, heading: Copy.Siri.continuingHeading,
                        line: nil, period: period, action: nil)
                }
                return Self.notice(
                    spoken: Copy.Siri.tookTooLong, heading: Copy.Siri.tookTooLongHeading,
                    line: Copy.Siri.tookTooLongLine, period: period, action: askInApp)
            }
            entry = answered
        } catch {
            let failure = AiFailure.classify(error)
            // `.unknown` adds nothing the sentence does not already say, as on the Ask screen.
            let reason = failure.kind == .unknown ? nil : failure.reason
            return Self.notice(
                spoken: Copy.Siri.couldNotAnswer(reason), heading: Copy.Siri.noAnswerHeading,
                line: reason, period: period, action: askInApp)
        }

        // One row per cited CONVERSATION, in the order the answer first cites it. Two
        // citations into one conversation are one place to go.
        var seen = Set<String>()
        var sources: [AskArchiveCard.Source] = []
        for citation in entry.citations {
            guard let target = await target(citation),
                seen.insert(target.conversationId).inserted
            else { continue }
            sources.append(Self.source(target))
        }

        let text = AskArchiveText.plain(entry.answerText)
        var full = text
        var partialNote: String?
        if entry.isPartialCoverage, let read = entry.conversationsRead,
            let inScope = entry.conversationsInScope
        {
            full +=
                " "
                + Copy.Siri.partiallyRead(
                    read: read, inScope: inScope, period: period, summariesOnly: summariesOnly)
            partialNote =
                summariesOnly
                ? Copy.Siri.partialSummaries(read: read, inScope: inScope)
                : Copy.Ask.partialCoverage(read: read, inScope: inScope)
        }
        let shown = Array(sources.prefix(AskArchiveCard.sourceLimit))
        return AskArchiveOutcome(
            full: full,
            supporting: Copy.Siri.supporting(
                read: entry.conversationsRead, period: period, summariesOnly: summariesOnly),
            card: AskArchiveCard(
                periodLabel: Copy.Siri.periodLabel(period),
                body: text,
                isAnswer: true,
                partialNote: partialNote,
                sources: shown,
                moreSources: sources.count - shown.count,
                action: AskArchiveCard.Action(
                    label: Copy.Siri.openInAsk,
                    link: Route.askThread(id: entry.threadId, question: nil).url)
            )
        )
    }

    static func source(_ target: CitationTarget) -> AskArchiveCard.Source {
        let title = target.conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return AskArchiveCard.Source(
            id: target.conversationId,
            title: title.isEmpty ? EntityMapping.untitledConversation : title,
            when: target.startedAt.map { "\(TimeFmt.dayLabel(for: $0)) · \(TimeFmt.time($0))" },
            link: Route.conversation(
                id: target.conversationId, atMs: target.mediaOffsetMs, focus: target.focus
            ).url
        )
    }

    /// No answer: a heading above the card and at most one line on it, each said once, and one
    /// way on. `spoken` is the whole of it, for when there is no screen.
    static func notice(
        spoken: String, heading: String, line: String?, period: AskArchivePeriod,
        action: AskArchiveCard.Action?
    ) -> AskArchiveOutcome {
        AskArchiveOutcome(
            full: spoken,
            supporting: heading,
            card: AskArchiveCard(
                periodLabel: Copy.Siri.periodLabel(period), body: line, isAnswer: false,
                partialNote: nil, sources: [], moreSources: 0, action: action)
        )
    }

    /// The operation's result, or nil once `duration` has passed — whichever comes first.
    ///
    /// Not a task group: a group waits for every child before it returns, and Ask reads the
    /// spool and the transcripts in detached tasks that do not stop when cancelled — so the
    /// deadline would only be as good as the slowest of them. Here the answer to Siri never
    /// waits on the loser. The Ask is still cancelled, so a model call Siri has stopped waiting
    /// for is not left running.
    static func withDeadline(
        _ duration: Duration, _ operation: @escaping @Sendable () async throws -> AskEntry
    ) async throws -> AskEntry? {
        let race = AskDeadlineRace()
        let work = Task {
            do { race.finish(.answered(try await operation())) } catch {
                race.finish(.failed(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: duration)
            race.finish(.timedOut)
        }
        let result = await race.wait()
        timer.cancel()
        switch result {
        case .answered(let entry): return entry
        case .failed(let error): throw error
        case .timedOut:
            work.cancel()
            return nil
        }
    }
}

/// The first of {Ask answered, Ask failed, the deadline passed} wins; later ones are ignored.
final class AskDeadlineRace: Sendable {
    enum Result: Sendable {
        case answered(AskEntry)
        case failed(any Error)
        case timedOut
    }

    private struct State {
        var result: Result?
        var waiter: CheckedContinuation<Result, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func finish(_ value: Result) {
        let waiter = state.withLock { state -> CheckedContinuation<Result, Never>? in
            guard state.result == nil else { return nil }
            state.result = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }

    func wait() async -> Result {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Result? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Ask's answer text, made to be heard: the `[n]` citation markers go (the card lists the
/// conversations instead), and so does the space a marker leaves before punctuation.
enum AskArchiveText {
    static func plain(_ answer: String) -> String {
        var text = answer.replacing(/\s*\[\d+\]/, with: "")
        text = text.replacing(/[ \t]{2,}/, with: " ")
        text = text.replacing(/[ ]+([.,;:!?])/) { String($0.output.1) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Opening the app from the card

/// What a row or the button on the answer card runs. Not offered in Shortcuts: it only opens a
/// `companion://` route the card itself built, and refuses anything `Route.parse` does not know.
struct OpenAppLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in Pebble Audio"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Link")
    var link: String

    init() {}

    init(link: URL) {
        self.link = link.absoluteString
    }

    func perform() async throws -> some IntentResult {
        guard let url = URL(string: link), Route.parse(url) != nil else { return .result() }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

/// "Open my follow-ups in Pebble Audio."
struct OpenFollowUpsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Follow-ups"
    static let description = IntentDescription("Opens your follow-ups in Pebble Audio.")
    static let supportedModes: IntentModes = .foreground

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(Route.followUps(scope: nil).url))
    }
}
