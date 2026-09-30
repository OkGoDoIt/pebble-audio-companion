import AppDB
import SwiftUI

// One block between conversations (`HistoryStretch`): a run of gaps drawn as ONE block with ONE
// quiet label, the detail kept on the axis and in a sheet.
//
// - Height is the stretch's time on the scale; the labelled floor (44 pt) is paid once for the
//   whole stretch, never per piece.
// - The axis draws every piece at its true position and height, in its own treatment (stripes
//   for paused, dashes for not recording and deleted, the soft bar for described audio, the
//   plain line for quiet, amber for loss). Amber is never drawn shorter than 3 pt, and loss a
//   piece carries without a place of its own is a 3 pt amber tick at that piece's centre: a
//   stretch with any loss shows amber on its axis.
// - The label is one gray line, no cause, no time range (`HistoryLabels.stretchText`); the one
//   exception is a stretch that is mostly loss, whose amber title keeps its range beneath.
// - A tap opens the detail: every piece, in order, as the timeline used to say it, causes
//   included. A stretch that is a single openable no-conversation piece keeps its own
//   behaviour and is drawn as a `TimelineGap`.

struct TimelineStretch: View {
    let stretch: HistoryStretch
    var onOpenGap: (HistoryGap) -> Void = { _ in }

    @State private var showsDetail = false

    var body: some View {
        let text = HistoryLabels.stretchText(stretch)
        let opens = HistoryLabels.stretchOpensDetail(stretch)
        ZStack(alignment: .topLeading) {
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
            if let title = text.title {
                label(text, title: title)
                    .modifier(GapLabelPin())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(GapLabelPin.space))
        .background(alignment: .leading) { StretchAxis(stretch: stretch) }
        .contentShape(Rectangle())
        .onTapGesture { if opens { showsDetail = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HistoryLabels.stretchAccessibilityLabel(stretch))
        .accessibilityAddTraits(opens ? .isButton : [])
        .accessibilityHint(opens ? Copy.History.A11y.stretchHint : "")
        .sheet(isPresented: $showsDetail) {
            StretchDetailSheet(stretch: stretch) { gap in
                showsDetail = false
                onOpenGap(gap)
            }
        }
    }

    private func label(_ text: HistoryLabels.StretchText, title: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Group {
                if let loss = text.lossWords {
                    Text("\(title) · \(Text(loss).foregroundStyle(Tokens.missingText))")
                } else {
                    Text(title)
                }
            }
            .foregroundStyle(text.titleIsLoss ? Tokens.missingText : Tokens.faint)
            if let second = text.secondLine {
                Text(second).foregroundStyle(Tokens.faint)
            }
        }
        .font(AppFont.timelineMeta)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Tokens.Timeline.labelInset)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
    }
}

// MARK: - The axis, piece by piece

/// Every piece of a stretch on the axis, to scale inside the block.
struct StretchAxis: View {
    let stretch: HistoryStretch

    static let minimumLossHeight: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let total = CGFloat(max(1, stretch.durationMs))
            ZStack(alignment: .topLeading) {
                ForEach(stretch.parts) { part in
                    let top = CGFloat(part.startMs - stretch.startMs) / total * height
                    let length = CGFloat(part.endMs - part.startMs) / total * height
                    piece(part, top: top, length: length)
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }

    /// The x where the axis' centre sits, in the content column's space.
    private static var axisCentre: CGFloat {
        Tokens.Timeline.axisX + Tokens.Timeline.axisWidth / 2 - Tokens.Timeline.gutter
    }

    @ViewBuilder
    private func piece(_ part: HistoryGap, top: CGFloat, length: CGFloat) -> some View {
        switch part.kind {
        case .paused:
            bar(top: top, length: length) {
                ZStack {
                    Tokens.pausedStripeGround
                    DiagonalStripes(spacing: 4).stroke(Tokens.tint, lineWidth: 1.5)
                }
            }
        case .audioMissing:
            let drawn = max(length, Self.minimumLossHeight)
            bar(top: top + (length - drawn) / 2, length: drawn) { Tokens.missing }
        case .noConversation where part.descriptor != nil:
            bar(top: top, length: length) { Tokens.backgroundAudioBar }
        case .notRecording, .deleted:
            BrokenAxis()
                .frame(width: 4, height: max(length, 1))
                .offset(x: Self.axisCentre - 2, y: top)
        case .quiet, .noConversation, .notTranscribedYet, .transcriptionFailed:
            EmptyView()
        }
        if part.kind != .audioMissing && part.missingMs > 0 {
            // Loss the piece carries has no place of its own: one tick at its centre.
            Rectangle()
                .fill(Tokens.missing)
                .frame(width: Tokens.Timeline.barWidth, height: Self.minimumLossHeight)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .offset(
                    x: Self.axisCentre - Tokens.Timeline.barWidth / 2,
                    y: top + length / 2 - Self.minimumLossHeight / 2)
        }
    }

    private func bar<Fill: View>(top: CGFloat, length: CGFloat, @ViewBuilder _ fill: () -> Fill) -> some View {
        fill()
            .frame(width: Tokens.Timeline.barWidth, height: max(length, 1))
            .clipShape(RoundedRectangle(cornerRadius: min(Tokens.Timeline.barWidth / 2, max(length, 1) / 2)))
            .offset(x: Self.axisCentre - Tokens.Timeline.barWidth / 2, y: top)
    }
}

// MARK: - The detail

/// Every piece of a stretch, in order, as the timeline used to say it: kind and duration, the
/// time range and the recorded cause, loss in amber. An openable no-conversation piece opens
/// its audio. Never a stored error string: causes come from `HistoryLabels.gapText`.
struct StretchDetailSheet: View {
    let stretch: HistoryStretch
    var onOpenGap: (HistoryGap) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(stretch.parts) { part in
                    row(part)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.History.stretchDetailDone) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        let zone = TimeZone(identifier: stretch.zoneID) ?? .current
        return HistoryFormat.timeRange(stretch.startMs, stretch.endMs, zone: zone)
    }

    @ViewBuilder
    private func row(_ part: HistoryGap) -> some View {
        // Every piece is named in the sheet, however short: the sheet is where the detail is.
        let text = HistoryLabels.gapText(part)
        let name = text.title ?? Copy.History.gapLabel(
            Copy.History.gapName(part), duration: HistoryFormat.duration(ms: part.endMs - part.startMs))
        let zone = TimeZone(identifier: part.zoneID) ?? .current
        let detail = text.title == nil
            ? HistoryFormat.timeRange(part.startMs, part.endMs, zone: zone) : text.detail
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(AppFont.callout)
                .foregroundStyle(part.kind == .audioMissing ? Tokens.missingText : Tokens.label)
            GapDetailLine(detail: detail, missing: text.missing)
                .font(AppFont.footnote)
        }
        .accessibilityElement(children: .combine)
        if part.kind == .noConversation && part.isOpenable {
            Button { onOpenGap(part) } label: {
                HStack {
                    content
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.chevron)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Copy.History.A11y.openHint)
        } else {
            content
        }
    }
}
