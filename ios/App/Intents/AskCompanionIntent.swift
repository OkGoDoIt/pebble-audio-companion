import AppIntents
import Foundation

// v1 STUB with the real entity model (plan "Native-surface plan": Siri/Ask ships in v1.x, but
// "define the App Intents entity model at v1"). The shapes below are the contract — a later
// milestone swaps the stubbed query/answer for the DB + AskRetriever without changing them.
//
// v1 behaviour: the intent hands the question to the app by opening the addressable Ask route
// (`companion://ask?scope=…&q=…`), so the answer is produced by the one Ask implementation
// with its scope pill visible (anti-B5) and its citations intact — never a second, invisible
// Ask path answering out of Siri with no provenance.

/// A conversation, as Siri/Shortcuts sees it.
struct ConversationEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static var defaultQuery = ConversationEntityQuery()

    var id: String
    /// Human title ("Coffee with Dana") — never a raw id.
    var title: String
    /// e.g. "Today · 9:12 AM", already formatted in the recorded timezone (Q16).
    var subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" }
        )
    }
}

/// The lookup seam. v1 returns nothing (no Siri surface is exposed yet); the DB-backed
/// implementation replaces the two bodies below and nothing else.
struct ConversationEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        []  // TODO(v1.x): ConversationQueries.detail(id:) per identifier.
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        []  // TODO(v1.x): TranscriptIndex title search.
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        []  // TODO(v1.x): today's conversations, newest first.
    }
}

/// The Ask scope, in the same vocabulary the sheet's pill shows and the deep link carries.
enum AskScopeAppEnum: String, AppEnum {
    case today
    case yesterday
    case last7Days
    case everything

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scope")
    static var caseDisplayRepresentations: [AskScopeAppEnum: DisplayRepresentation] = [
        .today: "Today",
        .yesterday: "Yesterday",
        .last7Days: "Last 7 days",
        .everything: "Everything",
    ]

    /// Matches `AskScope.routeKey` — the one spelling the deep link understands.
    var routeKey: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .last7Days: return "last7"
        case .everything: return "everything"
        }
    }
}

/// "Ask Pebble Audio what I said about the roadmap."
struct AskCompanionIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask About My Recordings"
    static var description = IntentDescription(
        "Opens Ask with your question, scoped the way you asked for it."
    )
    /// Ask has to be visible: the scope pill and the citations are the honesty of the feature,
    /// so this intent opens the app rather than answering silently.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    @Parameter(title: "Scope", default: .today)
    var scope: AskScopeAppEnum

    /// Optional conversation scope — the entity model exists so this parameter can carry it.
    @Parameter(title: "Conversation")
    var conversation: ConversationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question) about \(\.$scope)")
    }

    func perform() async throws -> some IntentResult {
        let scopeKey = conversation.map { "conversation:\($0.id)" } ?? scope.routeKey
        var components = URLComponents()
        components.scheme = "companion"
        components.host = "ask"
        components.queryItems = [
            URLQueryItem(name: "scope", value: scopeKey),
            URLQueryItem(name: "q", value: question),
        ]
        guard let url = components.url else { return .result() }
        return .result(opensIntent: OpenURLIntent(url))
    }
}
