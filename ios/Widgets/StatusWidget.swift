import AppIntents
import SwiftUI
import WidgetKit

// The headline widget, and the reason the widget set was rebuilt: it answers the one question a
// background-microphone product has to answer without being opened — "is it recording right
// now?" — and then lets the user do something about it in place.
//
// The day-coverage strip could not do either. It reported what had already happened, in a form
// with no action attached.

struct CaptureStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedAppGroup.statusWidgetKind, provider: CompanionProvider()) {
            entry in
            CaptureStatusView(entry: entry)
        }
        .configurationDisplayName(Copy.Widgets.statusName)
        .description(Copy.Widgets.statusDescription)
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
    }
}

struct CaptureStatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CompanionEntry

    private var status: WidgetStatus { entry.status }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            default: small
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusDotLabel(word: status.word, color: status.dot, font: AppFont.cardHead)
                .widgetURL(Route.today(date: nil).url)

            // Elapsed time of the running stretch. `.timer` ticks by itself, so this number
            // stays true between reloads instead of aging into a lie.
            if let startedAt = status.startedAt {
                Text(startedAt, style: .timer)
                    .font(AppFont.detailTitle)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 6)
            } else if let secondary = status.secondary {
                // Some status lines are a full sentence, and a two-line headline above them
                // leaves little room. Scaling beats clipping: a slightly smaller sentence still
                // says what is wrong, half a sentence does not.
                Text(secondary)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .padding(.top, 4)
            }

            Spacer(minLength: 4)

            if !status.bars(from: entry).isEmpty {
                ActivityBars(bars: status.bars(from: entry), height: 20)
                    .padding(.bottom, 8)
            }

            CaptureControlButton(offersPause: status.offersPause, isOff: status.isOff)
        }
    }

    // MARK: - Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(status.word)
                .font(.headline)
                .lineLimit(1)
            if let startedAt = status.startedAt {
                Text(startedAt, style: .timer)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
            } else if let secondary = status.secondary {
                Text(secondary).font(.caption).lineLimit(1)
            }
            if !status.bars(from: entry).isEmpty {
                ActivityBars(bars: status.bars(from: entry), palette: .monochrome, height: 8)
            }
        }
        .widgetURL(Route.today(date: nil).url)
        .widgetAccentable()
    }

    /// The smallest surface in the system: a ring that is full while capture is running, plus
    /// the one glyph that says which of the two states it is. No numbers — a circular accessory
    /// that tries to fit an elapsed time ends up illegible and still ambiguous.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: status.isRecording ? "waveform" : "pause.fill")
                .font(.system(size: 20, weight: .semibold))
        }
        .widgetURL(Route.today(date: nil).url)
        .widgetAccentable()
        .accessibilityLabel(status.word)
    }
}

// MARK: - Shared pieces

/// Dot + word, the status-card grammar shrunk to widget size.
struct StatusDotLabel: View {
    let word: String
    let color: Color
    var font: Font = AppFont.cardHead

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(word)
                .font(font)
                .foregroundStyle(Tokens.label)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }
}

/// The interactive half. `Button(intent:)` runs the intent in the extension, which posts the
/// request and waits to be told the app took it — the same path Control Center and Siri use, so
/// there is exactly one way capture changes from outside the app.
struct CaptureControlButton: View {
    let offersPause: Bool
    /// Capture is off rather than paused, so the button starts something instead of resuming
    /// it. Same intent either way — only the word changes, because "Resume" on a phone that has
    /// never recorded is the wrong promise.
    var isOff: Bool = false

    var body: some View {
        Group {
            if offersPause {
                Button(intent: PauseCaptureIntent()) {
                    label(Copy.Live.pause, systemImage: "pause.fill")
                }
                .accessibilityLabel(Copy.Widgets.pauseHint)
            } else {
                Button(intent: ResumeCaptureIntent()) {
                    label(
                        isOff ? Copy.Status.startRecording : Copy.Status.resume,
                        systemImage: "waveform"
                    )
                }
                .accessibilityLabel(
                    isOff ? Copy.Widgets.startHint : Copy.Widgets.resumeHint
                )
            }
        }
        .buttonStyle(.plain)
        .tint(Tokens.tint)
    }

    private func label(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
            Text(text).font(AppFont.microBold).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(Tokens.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Tokens.tintFill12, in: Capsule(style: .continuous))
    }
}

extension WidgetStatus {
    /// The activity profile, but only when it has something to say.
    ///
    /// Two ways it does not: a stale snapshot (its bars would draw a conversation that ended
    /// hours ago as if it were now), and a window in which nothing happened at all — an
    /// all-`off` strip renders as a row of grey stubs that reads as a broken view rather than
    /// as "nothing happened", which the words above already say better.
    func bars(from entry: CompanionEntry) -> [CoverageSnapshot.ActivityBar] {
        guard !isStale, let snapshot = entry.snapshot else { return [] }
        guard snapshot.activity.contains(where: { $0.kind != .off }) else { return [] }
        return snapshot.activity
    }
}

#Preview("Small", as: .systemSmall) {
    CaptureStatusWidget()
} timeline: {
    CompanionEntry.placeholder()
    CompanionEntry.empty()
}

#Preview("Rectangular", as: .accessoryRectangular) {
    CaptureStatusWidget()
} timeline: {
    CompanionEntry.placeholder()
}
