import SwiftUI
import WidgetKit

// One entry type, one provider, one status derivation — shared by all four widgets.
//
// The extension reads exactly two things (plan 6.8): `coverage_snapshot.json` in the App Group,
// and the small capture-intent defaults next to it. No database, no segment directory, no
// coverage computation — a widget that opened the DB would fight the app for the writer lock
// and blow the extension's memory budget.
//
// Two sources, two jobs, deliberately not merged:
//   • the SNAPSHOT says what the app last observed (its prose headline is the one approved
//     status vocabulary — the widget never re-derives status words of its own, U9);
//   • the DEFAULTS say what the user last ASKED for, which is always current because an intent
//     writes them synchronously. That is what decides whether the button offers Pause or
//     Resume, and what lets a tap look answered before the watch has replied.

struct CompanionEntry: TimelineEntry {
    let date: Date
    /// nil = nothing has been written yet (fresh install, or capture never started).
    let snapshot: CoverageSnapshot?
    /// What the user last asked for and the app has not confirmed yet.
    let pending: SharedCaptureIntent?
    /// What the app has actually applied.
    let applied: SharedCaptureIntent

    static func current(now: Date = Date()) -> CompanionEntry {
        CompanionEntry(
            date: now,
            snapshot: CoverageSnapshot.loadFromAppGroup(),
            pending: CaptureIntentBridge.pendingRequest()?.intent,
            applied: CaptureIntentBridge.appliedIntent()
        )
    }

    /// Redacted-placeholder + gallery sample: shape-accurate, obviously not real data.
    static func placeholder(now: Date = Date()) -> CompanionEntry {
        CompanionEntry(
            date: now, snapshot: .sample(now: now), pending: nil, applied: .active
        )
    }

    /// Nothing written yet — the honest empty state, not an invented empty day.
    static func empty(now: Date = Date()) -> CompanionEntry {
        CompanionEntry(date: now, snapshot: nil, pending: nil, applied: .off)
    }

    var status: WidgetStatus { WidgetStatus(entry: self) }
}

/// Everything a widget needs to draw an honest state, derived once.
struct WidgetStatus {
    let word: String
    let dot: Color
    /// True only when the app last observed real capture AND the snapshot is fresh enough to
    /// still stand behind that. A stale file is never allowed to assert "Recording".
    let isRecording: Bool
    /// Start of the running stretch, for the self-ticking elapsed timer. Nil whenever we would
    /// otherwise be counting up from a number the app has not confirmed recently.
    let startedAt: Date?
    /// The control to offer: pausing what is running, or resuming what is not.
    let offersPause: Bool
    /// Secondary line: the status detail, or the "as of" hedge when the snapshot is stale.
    let secondary: String?
    let isStale: Bool
    let hasData: Bool

    init(entry: CompanionEntry) {
        let snapshot = entry.snapshot
        let stale = snapshot?.isStale(at: entry.date) ?? false
        isStale = stale
        hasData = snapshot != nil

        // What the user asked for wins the WORD while it is unconfirmed — the switch moved, so
        // the widget must not keep showing the old state as if the tap never happened — but it
        // is spelled with an ellipsis, because the watch has not answered yet.
        let observed = snapshot?.headline.isEmpty == false ? snapshot!.headline : nil
        switch entry.pending {
        case .active where snapshot?.state != .recording:
            word = Copy.Widgets.resuming
        case .paused where snapshot?.state == .recording:
            word = Copy.Widgets.pausing
        default:
            word = observed ?? Copy.Status.notRecording
        }

        // The applied intent is always current; the snapshot may not be. Offering "Pause" for
        // something already paused is the kind of small lie this product cannot afford.
        offersPause = (entry.pending ?? entry.applied) == .active

        let claimsRecording = snapshot?.state == .recording && !stale
        isRecording = claimsRecording
        startedAt = claimsRecording ? snapshot?.currentStartedAt : nil

        if snapshot == nil {
            dot = Tokens.neutralDot
            secondary = Copy.Widgets.noData
        } else if stale {
            dot = Tokens.neutralDot
            secondary = Copy.Widgets.asOf(
                WidgetStatus.clock.string(
                    from: Date(timeIntervalSince1970: Double(snapshot!.generatedAtMs) / 1000)
                )
            )
        } else {
            dot = WidgetStatus.color(forDot: snapshot!.dot)
            secondary = snapshot!.detail
        }
    }

    /// The status dot's approved semantic colors (`StatusDot`), spelled as the snapshot does.
    static func color(forDot dot: String) -> Color {
        switch dot {
        case "active": return Tokens.good
        case "attention": return Tokens.attention
        case "consent": return Tokens.tint
        case "problem": return Tokens.destructive
        case "info": return Tokens.tint
        default: return Tokens.neutralDot
        }
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

/// The one timeline provider. Every widget uses it — they differ in what they DRAW, never in
/// where their truth comes from.
struct CompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> CompanionEntry { .placeholder() }

    func getSnapshot(in context: Context, completion: @escaping (CompanionEntry) -> Void) {
        // The widget gallery must never show a stranger's real day; everywhere else is live.
        completion(context.isPreview ? .placeholder() : .current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CompanionEntry>) -> Void) {
        let entry = CompanionEntry.current()
        // Elapsed time ticks on its own (`Text(_:style:.timer)`), so the reload budget buys
        // fresh WORDS, not a fresh clock. While something is being recorded the title and the
        // transcript line change often enough to be worth 5 minutes; otherwise nothing moves
        // without an app event, and the app reloads us directly when one happens.
        let minutes = entry.status.isRecording ? 5 : 20
        let next =
            Calendar.current.date(byAdding: .minute, value: minutes, to: entry.date)
            ?? entry.date.addingTimeInterval(Double(minutes) * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Gallery / placeholder sample

extension CoverageSnapshot {
    /// Shape-accurate sample content for the gallery and the redacted placeholder.
    static func sample(now: Date = Date()) -> CoverageSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dayStart = nowMs - 10 * 3_600_000
        func span(_ kind: Span.Kind, _ fromHr: Double, _ toHr: Double) -> Span {
            Span(
                kind: kind,
                startMs: dayStart + Int64(fromHr * 3_600_000),
                endMs: dayStart + Int64(toHr * 3_600_000)
            )
        }
        let levels: [Double] = [
            0.9, 0.7, 0.95, 0.4, 0.85, 1, 0.6, 0.2, 0.75, 0.9,
            0.5, 0.8, 1, 0.65, 0.3, 0.9, 0.85, 0.45, 0.7, 1,
            0.55, 0.8, 0.35, 0.9, 0.75, 1, 0.6, 0.85, 0.5, 0.95,
        ]
        return CoverageSnapshot(
            generatedAtMs: nowMs,
            dateKey: "",
            dayStartMs: dayStart,
            nowMs: dayStart + 10 * 3_600_000,
            spans: [
                span(.recorded, 2, 4.4), span(.quiet, 4.4, 5.8), span(.recorded, 5.8, 8.7),
                span(.missing, 8.7, 8.9), span(.recorded, 8.9, 10),
            ],
            totalRecordedMs: Int64(4.2 * 3_600_000),
            totalMissingMs: 60_000,
            headline: Copy.Status.recording,
            detail: nil,
            dot: "active",
            isRecording: true,
            state: .recording,
            currentStartedAtMs: nowMs - 22 * 60 * 1000,
            liveTitle: "Kitchen renovation quote",
            liveLine: "We can start the week after next if the tiles arrive on time",
            activity: levels.map { ActivityBar(kind: $0 < 0.25 ? .quiet : .recorded, level: $0) },
            activityWindowMs: 10 * 60 * 1000,
            followUps: [
                FollowUp(id: "1", text: "Send the measurements to Dana", conversationId: "c1"),
                FollowUp(id: "2", text: "Confirm the tile order by Friday", conversationId: "c1"),
                FollowUp(id: "3", text: "Book the electrician", conversationId: "c2"),
            ],
            openFollowUpCount: 4
        )
    }
}
