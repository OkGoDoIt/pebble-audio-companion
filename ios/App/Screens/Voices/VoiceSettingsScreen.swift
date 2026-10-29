import AppDB
import SwiftUI

struct VoiceSettingsScreen: View {
    @State private var model: VoiceSettingsModel
    @State private var setup = false
    @State private var undoRun: VoiceRunDisplay?
    @State private var clearing = false
    @State private var asking: UnknownVoiceDisplay?

    init(model: VoiceSettingsModel = .init()) { _model = State(initialValue: model) }

    var body: some View {
        SettingsScroll {
            Text(Copy.Voices.introduction)
                .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                .padding(.vertical, 8)
            ListCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Copy.Voices.recognize).font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                        Text(model.display.statusLine)
                            .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                    }
                    Spacer(minLength: 0)
                    Toggle(Copy.Voices.recognize, isOn: Binding(
                        get: { model.display.enabled },
                        set: { value in Task { _ = await model.enable(value) } }))
                        .labelsHidden().tint(Tokens.tint).disabled(model.working || !model.loaded)
                }
                Label(Copy.Voices.local, systemImage: "iphone")
                    .font(AppFont.footnote).foregroundStyle(Tokens.meta)
            }
            if let progress = model.downloadProgress { VoiceDownloadCard(progress: progress) }
            if let error = model.errorMessage { VoiceMessageCard(text: error) }
            if !model.loaded {
                Button(Copy.Speaker.retry) { Task { await model.refresh() } }.buttonStyle(.borderedTint)
            }

            SettingsSectionHeader(title: Copy.Voices.yourVoice)
            if let me = model.display.people.first(where: { $0.person.isCurrentUser }) {
                ListCard {
                    NavigationLink {
                        VoiceProfileScreen(personId: me.id, model: model)
                    } label: { VoicePersonRow(profile: me) }
                    .buttonStyle(.plain)
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            VoiceAvatar(name: "", isCurrentUser: true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Copy.Voices.setUp).font(AppFont.headline).foregroundStyle(Tokens.label)
                                Text(Copy.Voices.setUpDetail).font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                            }
                        }
                        Button(Copy.Voices.setUp) { setup = true }.buttonStyle(.inCardFilled)
                            .disabled(model.working)
                    }
                }
            }

            if !model.unknownVoices.isEmpty {
                SettingsSectionHeader(title: "Voices to name")
                ListCard {
                    ForEach(model.unknownVoices) { voice in
                        Button { asking = voice } label: {
                            HStack(spacing: 12) {
                                VoiceAvatar(name: "?", isUnknown: true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Heard in \(voice.recordingCount) recordings")
                                        .font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                                    if !voice.detail.isEmpty {
                                        Text(voice.detail).font(AppFont.footnote).foregroundStyle(Tokens.meta)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Tokens.chevron).accessibilityHidden(true)
                            }.frame(minHeight: 56).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Don’t Ask About This Voice", systemImage: "nosign") {
                                Task { await model.stopAsking(about: voice) }
                            }
                        }
                    }
                }
                SettingsFooter(text: "Naming a voice names it in every recording it was heard in.")
            }

            let others = model.display.people.filter { !$0.person.isCurrentUser }
            if !others.isEmpty {
                SettingsSectionHeader(title: Copy.Voices.people)
                ListCard {
                    ForEach(others) { person in
                        NavigationLink {
                            VoiceProfileScreen(personId: person.id, model: model)
                        } label: { VoicePersonRow(profile: person) }.buttonStyle(.plain)
                    }
                }
            }
            SettingsFooter(text: Copy.Voices.noPeopleDetail)

            if !model.display.people.isEmpty {
                SettingsSectionHeader(title: Copy.Voices.history)
                SettingsFooter(text: Copy.Voices.historyDetail)
                if let run = model.display.run {
                    VoiceRunCard(run: run, heading: model.display.runHeading, waiting: model.display.waiting != nil,
                                 onStop: { Task { await model.cancel(run) } }, onUndo: { undoRun = run })
                }
                if model.display.run?.isRunning != true {
                    ListCard {
                        TintActionRow(title: Copy.Voices.lastWeek) {
                            Task { await model.recognizeHistory(days: 7) }
                        }
                        TintActionRow(title: Copy.Voices.allRecordings) {
                            Task { await model.recognizeHistory(days: nil) }
                        }
                    }.disabled(!model.display.enabled || model.working)
                }
            }
            if !model.display.people.isEmpty {
                Button(Copy.Voices.clearAutomatic, role: .destructive) { clearing = true }
                    .font(AppFont.callout).frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.working)
            }
            if let notice = model.display.notice { SettingsFooter(text: notice) }
        }
        .navigationTitle(Copy.Voices.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await model.observe() }
        .sheet(item: $asking, onDismiss: { Task { await model.refresh() } }) { voice in
            WhoIsThisSheet(voice: voice) { line in UndoCenter.shared.snackbar = SnackbarItem(message: line) }
        }
        .sheet(isPresented: $setup, onDismiss: { Task { await model.refresh() } }) {
            VoiceSetupScreen(person: model.display.currentUser)
        }
        .confirmationDialog(Copy.Voices.clearAutomatic, isPresented: $clearing, titleVisibility: .visible) {
            Button(Copy.Voices.clearAutomatic, role: .destructive) { Task { await model.clearAutomaticNames() } }
        } message: { Text(Copy.Voices.clearAutomaticDetail) }
        .confirmationDialog(Copy.Voices.undo, isPresented: Binding(
            get: { undoRun != nil }, set: { if !$0 { undoRun = nil } }),
            titleVisibility: .visible, presenting: undoRun) { run in
                Button(Copy.Voices.undo, role: .destructive) { Task { await model.undo(run) } }
            } message: { _ in Text(Copy.Voices.undoDetail) }
    }
}

/// A history run: what it is doing, how far through it is, and the one action that fits.
struct VoiceRunCard: View {
    let run: VoiceRunDisplay
    /// What a run with work left is doing now: finding voices, or waiting for a charger.
    let heading: String
    let waiting: Bool
    let onStop: () -> Void
    let onUndo: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(run.isRunning ? heading : (run.stopped ? "Voice matching stopped" : "Voice matching finished"))
                        .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                    Spacer()
                    if run.isRunning, !waiting { ProgressView() }
                }
                if run.isRunning, let fraction = run.fraction {
                    ProgressView(value: fraction).tint(Tokens.tint)
                }
                Text(run.detail)
                    .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                if run.failed > 0 {
                    Text(run.failed == 1 ? "1 recording couldn’t be checked. Run another pass to try again."
                         : "\(run.failed) recordings couldn’t be checked. Run another pass to try again.")
                        .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                }
                if run.isRunning {
                    Button(Copy.Voices.cancelRun, action: onStop).buttonStyle(.borderedTint)
                } else if run.canUndo {
                    Button(Copy.Voices.undo, action: onUndo).buttonStyle(.borderedTint)
                }
            }
        }
    }
}

struct VoiceProfileScreen: View {
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
                HStack(spacing: 12) {
                    VoiceAvatar(name: profile.person.name, isCurrentUser: profile.person.isCurrentUser)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.person.isCurrentUser ? Copy.Speaker.you : profile.person.name)
                            .font(AppFont.detailTitle).foregroundStyle(Tokens.label)
                        Text("\(profile.examples.count) confirmed samples")
                            .font(AppFont.subBody).foregroundStyle(Tokens.meta)
                    }
                }.padding(.vertical, 12)
                if !profile.ready { VoiceMessageCard(text: Copy.Voices.needsAnother) }
                SettingsFooter(text: Copy.Voices.sampleDetail)
                SettingsSectionHeader(title: Copy.Voices.samples)
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
        .navigationTitle(profile?.person.name ?? Copy.Voices.title)
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
                Button { if player.playing == clip.id { player.stop() } else { player.toggle(clip) } } label: {
                    Image(systemName: player.playing == clip.id ? "stop.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.onTint)
                        .frame(width: 36, height: 36).background(Circle().fill(Tokens.tint))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.playing == clip.id ? "Stop" : "Play sample")
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

struct VoiceAvatar: View {
    let name: String
    var isCurrentUser = false
    /// A voice with no name yet: grey, so it doesn't read as a person.
    var isUnknown = false
    var body: some View {
        Group {
            if isCurrentUser { Image(systemName: "person.wave.2.fill").font(.system(size: 19)) }
            else { Text(String(name.prefix(1)).uppercased()).font(AppFont.headline) }
        }
        .foregroundStyle(isUnknown ? Tokens.meta : Tokens.tint).frame(width: 44, height: 44)
        .background(Circle().fill(isUnknown ? Tokens.grayChipFill : Tokens.tintFill12)).accessibilityHidden(true)
    }
}

private struct VoicePersonRow: View {
    let profile: VoicePersonDisplay
    var body: some View {
        HStack(spacing: 12) {
            VoiceAvatar(name: profile.person.name, isCurrentUser: profile.person.isCurrentUser)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.person.isCurrentUser ? Copy.Speaker.you : profile.person.name)
                    .font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                Text(profile.ready ? "\(profile.examples.count) voice samples" : "Needs another sample")
                    .font(AppFont.footnote).foregroundStyle(Tokens.meta)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.chevron)
        }.contentShape(Rectangle())
    }
}

struct VoiceMessageCard: View {
    let text: String
    var body: some View {
        Card {
            Label(text, systemImage: "info.circle")
                .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VoiceDownloadCard: View {
    let progress: Double
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(Copy.Voices.preparing).font(AppFont.cardHead).foregroundStyle(Tokens.label)
                ProgressView(value: progress).tint(Tokens.tint)
                Text(Copy.Voices.downloadDetail).font(AppFont.footnote).foregroundStyle(Tokens.meta)
            }
        }
    }
}
