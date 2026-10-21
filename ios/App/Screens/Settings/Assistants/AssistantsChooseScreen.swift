import CompanionRuntime
import SwiftUI

/// Step 2 of 3, Choose (round 3: 04a, 04b): which conversations the server may hold, what
/// assistants may also do, and a preview of exactly what goes, which follows the choices. Start
/// Syncing sends the choices to the server and starts the sync; nothing went before it.
struct AssistantsChooseScreen: View {
    private var source: AssistantsSource { SettingsDataSources.current.assistants }

    @State private var scope: ArchiveSharingScope = .all
    @State private var clips = false
    @State private var edits = false
    @State private var loaded = false

    var body: some View {
        @Bindable var flow = source.flow
        AssistantScroll(spacing: 10, bottom: 34) {
            SetupStepBar(now: 1)
            Text(Copy.AssistantAccess.chooseTitle)
                .font(AppFont.screenTitle)
                .kerning(0.36)
                .foregroundStyle(Tokens.label)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
            AssistantScopeOptions(scope: $scope, source: source)
            AssistantSectionHeader(title: Copy.AssistantAccess.mayAlso)
            AssistantMayAlso(
                preferences: ArchivePreferences(clips: clips, edits: edits, scope: scope),
                set: { clips = $0.clips; edits = $0.edits })
            AssistantGoesBlock(
                heading: Copy.AssistantAccess.whatGoesTo(source.host ?? AssistantsDemo.host),
                paragraphs: [
                    Copy.AssistantAccess.choosePreview(
                        scope, count: source.counts?.count(scope, nowMs: source.nowMs) ?? 0,
                        clips: clips, edits: edits)
                ],
                background: Tokens.surface)
                .padding(.top, 2)
            Button(Copy.AssistantAccess.startSyncing) {
                source.startSyncing(ArchivePreferences(clips: clips, edits: edits, scope: scope))
            }
            .buttonStyle(.assistantFilled)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(Copy.AssistantAccess.chooseTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            scope = source.sync.preferences.scope
            clips = source.sync.preferences.clips
            edits = source.sync.preferences.edits
        }
        .task { await source.loadCounts() }
        .navigationDestination(isPresented: $flow.showConnect) { AssistantsConnectScreen(inSetup: true) }
    }
}

/// The three scope choices, with the days picker inside the rolling one when it is chosen. The
/// counts are the phone's own. Used by Choose and by Conversations (the scope screen).
struct AssistantScopeOptions: View {
    @Binding var scope: ArchiveSharingScope
    let source: AssistantsSource
    /// The rolling window's days when it is not the choice yet.
    @State private var days = ArchiveSharingScope.defaultRollingDays

    var body: some View {
        let now = source.nowMs
        let counts = source.counts
        let todayStart = AssistantTime.logicalDayStart(now)
        VStack(spacing: 8) {
            AssistantOptionCard(
                title: Copy.AssistantAccess.allTitle,
                line: Copy.AssistantAccess.allLine(
                    count: counts?.total ?? 0,
                    oldest: counts?.oldestStartMs.map { AssistantTime.longDay($0) }),
                detail: scope == .all ? Copy.AssistantAccess.keepAudioLine : nil,
                isSelected: scope == .all,
                action: { scope = .all }
            ) { EmptyView() }
            AssistantOptionCard(
                title: Copy.AssistantAccess.sinceTitle(AssistantTime.longDay(todayStart)),
                line: Copy.AssistantAccess.sinceLine(count: counts?.count(since: todayStart) ?? 0),
                isSelected: isSince,
                action: { scope = .since(ms: todayStart) }
            ) { EmptyView() }
            AssistantOptionCard(
                title: Copy.AssistantAccess.rollingTitle(shownDays),
                line: rollingCountLine(days: shownDays, now: now),
                detail: isRolling
                    ? Copy.AssistantAccess.rollingLine(shownDays) : Copy.AssistantAccess.rollingShortLine,
                isSelected: isRolling,
                action: { scope = .lastDays(shownDays) }
            ) {
                if isRolling {
                    AssistantSegmented(
                        values: ArchiveSharingScope.rollingChoices, label: { "\($0)" },
                        selection: Binding(
                            get: { shownDays },
                            set: {
                                days = $0
                                scope = .lastDays($0)
                            }),
                        accessibilityName: Copy.AssistantAccess.daysAccessibility)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.AssistantAccess.conversationsAccessibility)
        .onAppear {
            if case .lastDays(let current) = scope { days = current }
        }
    }

    private var isSince: Bool { if case .since = scope { return true } else { return false } }
    private var isRolling: Bool { if case .lastDays = scope { return true } else { return false } }
    private var shownDays: Int { if case .lastDays(let d) = scope { return d } else { return days } }

    private func rollingCountLine(days: Int, now: Int64) -> String {
        let cutoff = now - Int64(days) * 86_400_000
        let counts = source.counts
        let count = counts?.count(since: cutoff) ?? 0
        // "Back to" the window's start, or the first conversation when the window reaches past it.
        let since = max(cutoff, counts?.oldestStartMs ?? cutoff)
        return Copy.AssistantAccess.rollingCountLine(count: count, since: AssistantTime.longDay(since))
    }
}
