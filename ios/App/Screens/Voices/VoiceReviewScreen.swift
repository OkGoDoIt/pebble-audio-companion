import AppDB
import SwiftUI

/// "Is this Dana?", with every conversation the voice was heard in to listen through. Checked is
/// them, unchecked isn't: one answer covers the lot.
struct VoiceReviewScreen: View {
    let voice: UnknownVoiceDisplay
    let onAnswered: (SnackbarItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = WhoIsThisModel()
    @State private var full: UnknownVoiceDisplay?
    @State private var kept: Set<String>
    @State private var splitting = false

    init(voice: UnknownVoiceDisplay, onAnswered: @escaping (SnackbarItem) -> Void) {
        self.voice = voice
        self.onAnswered = onAnswered
        _kept = State(initialValue: Set(voice.clips.map(\.id)))
    }

    private var shown: UnknownVoiceDisplay { full ?? voice }

    var body: some View {
        NavigationStack {
            SettingsScroll {
                if let suggestion = shown.suggestion {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            VoiceAvatar(name: suggestion.person.name, isCurrentUser: suggestion.person.isCurrentUser,
                                        colorIndex: suggestion.colorIndex, size: 32)
                            Text(Copy.Voices.isThis(suggestion.name)).font(AppFont.screenTitle).foregroundStyle(Tokens.label)
                        }
                        Text(Copy.Voices.uncheckAny).font(AppFont.subBody).foregroundStyle(Tokens.meta)
                    }.padding(.bottom, 4)
                }
                ListCard(rowVerticalPadding: 10, rowHorizontalPadding: 14) {
                    ForEach(shown.clips) { clip in
                        VoiceClipRow(clip: clip, player: model, checked: kept.contains(clip.id)) {
                            if kept.contains(clip.id) { kept.remove(clip.id) } else { kept.insert(clip.id) }
                        }
                    }
                }
                if let error = model.errorMessage { VoiceMessageCard(text: error) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Voices.notNow) { model.stop(); dismiss() }.disabled(model.working)
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationDestination(isPresented: $splitting) {
                VoiceSplitScreen(voice: shown) { notice in onAnswered(notice); dismiss() }
            }
        }
        .tint(Tokens.tint)
        .task {
            await model.load()
            if let detail = await model.detail(of: voice.id) {
                full = detail
                // Any recording the first look didn't have starts checked too.
                kept.formUnion(Set(detail.clips.map(\.id)).subtracting(voice.clips.map(\.id)))
            }
        }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var actions: some View {
        if let suggestion = shown.suggestion {
            VStack(spacing: 6) {
                Button {
                    Task {
                        let all = kept.count == Set(shown.clips.map(\.id)).count
                        guard let notice = await model.confirm(shown, as: suggestion, clips: all ? nil : kept) else { return }
                        onAnswered(notice)
                        dismiss()
                    }
                } label: {
                    HStack {
                        if model.working { ProgressView().tint(Tokens.onTint) }
                        Text(Copy.Voices.confirm(kept.count, for: suggestion.name))
                    }
                }
                .buttonStyle(.primaryFilled).disabled(kept.isEmpty || model.working)
                Button(Copy.Voices.moreThanOne) { model.stop(); splitting = true }
                    .font(AppFont.callout.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44).disabled(model.working)
                Button(Copy.Voices.noneOfThese(suggestion.name)) {
                    Task {
                        guard await model.reject(shown, as: suggestion) else { return }
                        dismiss()
                    }
                }
                .font(AppFont.callout.weight(.semibold)).foregroundStyle(Tokens.tint)
                .frame(maxWidth: .infinity, minHeight: 44).disabled(model.working)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8).background(Tokens.ground)
        }
    }
}

/// "Is this you?": the first question, about the voice heard most.
struct VoiceFirstAskScreen: View {
    let voice: UnknownVoiceDisplay
    let currentUser: Person?
    let onAnswered: (SnackbarItem) -> Void
    let onSomeoneElse: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = WhoIsThisModel()
    @State private var full: UnknownVoiceDisplay?
    @State private var askingName = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            SettingsScroll {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Copy.Voices.isThisYou).font(AppFont.screenTitle).foregroundStyle(Tokens.label)
                    Text(Copy.Voices.mostOfYourConversationsLine).font(AppFont.callout).foregroundStyle(Tokens.secondaryBody)
                }.padding(.vertical, 6)
                ListCard(rowVerticalPadding: 10, rowHorizontalPadding: 14) {
                    ForEach((full ?? voice).clips.prefix(3)) { clip in VoiceClipRow(clip: clip, player: model) }
                }
                if let error = model.errorMessage { VoiceMessageCard(text: error) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Voices.notNow) { model.stop(); dismiss() }.disabled(model.working)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(Copy.Voices.thatsMe) {
                        if let currentUser { name = currentUser.name; save() } else { askingName = true }
                    }.buttonStyle(.primaryFilled).disabled(model.working)
                    Button(Copy.Voices.itsSomeoneElse) {
                        model.stop()
                        dismiss()
                        onSomeoneElse()
                    }.buttonStyle(.borderedTint).disabled(model.working)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8).background(Tokens.ground)
            }
        }
        .tint(Tokens.tint)
        .task {
            await model.load()
            full = await model.detail(of: voice.id)
        }
        .onDisappear { model.stop() }
        .alert(Copy.Voices.yourName, isPresented: $askingName) {
            TextField(Copy.Voices.yourName, text: $name).textContentType(.name)
            Button(Copy.Common.cancel, role: .cancel) {}
            Button(Copy.Common.save) { save() }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            guard await model.nameAsMe(voice, displayName: trimmed) != nil else { return }
            onAnswered(SnackbarItem(message: Copy.Voices.named("you", in: voice.recordingCount)))
            dismiss()
        }
    }
}

/// One moment of a voice: play it, read what was said. Tap the words for more of the audio around
/// it; long press to open the conversation.
struct VoiceClipRow: View {
    let clip: UnknownVoiceClip
    let player: WhoIsThisModel
    /// With a checkbox, tapping it says whether this one is them.
    var checked: Bool? = nil
    var onToggle: (() -> Void)? = nil
    var onIgnore: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            VoicePlayButton(clip: clip, player: player, size: 44)
            Button { player.toggle(clip, longer: true) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.heardAt.map(WhoIsThisSheet.when) ?? "Earlier").font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                    if let quote = clip.quote {
                        Text(quote).font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Copy.Voices.playLonger)
            if let checked {
                Button { onToggle?() } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 26)).foregroundStyle(checked ? Tokens.tint : Tokens.chevron)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clip.heardAt.map(WhoIsThisSheet.when) ?? "Earlier")
                .accessibilityValue(checked ? "Checked" : "Not checked")
            }
        }
        .contextMenu {
            Button(Copy.Voices.playLonger, systemImage: "waveform") { player.toggle(clip, longer: true) }
            if let onOpen { Button("Open Conversation", systemImage: "text.bubble", action: onOpen) }
            if let onIgnore { Button("Ignore Clip", systemImage: "nosign", action: onIgnore) }
        }
    }
}
