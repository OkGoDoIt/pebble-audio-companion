import AppIntents
import Foundation

// The Ask intent (plan "Native-surface plan"). It hands the question to the app by opening
// the addressable Ask route (`companion://ask?scope=…&q=…`), so the answer is produced by the
// one Ask implementation with its scope pill visible (anti-B5) and its citations intact —
// never a second, invisible Ask path answering out of Siri with no provenance.
//
// The `conversation` parameter this intent used to carry is gone. It was typed with a stub
// `ConversationEntity` whose query returned nothing, so no Shortcut or Siri request could ever
// have filled it — and the real entity (`Entities/ConversationEntity.swift`) is `@available(iOS
// 27, *)`, which a stored parameter on an intent that must exist on iOS 26 cannot be. On iOS 27
// the conversation-scoped Ask is its own intent, `AskAboutConversationIntent`, so Siri gets one
// "Conversation" type rather than a real one and a stub that resolves nothing side by side.

/// The Ask scope, in the same vocabulary the sheet's pill shows and the deep link carries.
enum AskScopeAppEnum: String, AppEnum {
    case today
    case yesterday
    case last7Days
    case everything

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scope")
    static let caseDisplayRepresentations: [AskScopeAppEnum: DisplayRepresentation] = [
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

/// "Open Ask in Pebble Audio." Since 2026-10-21 "Ask Pebble Audio …" is answered by Siri
/// (`AskArchiveIntent`); this is the one that opens the Ask screen.
struct AskCompanionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Ask"
    static let description = IntentDescription(
        "Opens Ask in Pebble Audio with your question, scoped the way you asked for it."
    )
    /// Ask has to be visible: the scope pill and the citations are the honesty of the feature,
    /// so this intent opens the app rather than answering silently.
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    @Parameter(title: "Scope", default: .today)
    var scope: AskScopeAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question) about \(\.$scope)")
    }

    func perform() async throws -> some IntentResult {
        let scopeKey = scope.routeKey
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
