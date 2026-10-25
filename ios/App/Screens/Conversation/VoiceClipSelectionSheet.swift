import SwiftUI

/// Chooses stored audio without relying on transcription or a predicted identity.
/// Every clip belongs to one conversation piece, even when playback joins several pieces.
struct VoiceClipSelectionSheet: View {
    let pieces: [ConversationAudioPiece]
    let initialPlaybackMs: Int64
    let onPlay: (TranscriptTurn) -> Void
    let onStop: () -> Void
    let onChoose: (TranscriptTurn) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int
    @State private var startSeconds: Double
    @State private var durationSeconds: Double

    init(pieces: [ConversationAudioPiece], initialPlaybackMs: Int64,
         onPlay: @escaping (TranscriptTurn) -> Void, onStop: @escaping () -> Void,
         onChoose: @escaping (TranscriptTurn) -> Void) {
        self.pieces = pieces
        self.initialPlaybackMs = initialPlaybackMs
        self.onPlay = onPlay
        self.onStop = onStop
        self.onChoose = onChoose
        let available = Self.available(pieces)
        let index = available.firstIndex {
            initialPlaybackMs >= $0.playbackStartMs && initialPlaybackMs < $0.playbackEndMs
        } ?? (available.last?.playbackEndMs == initialPlaybackMs ? max(0, available.count - 1) : 0)
        let piece = available.indices.contains(index) ? available[index] : nil
        let length = piece.map { Double($0.sourceEndMs - $0.sourceStartMs) / 1_000 } ?? 0
        // Open on a full default-length clip at the playhead; a playhead outside the section
        // (or at the very end of the audio) starts from the section's beginning instead.
        let inPiece = piece.map { initialPlaybackMs >= $0.playbackStartMs && initialPlaybackMs < $0.playbackEndMs } ?? false
        let offset = inPiece ? piece.map { Double(initialPlaybackMs - $0.playbackStartMs) / 1_000 } ?? 0 : 0
        let fits = min(10, length)
        let start = max(0, min(offset, length - fits))
        _selectedIndex = State(initialValue: index)
        _startSeconds = State(initialValue: start)
        _durationSeconds = State(initialValue: fits)
    }

    private static func available(_ pieces: [ConversationAudioPiece]) -> [ConversationAudioPiece] {
        pieces.filter { !$0.segmentId.isEmpty && $0.sourceStartMs >= 0
            && $0.sourceEndMs > $0.sourceStartMs && $0.playbackStartMs >= 0 }
    }
    private var available: [ConversationAudioPiece] { Self.available(pieces) }
    private var piece: ConversationAudioPiece? {
        available.indices.contains(selectedIndex) ? available[selectedIndex] : nil
    }
    private var lengthSeconds: Double {
        piece.map { Double($0.sourceEndMs - $0.sourceStartMs) / 1_000 } ?? 0
    }
    private var maximumStart: Double { max(0, lengthSeconds - min(1, lengthSeconds)) }
    private var maximumDuration: Double { min(30, max(0, lengthSeconds - startSeconds)) }
    private var minimumDuration: Double { min(1, maximumDuration) }
    private var clip: TranscriptTurn? {
        guard let piece else { return nil }
        return Self.makeTurn(piece: piece, startOffsetMs: Int64((startSeconds * 1_000).rounded()),
                             durationMs: Int64((durationSeconds * 1_000).rounded()))
    }

    /// Reuses the same source/playback mapping as the conversation, with UI limits applied.
    static func makeTurn(piece: ConversationAudioPiece, startOffsetMs: Int64,
                         durationMs: Int64) -> TranscriptTurn? {
        guard piece.sourceStartMs >= 0, piece.sourceEndMs > piece.sourceStartMs else { return nil }
        let length = piece.sourceEndMs - piece.sourceStartMs
        let minimum = min(1_000, length)
        let offset = min(max(0, startOffsetMs), length - minimum)
        return piece.clip(atPlaybackMs: piece.playbackStartMs + offset,
                          durationMs: min(max(minimum, durationMs), 30_000, length - offset))
    }

    var body: some View {
        NavigationStack {
            SettingsScroll {
                Text("Choose a short clip with one person speaking. Listen to it, then give the voice a name.")
                    .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                if piece != nil {
                    if available.count > 1 {
                        // A Menu rather than an inline Picker: the picker's one-line label clips at
                        // accessibility text sizes, while this label wraps like the rows below it.
                        Card {
                            Menu {
                                Picker("Recording section", selection: $selectedIndex) {
                                    ForEach(Array(available.enumerated()), id: \.offset) { index, section in
                                        Text("Section \(index + 1) · \(sectionTimes(section))").tag(index)
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Section \(selectedIndex + 1) of \(available.count)")
                                            .font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                                        Text(piece.map(sectionTimes) ?? "")
                                            .font(AppFont.callout.monospacedDigit()).foregroundStyle(Tokens.secondaryBody)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(AppFont.callout).foregroundStyle(Tokens.tint)
                                }.contentShape(Rectangle())
                            }.accessibilityLabel("Recording section")
                                .accessibilityValue("Section \(selectedIndex + 1), \(piece.map(sectionTimes) ?? "")")
                        }
                    }
                    SettingsSectionHeader(title: "Audio clip")
                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            Stepper(value: startBinding, in: 0...maximumStart, step: 1) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Starts at").font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                                    Text(TimeFmt.timecode(clip?.mediaOffsetMs ?? 0))
                                        .font(AppFont.callout.monospacedDigit()).foregroundStyle(Tokens.secondaryBody)
                                }
                            }.accessibilityLabel("Clip start")
                                .accessibilityValue(TimeFmt.timecode(clip?.mediaOffsetMs ?? 0))
                                .disabled(maximumStart == 0)
                            if maximumStart > 0 {
                                Slider(value: startBinding, in: 0...maximumStart, step: 1)
                                    .tint(Tokens.tint).accessibilityLabel("Clip start")
                                    .accessibilityValue(TimeFmt.timecode(clip?.mediaOffsetMs ?? 0))
                            }
                            Stepper(value: durationBinding, in: minimumDuration...maximumDuration, step: 1) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Length").font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                                    Text(durationSeconds.formatted(.number.precision(.fractionLength(0...1))) + " sec")
                                        .font(AppFont.callout.monospacedDigit()).foregroundStyle(Tokens.secondaryBody)
                                }
                            }.accessibilityLabel("Clip length")
                                .accessibilityValue("\(durationSeconds.formatted(.number.precision(.fractionLength(0...1)))) seconds")
                                .disabled(maximumDuration <= minimumDuration)
                            Button {
                                if let clip { onStop(); onPlay(clip) }
                            } label: {
                                Label("Listen to this clip", systemImage: "play.fill")
                            }.buttonStyle(.borderedTint).disabled(clip == nil)
                        }
                    }
                    SettingsFooter(text: "To remember a voice for other recordings, choose 2–30 seconds of clear speech. You can make that choice after naming the clip.")
                } else {
                    VoiceMessageCard(text: "There is no saved audio available to select in this conversation.")
                }
            }
            .navigationTitle("Identify a voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.cancel) { onStop(); dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Choose speaker") {
                    guard let clip else { return }
                    onStop()
                    onChoose(clip)
                }.buttonStyle(.primaryFilled).disabled(clip == nil)
                    .padding(16).background(Tokens.ground)
            }
        }
        .tint(Tokens.tint)
        .onChange(of: selectedIndex) { _, _ in resetSelection() }
        .onChange(of: pieces) { _, _ in
            selectedIndex = min(selectedIndex, max(0, available.count - 1))
            resetSelection()
        }
        .onDisappear(perform: onStop)
    }

    private var startBinding: Binding<Double> {
        Binding(get: { min(startSeconds, maximumStart) }, set: { value in
            onStop()
            startSeconds = min(max(0, value), maximumStart)
            durationSeconds = min(max(minimumDuration, durationSeconds), maximumDuration)
        })
    }
    private var durationBinding: Binding<Double> {
        Binding(get: { min(max(minimumDuration, durationSeconds), maximumDuration) }, set: { value in
            onStop()
            durationSeconds = min(max(minimumDuration, value), maximumDuration)
        })
    }
    private func sectionTimes(_ section: ConversationAudioPiece) -> String {
        "\(TimeFmt.timecode(section.playbackStartMs))–\(TimeFmt.timecode(section.playbackEndMs))"
    }
    private func resetSelection() {
        onStop()
        startSeconds = 0
        durationSeconds = min(10, lengthSeconds)
    }
}
