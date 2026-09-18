import AppIntents
import Foundation

// "Open" intents for the three things Siri and Spotlight can hand back as entities. Each one
// opens the app on the existing `companion://` route through `OpenURLIntent`, so a Siri "open
// that conversation", a tapped Spotlight result and a pasted link all land through the one
// navigation path (`Route.parse` → `router.navigate`). Nothing here opens a second way in.
//
// `OpenConversationIntent` carries the `.system.open` schema — the one Siri uses for "open
// this" over an on-screen or just-found entity. The processor allows one type per schema, so
// the other two are plain `OpenIntent`s; Shortcuts offers them the same way.
//
// Every string is an inline literal: `appintentsmetadataprocessor` extracts them at build time
// and rejects constants (see `CaptureIntents.swift`).

@available(iOS 27, *)
@AppIntent(schema: .system.open)
struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens a conversation in Pebble Audio.")
    static let supportedModes: IntentModes = .foreground

    var target: ConversationEntity

    init() {}

    init(target: ConversationEntity) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(Route.conversation(id: target.id, atMs: nil).url))
    }
}

@available(iOS 27, *)
struct OpenFollowUpIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Follow-up"
    static let description = IntentDescription("Opens a follow-up in Pebble Audio.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Follow-up")
    var target: FollowUpEntity

    init() {}

    init(target: FollowUpEntity) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(Route.followUp(id: target.id).url))
    }
}

@available(iOS 27, *)
struct OpenNoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Saved Note"
    static let description = IntentDescription("Opens a saved note in Pebble Audio.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Note")
    var target: SavedNoteEntity

    init() {}

    init(target: SavedNoteEntity) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(Route.note(id: target.id).url))
    }
}

/// "Search Pebble Audio for the ferry" — the system's in-app search schema, which Siri maps
/// any "search <app> for …" request onto. Lands on the Library's search state with the words
/// typed in, the same as `companion://search?q=`.
@available(iOS 27, *)
@AppIntent(schema: .system.searchInApp)
struct SearchInAppIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Recordings"
    static let description = IntentDescription(
        "Searches your conversations, notes and follow-ups in Pebble Audio."
    )
    static let searchScopes: [StringSearchScope] = [.general]
    static let supportedModes: IntentModes = .foreground

    var criteria: StringSearchCriteria

    init() {}

    init(criteria: StringSearchCriteria) {
        self.criteria = criteria
    }

    func perform() async throws -> some IntentResult {
        let term = criteria.term.trimmingCharacters(in: .whitespacesAndNewlines)
        return .result(
            opensIntent: OpenURLIntent(Route.search(query: term.isEmpty ? nil : term).url))
    }
}
