import SwiftUI

/// Live Conversation (LiveDetail artboard, extraction §2.17): back "Today", "Recording now"
/// header with the Live badge, the growing on-device transcript with a leading clock rail and
/// inline quiet/missing markers, the in-progress line, the provenance footnote, and the
/// [Pause][Stop] transport bar. No tab bar. Pause/Stop end the conversation (Q13), so both pop
/// back to Today.
///
/// Times: absolute clock stamps, not elapsed offsets. The header already anchors the session
/// ("Started 12:04 PM"), a stamp has to survive into the finished Conversation unchanged, and
/// Q16 pins every displayed time to the zone the audio was RECORDED in — all three only work
/// with wall-clock time. Repeated minutes are suppressed so a burst of turns doesn't become a
/// column of identical stamps, and the still-growing turn gets no stamp at all.
struct LiveConversationScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel = LiveViewModel()
    /// 11pt "9:46 AM" plus breathing room, scaled with the timecode's own text style so the
    /// rail grows with Dynamic Type instead of truncating.
    @ScaledMetric(relativeTo: .caption2) private var railWidth: CGFloat = 60

    private let bottomAnchor = "live-transcript-bottom"

    /// At accessibility sizes a fixed leading column has no room left for the turn, so the
    /// stamp moves above the turn and the rail disappears.
    private var stacksTimeAboveTurn: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.blockGap) {
                    header
                    transcriptCard
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, Tokens.screenMargin)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .onChange(of: newestRowKey) { _, _ in follow(proxy) }
        }
        .background(Tokens.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { transportBar }
        .task { await viewModel.observe() }
    }

    // MARK: Header ("Recording now" · started line · Live badge)

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Copy.Live.title)
                    .font(AppFont.detailTitle)
                    .foregroundStyle(Tokens.label)
                Text(viewModel.snapshot.startedLine)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
            }
            Spacer(minLength: 8)
            if viewModel.snapshot.isLive {
                LiveBadge()
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Transcript (clock rail · speaker-colored turns · inline markers · in-progress line)

    private var transcriptCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if rows.isEmpty {
                    // One calm line until the transcriber produces anything — the recording is
                    // fine, there is simply nothing to show yet.
                    Text(Copy.Live.waiting)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(rows) { row in
                        switch row.item {
                        case .turn(let turn):
                            turnRow(row, turn: turn)
                        case .marker(let marker):
                            markerRow(row, marker: marker)
                        }
                    }

                    Text(viewModel.snapshot.provenance)
                        .font(AppFont.micro)
                        .foregroundStyle(Tokens.faint)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func turnRow(_ row: LiveRow, turn: LiveTurn) -> some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            Text(speakerName(turn.speaker))
                .font(AppFont.speaker)
                .foregroundStyle(speakerColor(turn.speaker))
            Text(turn.text)
                .font(AppFont.callout)
                .foregroundStyle(turn.isInProgress ? Tokens.meta : Tokens.label)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if stacksTimeAboveTurn {
                VStack(alignment: .leading, spacing: 3) {
                    if let stamp = row.stamp { stampText(stamp) }
                    content
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    rail(row.stamp)
                    content
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Copy.A11y.transcriptTurn(
                time: row.spokenStamp,
                speaker: turn.isInProgress
                    ? Copy.A11y.turnInProgress : spokenSpeakerName(turn.speaker),
                text: turn.text
            )
        )
    }

    /// "quiet for 2 min" / "2 sec missing · Bluetooth hiccup" between hairline rules — inline
    /// where it happened, never a banner, and loss is never dressed up as quiet.
    @ViewBuilder
    private func markerRow(_ row: LiveRow, marker: LiveMarker) -> some View {
        let ink = marker.kind == .missing ? Tokens.missing : Tokens.faint
        let rule = marker.kind == .missing ? Tokens.missingHair : Tokens.hairline
        let label = Text(marker.text)
            .font(.system(.caption))
            .foregroundStyle(ink)
            .layoutPriority(1)

        Group {
            if stacksTimeAboveTurn {
                VStack(alignment: .leading, spacing: 2) {
                    if let stamp = row.stamp { stampText(stamp) }
                    label
                }
            } else {
                HStack(spacing: 10) {
                    rail(row.stamp)
                    HStack(spacing: 8) {
                        label
                        Rectangle().fill(rule).frame(height: 0.5)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Copy.A11y.transcriptMarker(time: row.spokenStamp, text: marker.text)
        )
    }

    /// The leading clock column. Empty (but still reserved) when the row repeats the minute
    /// above it or is the still-growing turn, so the transcript keeps one left edge.
    private func rail(_ stamp: String?) -> some View {
        stampText(stamp ?? "")
            .frame(width: railWidth, alignment: .leading)
    }

    /// 11pt `faint` — the plan's "timestamp of record" class. Monospaced digits keep the rail
    /// from shivering as the minutes change.
    private func stampText(_ text: String) -> some View {
        Text(text)
            .font(AppFont.micro.monospacedDigit())
            .foregroundStyle(Tokens.faint)
            .lineLimit(1)
    }

    // MARK: Derivation

    /// One display row per transcript item, with its stamp already resolved: absolute clock
    /// time in the recording's zone, blanked when it repeats the row above (the old app's rule
    /// — a run of turns inside one minute is stamped once).
    private var rows: [LiveRow] {
        let zone = viewModel.snapshot.timeZone
        var previousStamp: String?
        return viewModel.snapshot.items.map { item in
            guard let at = item.stampedAt else {
                return LiveRow(item: item, stamp: nil, spokenStamp: nil)
            }
            let stamp = LiveClock.shortTime(at, in: zone)
            defer { previousStamp = stamp }
            return LiveRow(item: item, stamp: stamp == previousStamp ? nil : stamp, spokenStamp: stamp)
        }
    }

    /// Changes both when a row is added and when the in-progress tail grows, which is exactly
    /// when the view should follow along.
    private var newestRowKey: String {
        guard let last = viewModel.snapshot.items.last else { return "" }
        if case .turn(let turn) = last { return "\(last.id)-\(turn.text.count)" }
        return last.id
    }

    /// Keep the newest words on screen. Reduce Motion still scrolls — it just doesn't animate.
    private func follow(_ proxy: ScrollViewProxy) {
        guard viewModel.snapshot.isLive else { return }
        if reduceMotion {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private func speakerName(_ speaker: LiveSpeaker) -> String {
        switch speaker {
        case .you(let name), .other(let name): return name
        case .unresolved: return "·"
        }
    }

    /// VoiceOver never says "·".
    private func spokenSpeakerName(_ speaker: LiveSpeaker) -> String? {
        switch speaker {
        case .you(let name), .other(let name): return name
        case .unresolved: return nil
        }
    }

    private func speakerColor(_ speaker: LiveSpeaker) -> Color {
        switch speaker {
        case .you: return Tokens.tint
        case .other: return Tokens.speakerOther
        case .unresolved: return Tokens.captured
        }
    }

    // MARK: Transport bar ([Pause] [Stop red], barBg, top hairline)

    private var transportBar: some View {
        HStack(spacing: 10) {
            TransportButton(title: Copy.Live.pause, systemImage: "pause.fill") {
                Haptics.captureEnded()
                viewModel.pauseTapped()
                dismiss()
            }
            TransportButton(title: Copy.Live.stop, systemImage: "stop.fill", role: .stop) {
                Haptics.captureEnded()
                viewModel.stopTapped()
                dismiss()
            }
        }
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Tokens.barBg)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.barHairline).frame(height: 0.5)
        }
    }
}

// MARK: - Row + clock

/// A transcript item paired with the stamp actually shown beside it.
private struct LiveRow: Identifiable {
    let item: LiveTranscriptItem
    /// Nil when the minute repeats the row above, or the row must not be stamped.
    let stamp: String?
    /// Always the row's real time — VoiceOver reads it even where the rail stays blank.
    let spokenStamp: String?

    var id: String { item.id }
}

/// Clock stamps for the live transcript. Locale-formatted (12- or 24-hour per the user's
/// settings), in the zone the audio was recorded in (Q16) — never a hand-built string.
enum LiveClock {
    static func shortTime(_ date: Date, in zone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }
}

// MARK: - Previews

#Preview("Live conversation") {
    NavigationStack {
        LiveConversationScreen()
    }
    .environment(AppRouter())
    .tint(Tokens.tint)
}
