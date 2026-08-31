import SwiftUI

/// Live Conversation (LiveDetail artboard, extraction §2.17): back "Today", "Recording now"
/// header with the Live badge, the conversation's transcript growing at the bottom, and the
/// [Pause][Stop] transport bar. No tab bar. Pause/Stop end the conversation (Q13), so both
/// pop back to Today.
///
/// This is the Conversation screen's transcript card, not a parallel one: same speaker
/// blocks, same clock stamps beside the names, same inline quiet/missing markers. What the
/// user watches being written here is exactly what they will find in the Library afterwards
/// — including everything captured before the current segment, which this screen used to
/// throw away every time the link dropped and a new segment opened.
///
/// Times: absolute clock stamps, not elapsed offsets. The header already anchors the session
/// ("Started 12:04 PM"), a stamp has to survive into the finished Conversation unchanged, and
/// Q16 pins every displayed time to the zone the audio was RECORDED in. The still-growing
/// turn gets no stamp at all — its words are still being revised.
struct LiveConversationScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = LiveViewModel()

    private let bottomAnchor = "live-transcript-bottom"

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

    // MARK: Transcript (the Conversation card, still being written)

    @ViewBuilder
    private var transcriptCard: some View {
        if viewModel.snapshot.items.isEmpty {
            Card {
                // One calm line until the transcriber produces anything — the recording is
                // fine, there is simply nothing to show yet.
                Text(Copy.Live.waiting)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            TranscriptView(
                transcript: viewModel.snapshot.items,
                provenance: viewModel.snapshot.provenance,
                timeZone: viewModel.snapshot.timeZone
            )
        }
    }

    // MARK: Derivation

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

// MARK: - Previews

#Preview("Live conversation") {
    NavigationStack {
        LiveConversationScreen()
    }
    .environment(AppRouter())
    .tint(Tokens.tint)
}
