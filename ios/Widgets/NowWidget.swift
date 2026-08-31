import AppIntents
import SwiftUI
import WidgetKit

// "Recording now" — the medium widget Roger asked for: what is being recorded, the last thing
// heard in it, how alive the last few minutes were, and the control, all without opening the app.
//
// Everything on it is allowed to be absent, and each absence has its own honest line. A title
// that enrichment has not written yet is "This conversation", not a made-up name; a transcript
// line that does not exist yet is "Listening…", not filler; a stale snapshot drops the live half
// entirely rather than presenting old words as current.

struct NowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedAppGroup.nowWidgetKind, provider: CompanionProvider()) {
            entry in
            NowWidgetView(entry: entry)
        }
        .configurationDisplayName(Copy.Widgets.nowName)
        .description(Copy.Widgets.nowDescription)
        .supportedFamilies([.systemMedium])
    }
}

struct NowWidgetView: View {
    let entry: CompanionEntry

    private var status: WidgetStatus { entry.status }
    private var snapshot: CoverageSnapshot? { status.isStale ? nil : entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if status.isRecording {
                live
            } else {
                idle
            }
            Spacer(minLength: 0)
            bottom
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(Route.live.url)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDotLabel(word: status.word, color: status.dot)
            Spacer(minLength: 8)
            if let startedAt = status.startedAt {
                Text(startedAt, style: .timer)
                    .font(AppFont.cardHead)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Title + the newest line actually said. Two lines of transcript is the most a medium
    /// widget can show without the text becoming a wall nobody reads at a glance.
    private var live: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot?.liveTitle?.nonBlank ?? Copy.Widgets.untitledConversation)
                .font(AppFont.rowTitle)
                .foregroundStyle(Tokens.label)
                .lineLimit(1)
            Text(snapshot?.liveLine?.nonBlank ?? Copy.Widgets.listening)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.secondaryBody)
                .lineLimit(2)
        }
    }

    private var idle: some View {
        Text(status.secondary ?? Copy.Widgets.nothingRecording)
            .font(AppFont.footnote)
            .foregroundStyle(Tokens.tertiary)
            .lineLimit(2)
    }

    private var bottom: some View {
        HStack(alignment: .center, spacing: 12) {
            let bars = status.bars(from: entry)
            if bars.isEmpty {
                Spacer(minLength: 0)
            } else {
                ActivityBars(bars: bars, height: 26)
            }
            CaptureControlButton(offersPause: status.offersPause)
                .frame(width: 104)
        }
    }
}

extension String {
    /// Blank strings are absent strings: a title of spaces must fall back to the honest
    /// placeholder rather than render as an empty row that looks like a layout bug.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview("Medium", as: .systemMedium) {
    NowWidget()
} timeline: {
    CompanionEntry.placeholder()
    CompanionEntry.empty()
}
