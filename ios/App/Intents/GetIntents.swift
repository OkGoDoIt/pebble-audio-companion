import AppIntents
import Foundation
import SearchKit

// The Shortcuts-facing "get" intents: they run in the app's own process against the database
// and answer without bringing the app forward. Each one goes through `EntityDataSources`, so
// the visibility setting is applied once, in one place, before any text is handed out.
//
// Every string is an inline literal for `appintentsmetadataprocessor` (see `CaptureIntents`).

/// "Get today's conversations" / "Get last week's conversations tagged work".
@available(iOS 27, *)
struct GetConversationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Conversations"
    static let description = IntentDescription(
        "Finds conversations recorded in a period, optionally narrowed to one tag."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Period", default: .today)
    var scope: AskScopeAppEnum

    @Parameter(title: "Tag")
    var tag: String?

    static var parameterSummary: some ParameterSummary {
        When(\.$tag, .hasAnyValue) {
            Summary("Get \(\.$scope) conversations tagged \(\.$tag)")
        } otherwise: {
            Summary("Get \(\.$scope) conversations")
        }
    }

    /// Enough for a day or a week in one answer; a Shortcut that wants more can loop by tag.
    static let limit = 100

    /// Each entity carries its summary, tags, people and day, and its transcript only when
    /// "Siri & Spotlight can see" is set to Everything — which is what a Shortcut piping this
    /// into Use Model hands the model. Under Off it hands over nothing at all, and says why.
    func perform() async throws
        -> some IntentResult & ReturnsValue<[ConversationEntity]> & ProvidesDialog
    {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        guard visibility.donates else {
            return .result(
                value: [],
                dialog: IntentDialog(stringLiteral: Copy.Siri.offForSiri("conversations")))
        }
        let trimmedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshots = await source.conversations(
            scope: scope.entityScope,
            tag: trimmedTag?.isEmpty == false ? trimmedTag : nil,
            limit: Self.limit
        )
        let entities = snapshots.map { ConversationEntity(snapshot: $0, visibility: visibility) }
        return .result(
            value: entities,
            dialog: IntentDialog(stringLiteral: Copy.Siri.conversationsFound(entities.count)))
    }
}

/// "What's today's recap?" — the day's digest as text, spoken as its short form when the
/// pipeline has written one.
@available(iOS 27, *)
struct GetTodaysRecapIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today's Recap"
    static let description = IntentDescription(
        "The recap Pebble Audio has written for today, if there is one yet."
    )
    static let supportedModes: IntentModes = .background

    /// What the intent returns and what Siri says — pure, so it is testable on its own.
    struct Answer: Equatable {
        /// The recap text, or "" when there is none to give.
        var value: String
        /// The spoken/shown line: the condensed recap when there is one, else the recap, else
        /// why there is nothing.
        var spoken: String
    }

    static func answer(recap: RecapEntitySnapshot?, visibility: SystemSearchVisibility) -> Answer {
        guard visibility.donates else {
            // The setting is the person's own; the answer says which one, not "no recap".
            return Answer(value: "", spoken: Copy.Siri.offForSiri("recaps"))
        }
        guard let text = recap?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return Answer(
                value: "",
                spoken: "No recap yet. One is written once today's conversations are transcribed.")
        }
        let short = recap?.shortText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Answer(value: text, spoken: (short?.isEmpty == false ? short : nil) ?? text)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        let recap = await source.recap(dateKey: await source.todayDateKey())
        let answer = Self.answer(recap: recap, visibility: visibility)
        return .result(value: answer.value, dialog: IntentDialog(stringLiteral: answer.spoken))
    }
}

/// "Get my follow-ups" — open ones by default, done ones on request.
@available(iOS 27, *)
struct GetFollowUpsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Follow-ups"
    static let description = IntentDescription(
        "Lists the follow-ups Pebble Audio has found, open ones first."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Period", default: .everything)
    var scope: AskScopeAppEnum

    @Parameter(title: "Include Done", default: false)
    var includeDone: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$scope) follow-ups") {
            \.$includeDone
        }
    }

    static let limit = 100

    func perform() async throws
        -> some IntentResult & ReturnsValue<[FollowUpEntity]> & ProvidesDialog
    {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        guard visibility.donates else {
            return .result(
                value: [],
                dialog: IntentDialog(stringLiteral: Copy.Siri.offForSiri("follow-ups")))
        }
        var entities: [FollowUpEntity] = []
        for snapshot in await source.followUps(
            scope: scope.entityScope, includeDone: includeDone, limit: Self.limit)
        {
            entities.append(
                await FollowUpEntityQuery.entity(snapshot, visibility: visibility, source: source))
        }
        return .result(
            value: entities,
            dialog: IntentDialog(stringLiteral: Copy.Siri.followUpsFound(entities.count)))
    }
}

/// "Catch up now" — wakes the pipeline so whatever is waiting is worked on immediately, and
/// says how much that is. Not a Live Activity and not long-running (a product decision): the
/// work continues in the app on its own, the intent only starts it and reports the backlog.
@available(iOS 27, *)
struct ProcessNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Catch Up Now"
    static let description = IntentDescription(
        "Starts transcribing and summarizing anything Pebble Audio has not got to yet."
    )
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backlog = await EntityDataSources.current.nudgePipeline()
        return .result(dialog: IntentDialog(stringLiteral: Self.dialog(for: backlog)))
    }

    /// One sentence, counts included, "nothing waiting" said plainly — and, with no runtime
    /// up in this process, said so rather than claiming work started.
    static func dialog(for backlog: PipelineBacklog?) -> String {
        guard let backlog else { return "Pebble Audio is not running. Open it to catch up." }
        if backlog.isEmpty { return "Nothing is waiting. Everything recorded so far is done." }
        var parts: [String] = []
        if backlog.queued > 0 {
            parts.append("\(backlog.queued) \(backlog.queued == 1 ? "recording" : "recordings") to transcribe")
        }
        if backlog.awaitingEnrichment > 0 {
            parts.append(
                "\(backlog.awaitingEnrichment) \(backlog.awaitingEnrichment == 1 ? "conversation" : "conversations") to summarize"
            )
        }
        return "Catching up: " + parts.joined(separator: " and ") + "."
    }
}

/// "Ask Pebble Audio what Dana said in this conversation" — the conversation-scoped Ask,
/// which on iOS 27 can take the entity Siri has in hand (an on-screen conversation, a search
/// result). Same route as `AskCompanionIntent`, same one visible Ask implementation.
@available(iOS 27, *)
struct AskAboutConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask About a Conversation"
    static let description = IntentDescription(
        "Opens Ask with your question, scoped to one conversation."
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question) about \(\.$conversation)")
    }

    func perform() async throws -> some IntentResult {
        var components = URLComponents()
        components.scheme = Route.scheme
        components.host = "ask"
        components.queryItems = [
            URLQueryItem(name: "scope", value: "conversation:\(conversation.id)"),
            URLQueryItem(name: "q", value: question),
        ]
        guard let url = components.url else { return .result() }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

extension AskScopeAppEnum {
    /// The same four periods, in the entity layer's vocabulary.
    var entityScope: EntityScope {
        switch self {
        case .today: return .today
        case .yesterday: return .yesterday
        case .last7Days: return .lastSevenDays
        case .everything: return .everything
        }
    }
}
