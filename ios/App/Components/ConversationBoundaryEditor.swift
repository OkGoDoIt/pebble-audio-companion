import AppDB
import SwiftUI

// The person's own answer to "is this one conversation or two?".
//
// The automatic rules (kit: `AppDB/ConversationBoundaries.swift`) are deliberately conservative:
// they end a conversation at a long settled stretch of nothing said, and leave the ambiguous
// middle alone. That is the right default, and it will still be wrong sometimes — a manual Stop
// is a strong signal but not an absolute one, and only the person who was there knows whether
// the twelve quiet minutes were a coffee break or the end of the afternoon.
//
// The alternative designs were both worse. A cleverer automatic rule for stop-then-resume asks
// the app to guess intent it cannot see; an "aggressiveness" setting asks the person to reason
// about the algorithm in the abstract, days before they see what it did. One reversible control
// on the boundary in front of them needs neither.
//
// Two properties this UI must keep, because they are what make the automatic layer safe to ship:
//  - nothing here touches audio, transcripts or notes. The footer says so out loud, because a
//    control called "split" on a recording app reads like destructive editing.
//  - every action is undoable by repeating it. Overrides are stored per segment and beat the
//    rules in both directions, so "put it back" is always available.

/// One place inside a conversation where a new one could start: the member recording that would
/// begin it. Supplied by the screen, which already has the member metas loaded.
struct ConversationBoundaryPoint: Identifiable, Equatable {
    /// The member segment that would start the new conversation. Also the override's key.
    let id: String
    /// Wall clock where the new conversation would begin.
    let startedAt: Date
    /// How far into this conversation that is.
    let offsetMs: Int64
    /// True while the person's own split stands here.
    var isSplit: Bool
}

/// The sheet. Pure presentation: it holds no store, so it previews and tests without a database
/// and the screen decides where the values come from.
struct ConversationBoundaryEditor: View {
    let startReason: ConversationStartReason?
    /// False for the first conversation there is — nothing to join to.
    let canJoinWithPrevious: Bool
    let isJoinedWithPrevious: Bool
    let points: [ConversationBoundaryPoint]
    var onToggleJoinWithPrevious: (Bool) -> Void
    var onToggleSplit: (String, Bool) -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SheetTitleRow(title: Copy.Boundaries.title) {
                        Button(Copy.Common.done, action: onDone)
                            .font(AppFont.headline)
                            .foregroundStyle(Tokens.tint)
                    }
                    if let because = Copy.Boundaries.startedBecause(startReason) {
                        Text(because)
                            .font(AppFont.subBody)
                            .foregroundStyle(Tokens.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if canJoinWithPrevious { joinSection }
                    splitSection
                    Text(Copy.Boundaries.footer)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Tokens.screenMargin)
                .padding(.bottom, 24)
            }
        }
        .background(Tokens.ground)
    }

    private var joinSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(Copy.Boundaries.joinHeader)
            ListCard {
                CheckRow(
                    title: isJoinedWithPrevious
                        ? Copy.Boundaries.joined : Copy.Boundaries.join,
                    isOn: isJoinedWithPrevious,
                    action: { onToggleJoinWithPrevious(!isJoinedWithPrevious) }
                )
            }
            Text(isJoinedWithPrevious ? Copy.Boundaries.undoJoin : Copy.Boundaries.joinFooter)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var splitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(Copy.Boundaries.splitHeader)
            if points.isEmpty {
                Text(Copy.Boundaries.noSplitPoints)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ListCard {
                    ForEach(points) { point in
                        CheckRow(
                            title: point.startedAt.formatted(date: .omitted, time: .shortened),
                            detail: Copy.Boundaries.minutesIn(point.offsetMs),
                            isOn: point.isSplit,
                            action: { onToggleSplit(point.id, !point.isSplit) }
                        )
                    }
                }
                Text(Copy.Boundaries.splitFooter)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppFont.sectionHeader)
            .kerning(0.4)
            .foregroundStyle(Tokens.meta)
    }
}

/// A row that is on or off, with the state carried by a checkmark rather than a toggle: these
/// are decisions about the recording in front of you, not preferences, and a switch invites the
/// reading that something is being turned on for the future.
private struct CheckRow: View {
    let title: String
    var detail: String? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                    }
                }
                Spacer(minLength: 10)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Tokens.tint : Tokens.chevron)
                    .imageScale(.large)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// The one calm line under a conversation's title saying why it starts where it does.
///
/// This is the other half of shipping an automatic splitter: a split the reader cannot account
/// for is worse than no split at all. Renders nothing when there is nothing to say.
struct ConversationStartCaption: View {
    let startReason: ConversationStartReason?

    var body: some View {
        if let text = Copy.Boundaries.startedBecause(startReason) {
            Text(text)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Reads and writes the person's decisions. Thin on purpose — the grouping itself is derived
/// and recomputed by the pipeline, so all this owns is the override rows.
@MainActor
struct ConversationBoundaryEditing {
    let overrides: BoundaryOverrideStore
    /// Called after a write so the caller can rebuild the grouping and refresh the screen.
    var onChanged: () async -> Void = {}

    func decisions(forSegments segmentIds: [String]) async -> [String: BoundaryDecision] {
        let all = (try? await overrides.all()) ?? [:]
        return all.filter { segmentIds.contains($0.key) }
    }

    /// Toggling a split writes `.split` on the member that would start the new conversation,
    /// and clearing it hands the join back to the automatic rules.
    func setSplit(atSegmentId segmentId: String, on: Bool) async {
        try? await overrides.set(segmentId: segmentId, decision: on ? .split : nil)
        await onChanged()
    }

    /// Joining writes `.join` on this conversation's FIRST member, which is the segment whose
    /// join to the previous conversation is being overruled.
    func setJoinWithPrevious(firstSegmentId: String, on: Bool) async {
        try? await overrides.set(segmentId: firstSegmentId, decision: on ? .join : nil)
        await onChanged()
    }
}

#Preview("Split or join") {
    ConversationBoundaryEditor(
        startReason: .quiet,
        canJoinWithPrevious: true,
        isJoinedWithPrevious: false,
        points: [
            ConversationBoundaryPoint(
                id: "seg-2", startedAt: .now.addingTimeInterval(-3600), offsetMs: 15 * 60_000,
                isSplit: false),
            ConversationBoundaryPoint(
                id: "seg-3", startedAt: .now.addingTimeInterval(-1800), offsetMs: 45 * 60_000,
                isSplit: true),
        ],
        onToggleJoinWithPrevious: { _ in },
        onToggleSplit: { _, _ in },
        onDone: {}
    )
}

#Preview("Nothing to split") {
    ConversationBoundaryEditor(
        startReason: .userStop,
        canJoinWithPrevious: true,
        isJoinedWithPrevious: true,
        points: [],
        onToggleJoinWithPrevious: { _ in },
        onToggleSplit: { _, _ in },
        onDone: {}
    )
}
