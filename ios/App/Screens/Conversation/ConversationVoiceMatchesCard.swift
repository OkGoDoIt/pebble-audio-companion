import SwiftUI

/// Audio evidence stays useful even when ASR supplied no words or only coarse timestamps.
/// This never presents the matched person's identity as the author of unaligned text.
struct ConversationVoiceMatchesCard: View {
    let matches: [ConversationVoiceMatch]
    let canPlay: Bool
    let onPlay: (ConversationVoiceMatch) -> Void
    let onStop: () -> Void
    let conversationId: String
    let onChanged: () -> Void
    @State private var reviewing = false
    @State private var selected: ConversationVoiceMatch?

    private var names: String {
        var seen = Set<String>()
        return matches.filter { seen.insert($0.person?.id ?? "unnamed").inserted }.map(\.name).joined(separator: ", ")
    }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(matches.allSatisfy(\.isAutomatic) ? "Recognized in the audio" : "Voices in the audio", systemImage: "waveform")
                    .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                Text(names).font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                Text(matches.allSatisfy(\.isAutomatic)
                     ? "Listen to a clip to confirm or change a name. These matches can’t be placed precisely beside the transcript yet."
                     : "Listen to a clip to review or change who is speaking. Names you chose are kept until you change them.")
                    .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                Button("Review voices (\(matches.count))") { reviewing = true }
                    .buttonStyle(.borderedTint)
            }
        }
        .sheet(isPresented: $reviewing, onDismiss: onStop) {
            NavigationStack {
                List {
                    ForEach(matches) { match in
                        HStack(spacing: 12) {
                            VoiceAvatar(name: match.person?.name ?? "?", isCurrentUser: match.person?.isCurrentUser ?? false)
                            Button { onPlay(match) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(match.name).font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                                    Text(match.isAutomatic ? "Recognized" : "Chosen by you")
                                        .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                                    Label(match.timeLabel, systemImage: "play.fill")
                                        .font(AppFont.footnote.monospacedDigit()).foregroundStyle(Tokens.tint)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!canPlay)
                            Button { onStop(); selected = match } label: {
                                Image(systemName: "pencil").foregroundStyle(Tokens.tint).frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel("Identify voice at \(match.timeLabel)")
                        }.listRowBackground(Tokens.surface)
                    }
                }
                .scrollContentBackground(.hidden).background(Tokens.ground)
                .navigationTitle("Voices in the audio").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(Copy.Common.done) { reviewing = false } } }
                .sheet(item: $selected, onDismiss: onStop) { match in
                    SpeakerRenameSheet(conversationId: conversationId, turn: match.correction,
                        onPlay: canPlay ? { onPlay(match) } : nil, onStop: onStop, onDone: onChanged)
                }
            }.tint(Tokens.tint)
        }
    }
}
