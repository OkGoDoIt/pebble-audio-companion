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
//  - every action can be taken back, and the sheet says how. A split makes a new conversation,
//    and joining that one to the previous conversation undoes it; a join dissolves the later
//    conversation into the earlier one, so the join is listed INSIDE the conversation it made,
//    with "separate them again" on it. (The rows used to be switches undone by tapping again.
//    That stopped being true the moment a split could land anywhere: the place you split at
//    leaves this conversation, and its row with it.)
//
// Where a split is offered changed with the conversation unit. A conversation was whole
// recordings, so the only places on offer were the joins between them — every fifteen minutes,
// wherever the file happened to rotate. It is now a range of each recording, and can start
// between any two turns, so the places offered are the ones a person would pick: where talk
// resumed after a break (`ConversationSplitPoints`).

/// One place inside a conversation: where a new one could start, or where the person joined
/// two. Supplied by the screen's data source.
struct ConversationBoundaryPoint: Identifiable, Equatable {
    /// The position itself — a recording and an offset into its stored audio. It is what a
    /// decision is stored against, because it is the only thing a regroup does not move.
    let cut: ConversationCut
    /// Wall clock of the first word after it.
    let startedAt: Date
    /// How far into this conversation that is.
    let offsetMs: Int64
    /// How long nobody spoke before it. Zero for a join, which is not defined by a pause.
    var pauseMs: Int64 = 0
    /// The first few words said after it, so the place can be recognised. Empty when there
    /// are none to quote.
    var opening: String = ""

    var id: String { "\(cut.segmentId)@\(cut.mediaMs)" }
}

/// The sheet. Pure presentation: it holds no store, so it previews and tests without a database
/// and the screen decides where the values come from.
struct ConversationBoundaryEditor: View {
    let startReason: ConversationStartReason?
    /// False for the first conversation there is — nothing to join to.
    let canJoinWithPrevious: Bool
    let isJoinedWithPrevious: Bool
    /// Places where talk resumed after a break: tapping one starts a new conversation there.
    let points: [ConversationBoundaryPoint]
    /// Places inside this conversation where the person joined two. Tapping one takes the
    /// join back.
    var joins: [ConversationBoundaryPoint] = []
    /// What the last split did — a split removes its own row (the place is now the start of
    /// another conversation), so without this the list just gets shorter. Shown in place of
    /// the list's instruction.
    var notice: String? = nil
    /// Q16 — the places are named by the clock in the zone the audio was recorded in, like the
    /// stamps in the transcript behind this sheet.
    var timeZone: TimeZone = .current
    var onToggleJoinWithPrevious: (Bool) -> Void
    var onSplit: (ConversationBoundaryPoint) -> Void
    var onSeparate: (ConversationBoundaryPoint) -> Void = { _ in }
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
                    if !joins.isEmpty { joinedSection }
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
            // Only once the join stands: "untick to separate them again" is worth a line,
            // "here is when you might want to join" is not — the row says that itself.
            if isJoinedWithPrevious {
                Text(Copy.Boundaries.undoJoin)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The joins that made this conversation the size it is. Ticked, because each is a
    /// decision that currently stands; tapping takes it back.
    private var joinedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(Copy.Boundaries.joinedHeader)
            ListCard {
                ForEach(joins) { point in
                    CheckRow(
                        title: Copy.Boundaries.place(
                            time: clock(point.startedAt), offsetMs: point.offsetMs),
                        detail: Copy.Boundaries.opening(point.opening),
                        isOn: true,
                        action: { onSeparate(point) }
                    )
                    .accessibilityHint(Copy.Boundaries.undoJoin)
                }
            }
            Text(Copy.Boundaries.joinedFooter)
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
                        PlaceRow(
                            title: Copy.Boundaries.place(
                                time: clock(point.startedAt), offsetMs: point.offsetMs),
                            detail: Copy.Boundaries.afterBreak(
                                point.pauseMs, opening: point.opening),
                            action: { onSplit(point) }
                        )
                    }
                }
            }
            // After a tap the instruction gives way to what the tap did: the row that was
            // tapped is gone (that place now starts another conversation), so this is what
            // says so — and how to take it back, since the split may have used the last row
            // and the instruction with it.
            if let notice {
                Text(notice)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !points.isEmpty {
                Text(Copy.Boundaries.splitFooter)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
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

/// A place that can be acted on once: no checkmark, because nothing here is on or off. Tapping
/// starts a new conversation at it, after which the place belongs to that conversation and the
/// row is gone from this one.
private struct PlaceRow: View {
    let title: String
    var detail: String? = nil
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
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 10)
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(Tokens.tint)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Copy.Boundaries.splitHint)
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

#Preview("Split or join") {
    ConversationBoundaryEditor(
        startReason: .quiet,
        canJoinWithPrevious: true,
        isJoinedWithPrevious: false,
        points: [
            ConversationBoundaryPoint(
                cut: ConversationCut(segmentId: "seg-1", mediaMs: 612_000),
                startedAt: .now.addingTimeInterval(-3600), offsetMs: 15 * 60_000,
                pauseMs: 95_000, opening: "So about the trip to Lisbon, I was thinking we…"),
            ConversationBoundaryPoint(
                cut: ConversationCut(segmentId: "seg-3", mediaMs: 0),
                startedAt: .now.addingTimeInterval(-1800), offsetMs: 45 * 60_000,
                pauseMs: 240_000, opening: "Right, where were we?"),
        ],
        joins: [
            ConversationBoundaryPoint(
                cut: ConversationCut(segmentId: "seg-2", mediaMs: 301_500),
                startedAt: .now.addingTimeInterval(-2700), offsetMs: 30 * 60_000,
                opening: "Anyway, the other thing was the budget.")
        ],
        onToggleJoinWithPrevious: { _ in },
        onSplit: { _ in },
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
        onSplit: { _ in },
        onDone: {}
    )
}
