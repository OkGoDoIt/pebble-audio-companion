import AppIntents

/// False is deliberately the default: iOS invokes this configuration when the Focus ends.
/// The suggested configuration shown while adding a filter opts this specific Focus in.
struct QuietTimeFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Quiet Time"
    static let description = IntentDescription("Use Quiet Time on your Pebble during this Focus.")

    @Parameter(title: "Quiet Time", default: false)
    var quietTime: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Quiet Time", subtitle: quietTime ? "On" : "Off")
    }

    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [Self] {
        let filter = Self()
        filter.quietTime = true
        return [filter]
    }

    func perform() async throws -> some IntentResult {
        FocusQuietTimeBridge.setFilter(quietTime)
        return .result()
    }
}
