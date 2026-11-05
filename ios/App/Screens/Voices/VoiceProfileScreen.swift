import AppDB
import SwiftUI

/// One person: how much they've been heard, what might be them, where they were found, and the
/// samples confirmed by hand.
struct VoiceProfileScreen: View {
    let personId: String
    let model: VoiceSettingsModel
    @State private var appearances: [VoiceAppearanceDisplay] = []
    @State private var possible: [UnknownVoiceDisplay] = []
    @State private var reviewing: UnknownVoiceDisplay?
    @State private var player = WhoIsThisModel()
    @State private var editor = SpeakerEditorModel()
    @State private var renaming = false
    @State private var renameDraft = ""
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router: AppRouter?
    private var profile: VoicePersonDisplay? { model.display.people.first { $0.id == personId } }

    var body: some View {
        SettingsScroll {
            if let profile {
                HStack(spacing: 10) {
                    VoiceAvatar(name: profile.person.name, isCurrentUser: profile.person.isCurrentUser,
                                colorIndex: profile.colorIndex, size: 30)
                    Text(profile.name).font(AppFont.detailTitle).foregroundStyle(Tokens.label)
                }
                HStack(spacing: 8) {
                    stat(profile.conversations.formatted(), profile.conversations == 1 ? "conversation" : "conversations")
                    stat(VoiceDuration.text(profile.speechMs, compact: true), "of speech")
                    stat(profile.lastHeard.map(Self.day) ?? "—", "last heard")
                }
                if let error = model.errorMessage ?? player.errorMessage ?? editor.errorMessage { VoiceMessageCard(text: error) }
                if !possible.isEmpty {
                    SettingsSectionHeader(title: Copy.Voices.possibleMatches)
                    ListCard(rowVerticalPadding: 9, rowHorizontalPadding: 14) {
                        ForEach(possible) { voice in possibleRow(voice, name: profile.name) }
                    }
                }
                if !appearances.isEmpty {
                    SettingsSectionHeader(title: Copy.Voices.foundAutomatically)
                    ListCard(rowVerticalPadding: 9, rowHorizontalPadding: 14) {
                        ForEach(appearances.prefix(3)) { appearance in
                            VoiceAppearanceRow(appearance: appearance, personName: profile.name, player: player,
                                               onOpen: { open(appearance) },
                                               onNotThem: { Task { await notThem(appearance) } })
                        }
                        if appearances.count > 3 {
                            NavigationLink {
                                VoiceAppearancesScreen(personId: personId, personName: profile.name,
                                                       appearances: appearances, model: model)
                            } label: {
                                Text(Copy.Voices.seeAll).font(AppFont.callout).foregroundStyle(Tokens.tint)
                                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                ListCard {
                    NavigationLink { VoiceSamplesScreen(personId: personId, model: model) } label: {
                        HStack(spacing: 8) {
                            Text(Copy.Voices.confirmedSamples).font(AppFont.bodyPlain).foregroundStyle(Tokens.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(profile.examples.count)").font(AppFont.subBody).foregroundStyle(Tokens.meta)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Tokens.chevron).accessibilityHidden(true)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            } else {
                VoiceMessageCard(text: Copy.Voices.emptyProfile)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let profile {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(Copy.Speaker.rename, systemImage: "pencil") {
                            renameDraft = profile.person.name
                            renaming = true
                        }
                        if !profile.person.isCurrentUser {
                            Button(Copy.Speaker.thisIsMe, systemImage: "person.fill.checkmark") {
                                Task { _ = await editor.makeMe(profile.person); await model.refresh() }
                            }
                        }
                        Divider()
                        Button(Copy.Speaker.deletePerson, systemImage: "trash", role: .destructive) { deleting = true }
                    } label: {
                        Label("More for \(profile.name)", systemImage: "ellipsis")
                    }
                }
            }
        }
        .task(id: "\(personId):\(model.toReview.map(\.id).joined())") { await load() }
        .onDisappear { player.stop() }
        .fullScreenCover(item: $reviewing, onDismiss: { Task { await model.refresh(); await load() } }) { voice in
            VoiceReviewScreen(voice: voice) { UndoCenter.shared.snackbar = $0 }
        }
        .alert(Copy.Speaker.renamePerson, isPresented: $renaming) {
            TextField(Copy.Speaker.namePlaceholder, text: $renameDraft)
            Button(Copy.Common.cancel, role: .cancel) {}
            Button(Copy.Common.save) {
                guard let profile else { return }
                Task { _ = await editor.rename(profile.person, to: renameDraft); await model.refresh() }
            }
        } message: { Text(Copy.Speaker.renamePersonMessage) }
        .confirmationDialog(Copy.Speaker.deletePersonTitle(profile?.person.name ?? ""), isPresented: $deleting,
                            titleVisibility: .visible) {
            Button(Copy.Speaker.deletePerson, role: .destructive) {
                guard let profile else { return }
                Task {
                    if await editor.delete(profile.person) { await model.refresh(); dismiss() }
                }
            }
        } message: { Text(Copy.Speaker.deletePersonMessage) }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(.title3, weight: .bold)).foregroundStyle(Tokens.label)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(AppFont.footnote).foregroundStyle(Tokens.meta).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .accessibilityElement(children: .combine)
    }

    private func possibleRow(_ voice: UnknownVoiceDisplay, name: String) -> some View {
        HStack(spacing: 10) {
            if let lead = voice.lead { VoicePlayButton(clip: lead, player: player) }
            VStack(alignment: .leading, spacing: 3) {
                Text(voice.recordingCount == 1 ? (voice.lead?.heardAt.map(WhoIsThisSheet.when) ?? "Earlier")
                     : "\(voice.recordingCount) conversations")
                    .font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                if let quote = voice.lead?.quote {
                    Text(quote).font(AppFont.footnote).foregroundStyle(Tokens.meta).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { player.stop(); reviewing = voice }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Copy.Voices.listenToAll)
            Button { Task { await answer(voice, yes: false) } } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Tokens.secondaryBody)
                    .frame(width: 44, height: 44).background(Circle().fill(Tokens.grayChipFill))
            }.buttonStyle(.plain).accessibilityLabel(Copy.Voices.notThem(name))
            Button { Task { await answer(voice, yes: true) } } label: {
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Tokens.onTint)
                    .frame(width: 44, height: 44).background(Circle().fill(Tokens.tint))
            }.buttonStyle(.plain).accessibilityLabel(Copy.Voices.thats(name))
        }
    }

    private func load() async {
        appearances = await model.appearances(personId: personId)
        var loaded: [UnknownVoiceDisplay] = []
        for voice in model.toReview.filter({ $0.suggestion?.person.id == personId }).prefix(8) {
            loaded.append(await model.detail(voice) ?? voice)
        }
        possible = loaded
    }

    private func answer(_ voice: UnknownVoiceDisplay, yes: Bool) async {
        player.stop()
        guard let suggestion = voice.suggestion else { return }
        if yes { await model.confirm(voice, as: suggestion) } else { _ = await model.someoneElse(voice, instead: suggestion) }
        await load()
    }

    private func notThem(_ appearance: VoiceAppearanceDisplay) async {
        player.stop()
        await model.notThisPerson(appearance, personId: personId)
        await load()
    }

    private func open(_ appearance: VoiceAppearanceDisplay) {
        player.stop()
        router?.navigate(to: .conversation(id: appearance.conversationId, atMs: nil, focus: nil))
    }

    /// "Today", "Tuesday", "Oct 12".
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 99
        return days < 7 ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A conversation someone was recognized in. Long press says it wasn't them.
struct VoiceAppearanceRow: View {
    let appearance: VoiceAppearanceDisplay
    let personName: String
    let player: WhoIsThisModel
    let onOpen: () -> Void
    let onNotThem: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VoicePlayButton(clip: appearance.clip, player: player)
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appearance.title).font(AppFont.rowTitle).foregroundStyle(Tokens.label).lineLimit(1)
                        Text("\(VoiceProfileScreen.day(appearance.heardAt)) · \(VoiceDuration.text(appearance.speechMs)) of \(personName == Copy.Speaker.you ? "you" : personName)")
                            .font(AppFont.footnote).foregroundStyle(Tokens.meta).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.chevron).accessibilityHidden(true)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .contextMenu {
            Button(Copy.Voices.notThem(personName == Copy.Speaker.you ? "you" : personName), systemImage: "person.fill.xmark",
                   role: .destructive, action: onNotThem)
        }
        .accessibilityAction(named: Copy.Voices.notThem(personName == Copy.Speaker.you ? "you" : personName), onNotThem)
    }
}

/// Every conversation someone was recognized in.
struct VoiceAppearancesScreen: View {
    let personId: String
    let personName: String
    @State var appearances: [VoiceAppearanceDisplay]
    let model: VoiceSettingsModel
    @State private var player = WhoIsThisModel()
    @Environment(AppRouter.self) private var router: AppRouter?

    var body: some View {
        SettingsScroll {
            LazyVStack(spacing: 0) {
                ForEach(appearances) { appearance in
                    VoiceAppearanceRow(appearance: appearance, personName: personName, player: player,
                        onOpen: {
                            player.stop()
                            router?.navigate(to: .conversation(id: appearance.conversationId, atMs: nil, focus: nil))
                        },
                        onNotThem: {
                            player.stop()
                            Task {
                                await model.notThisPerson(appearance, personId: personId)
                                appearances = await model.appearances(personId: personId)
                            }
                        })
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .overlay(alignment: .bottom) {
                        if appearance.id != appearances.last?.id {
                            Rectangle().fill(Tokens.hairline).frame(height: 0.5).padding(.horizontal, 16)
                        }
                    }
                }
            }
            .background(Tokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        }
        .navigationTitle(personName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }
}

/// The samples confirmed by hand: setup recordings and clips a person named.
struct VoiceSamplesScreen: View {
    let personId: String
    let model: VoiceSettingsModel
    @State private var adding = false
    @State private var forgetting = false
    @State private var deletingExample: VoiceExampleDisplay?
    @State private var player = WhoIsThisModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router: AppRouter?
    private var profile: VoicePersonDisplay? { model.display.people.first { $0.id == personId } }

    var body: some View {
        SettingsScroll {
            if let profile {
                SettingsFooter(text: Copy.Voices.sampleDetail)
                ListCard {
                    ForEach(profile.examples) { example in sampleRow(example) }
                    TintActionRow(title: Copy.Voices.addSample) { adding = true }
                }.disabled(model.working)
                if let error = model.errorMessage ?? player.errorMessage { VoiceMessageCard(text: error) }
                Button(Copy.Voices.forget, role: .destructive) { forgetting = true }
                    .font(AppFont.callout).padding(.top, 12).frame(maxWidth: .infinity, minHeight: 44)
                SettingsFooter(text: Copy.Voices.forgetDetail)
            } else {
                VoiceMessageCard(text: Copy.Voices.emptyProfile)
            }
        }
        .navigationTitle(Copy.Voices.confirmedSamples)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
        .sheet(isPresented: $adding, onDismiss: { Task { await model.refresh() } }) {
            if let profile { VoiceSetupScreen(person: profile.person) }
        }
        .confirmationDialog(Copy.Voices.forget, isPresented: $forgetting, titleVisibility: .visible) {
            Button(Copy.Voices.forget, role: .destructive) {
                guard let profile else { return }
                Task { await model.forget(profile); if model.errorMessage == nil { dismiss() } }
            }
        } message: { Text(Copy.Voices.forgetDetail) }
        .confirmationDialog(Copy.Voices.removeSample, isPresented: Binding(
            get: { deletingExample != nil }, set: { if !$0 { deletingExample = nil } }),
            titleVisibility: .visible, presenting: deletingExample) { example in
                Button(Copy.Voices.removeSample, role: .destructive) { Task { await model.remove(example) } }
            } message: { _ in
                Text("Removes this sample and automatic matches for this voice. Names you chose yourself stay.")
            }
    }

    /// A sample from a conversation reads like where it was heard: when, what was said, a play
    /// button, and the way back to it. A setup sample keeps its situation and length.
    private func sampleRow(_ example: VoiceExampleDisplay) -> some View {
        HStack(spacing: 12) {
            if let clip = example.clip {
                VoicePlayButton(clip: clip, player: player, size: 36)
            } else {
                // Setup samples keep no audio: the microphone it came through, in the play slot.
                Image(systemName: example.microphone == .phone ? "iphone" : "applewatch")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(Tokens.tint)
                    .frame(width: 36, height: 36).background(Circle().fill(Tokens.tintFill12))
                    .frame(width: 44, height: 44).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(example.clip?.heardAt.map(WhoIsThisSheet.when) ?? example.source)
                    .font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                Text(example.clip?.quote ?? "\(Int(example.durationSeconds)) sec · \(example.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(AppFont.footnote).foregroundStyle(Tokens.meta).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            Menu {
                if let clip = example.clip {
                    Button(player.playing == clip.id && player.playingLonger ? "Stop" : "Play Longer",
                           systemImage: "waveform") { player.toggle(clip, longer: true) }
                    if clip.heardAt != nil {
                        Button("Open Conversation", systemImage: "text.bubble") { open(clip) }
                    }
                    Divider()
                }
                Button("Remove Sample", systemImage: "trash", role: .destructive) { deletingExample = example }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(Tokens.tint)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("More for this sample")
        }
    }

    private func open(_ clip: UnknownVoiceClip) {
        player.stop()
        Task {
            guard let route = await UnknownVoiceClip.route(clip) else { player.couldNotOpen(); return }
            router?.navigate(to: route)
        }
    }
}
