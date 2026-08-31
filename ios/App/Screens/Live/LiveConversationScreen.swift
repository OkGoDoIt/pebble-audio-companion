import SwiftUI

/// Live Conversation (LiveDetail artboard, extraction §2.17): back "Today", "Recording now"
/// header with the Live badge, the growing on-device transcript with inline quiet markers
/// and the in-progress line, the provenance footnote, and the [Pause][Stop] transport bar.
/// No tab bar. Pause/Stop end the conversation (Q13), so both pop back to Today.
struct LiveConversationScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = LiveViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                header
                transcriptCard
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 4)
            .padding(.bottom, 16)
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
    }

    // MARK: Transcript (speaker-colored turns · inline quiet markers · in-progress line)

    private var transcriptCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.snapshot.items) { item in
                    switch item {
                    case .turn(let turn):
                        turnView(turn)
                    case .quiet(_, let text):
                        quietMarker(text)
                    }
                }

                Text(Copy.Live.provenance)
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.faint)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
    }

    private func turnView(_ turn: LiveTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
    }

    private func speakerName(_ speaker: LiveSpeaker) -> String {
        switch speaker {
        case .you(let name), .other(let name): return name
        case .unresolved: return "·"
        }
    }

    private func speakerColor(_ speaker: LiveSpeaker) -> Color {
        switch speaker {
        case .you: return Tokens.tint
        case .other: return Tokens.speakerOther
        case .unresolved: return Tokens.captured
        }
    }

    /// Centered "quiet for N" between gray hairline rules — calm known-silence, inline
    /// where it happened (never a banner).
    private func quietMarker(_ text: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Tokens.hairline).frame(height: 0.5)
            Text(text)
                .font(.system(.caption))
                .foregroundStyle(Tokens.faint)
                .fixedSize()
            Rectangle().fill(Tokens.hairline).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Transport bar ([Pause] [Stop red], barBg, top hairline)

    private var transportBar: some View {
        HStack(spacing: 10) {
            TransportButton(title: Copy.Live.pause, systemImage: "pause.fill") {
                viewModel.pauseTapped()
                dismiss()
            }
            TransportButton(title: Copy.Live.stop, systemImage: "stop.fill", role: .stop) {
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
