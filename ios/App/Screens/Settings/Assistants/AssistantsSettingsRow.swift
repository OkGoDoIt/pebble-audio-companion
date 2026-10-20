import SwiftUI

/// Settings root › AI Assistants (round 3: 01): "Not set up", "Off", or who can read. One self-
/// contained row, so the Settings root carries a single line for it.
struct AssistantsSettingsRow: View {
    private var source: AssistantsSource { SettingsDataSources.current.assistants }

    var body: some View {
        SettingsNavRow(
            title: Copy.AssistantAccess.rowTitle, value: source.rowValue, route: .settings(.server))
            // The sync's own published status, watched only while Settings is on screen: who
            // can read comes from the last answer the phone keeps, never a fetch from here.
            .onAppear { source.startObserving() }
            .onDisappear { source.stopObserving() }
    }
}
