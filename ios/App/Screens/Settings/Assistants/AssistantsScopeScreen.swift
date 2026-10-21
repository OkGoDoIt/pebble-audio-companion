import CompanionRuntime
import SwiftUI

/// AI Assistants › Conversations (round 3: 07b, 07d): which conversations the server may hold.
/// A choice that removes some from the server says how many, counted on this phone, before
/// anything happens; a wider one applies at once, and the phone sends what it now includes.
struct AssistantsScopeScreen: View {
    private var source: AssistantsSource { SettingsDataSources.current.assistants }

    @State private var draft: ArchiveSharingScope = .all
    @State private var pending: ArchiveSharingScope?
    @State private var confirming = false
    @State private var loaded = false

    var body: some View {
        AssistantScroll {
            AssistantScopeOptions(scope: $draft, source: source)
                .padding(.top, 8)
        }
        .navigationTitle(Copy.AssistantAccess.scopeScreenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = source.sync.preferences.scope
            if let demo = source.flow.demoScopeDraft {
                source.flow.demoScopeDraft = nil
                draft = demo
            }
        }
        .task { await source.loadCounts() }
        .onChange(of: draft) { _, next in consider(next) }
        .assistantConfirm(
            isPresented: $confirming,
            title: pending.map { Copy.AssistantAccess.removeTitle(removed($0)) } ?? "",
            message: pending.map(removeMessage) ?? "",
            confirmTitle: pending.map { Copy.AssistantAccess.removeConfirm(removed($0)) } ?? "",
            onConfirm: { if let pending { apply(pending) } },
            onCancel: cancel)
    }

    private var current: ArchiveSharingScope { source.sync.preferences.scope }

    private func removed(_ scope: ArchiveSharingScope) -> Int {
        source.counts?.removed(from: current, to: scope, nowMs: source.nowMs) ?? 0
    }

    private func removeMessage(_ scope: ArchiveSharingScope) -> String {
        let cutoff = scope.cutoffMs(nowMs: source.nowMs) ?? source.nowMs
        return Copy.AssistantAccess.removeMessage(
            before: AssistantTime.longDay(cutoff), host: source.host ?? "")
    }

    /// Narrower and removing something: ask. Anything else: apply.
    private func consider(_ next: ArchiveSharingScope) {
        guard next != current else { return }
        if ArchiveSharingScope.narrows(from: current, to: next, nowMs: source.nowMs), removed(next) > 0 {
            pending = next
            confirming = true
        } else {
            apply(next)
        }
    }

    private func apply(_ scope: ArchiveSharingScope) {
        var preferences = source.sync.preferences
        preferences.scope = scope
        // `pending` stays until the sheet is gone, so its words do not empty as it slides away.
        source.setPreferences(preferences)
    }

    private func cancel() {
        pending = nil
        draft = current
    }
}
