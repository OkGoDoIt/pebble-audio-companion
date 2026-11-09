import AppDB
import SwiftUI

/// People & voices. In order: how much has a name, the one question worth answering next, who's
/// been found, and the voices still without a name. Recognition's own controls come last, except
/// while it's off, when they're all there is to do.
struct VoiceSettingsScreen: View {
    @State private var model: VoiceSettingsModel
    @State private var player = WhoIsThisModel()
    @State private var setup = false
    @State private var undoRun: VoiceRunDisplay?
    @State private var clearing = false
    /// The voice being named, or being listened through.
    @State private var asking: UnknownVoiceDisplay?
    @State private var reviewing: UnknownVoiceDisplay?
    @State private var askingFirst: UnknownVoiceDisplay?
    /// "Is this you?" set aside for now.
    @State private var firstAskSetAside = false

    init(model: VoiceSettingsModel = .init()) { _model = State(initialValue: model) }

    var body: some View {
        SettingsScroll {
            if !model.display.enabled { recognition }
            if let progress = model.downloadProgress { VoiceDownloadCard(progress: progress) }
            if let error = model.errorMessage ?? player.errorMessage { VoiceMessageCard(text: error) }
            if !model.loaded {
                Button(Copy.Speaker.retry) { Task { await model.refresh() } }.buttonStyle(.borderedTint)
            }
            if let coverage = model.display.coverage, model.display.enabled { VoiceCoverageCard(coverage: coverage) }
            toReview
            people
            if model.display.enabled, !model.toName.isEmpty {
                ListCard(rowVerticalPadding: 11) {
                    NavigationLink { VoicesToNameScreen(model: model) } label: {
                        HStack(spacing: 10) {
                            VoiceAvatar(name: "?", isUnknown: true, size: 24)
                            Text(Copy.Voices.toName).font(AppFont.bodyPlain).foregroundStyle(Tokens.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(model.toName.count)").font(AppFont.subBody).foregroundStyle(Tokens.meta)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Tokens.chevron).accessibilityHidden(true)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            if model.display.enabled { recognition }
            if let notice = model.display.notice { SettingsFooter(text: notice) }
        }
        .navigationTitle(Copy.Voices.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await model.observe() }
        .onDisappear { player.stop() }
        .sheet(item: $asking, onDismiss: { Task { await model.refresh() } }) { voice in
            WhoIsThisSheet(voice: voice) { UndoCenter.shared.snackbar = $0 }
        }
        .fullScreenCover(item: $reviewing, onDismiss: { Task { await model.refresh() } }) { voice in
            VoiceReviewScreen(voice: voice) { UndoCenter.shared.snackbar = $0 }
        }
        .fullScreenCover(item: $askingFirst, onDismiss: { Task { await model.refresh() } }) { voice in
            VoiceFirstAskScreen(voice: voice, currentUser: model.display.currentUser,
                                onAnswered: { UndoCenter.shared.snackbar = $0 },
                                onSomeoneElse: { firstAskSetAside = true; asking = voice })
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

    /// One question at a time; answering brings up the next.
    @ViewBuilder private var toReview: some View {
        if model.display.enabled {
            if let first = model.firstAsk, !firstAskSetAside {
                SettingsSectionHeader(title: Copy.Voices.toReview)
                VoiceReviewCard(voice: first, title: Copy.Voices.isThisYou, detail: Copy.Voices.mostOfYourConversations,
                                confirm: Copy.Voices.thatsMe, decline: Copy.Voices.someoneElse, player: player,
                                onOpen: { player.stop(); askingFirst = first },
                                onConfirm: { player.stop(); askingFirst = first },
                                onDecline: { player.stop(); firstAskSetAside = true; asking = first })
            } else if let lead = model.leadReview, let suggestion = lead.suggestion {
                SettingsSectionHeader(title: model.toReview.count > 1
                                      ? "\(Copy.Voices.toReview) · \(model.toReview.count)" : Copy.Voices.toReview)
                VoiceReviewCard(voice: lead, title: Copy.Voices.isThis(suggestion.name), detail: Self.heardDetail(lead),
                                confirm: Copy.Voices.thats(suggestion.name), decline: Copy.Voices.someoneElse,
                                confirmDisabled: model.working, player: player,
                                onOpen: { player.stop(); reviewing = lead },
                                onConfirm: {
                                    player.stop()
                                    Task { await model.confirm(lead, as: suggestion) }
                                },
                                onDecline: {
                                    player.stop()
                                    Task {
                                        // A plain "no" is an answer on its own; naming them is on offer after it.
                                        if await model.someoneElse(lead, instead: suggestion) {
                                            var unsuggested = lead
                                            unsuggested.suggestion = nil
                                            asking = unsuggested
                                        }
                                    }
                                })
            }
        }
    }

    /// "Tuesday, 4:40 PM · also in 3 more conversations"
    static func heardDetail(_ voice: UnknownVoiceDisplay) -> String {
        let when = voice.lead?.heardAt.map(WhoIsThisSheet.when) ?? "Earlier"
        let others = voice.recordingCount - 1
        guard others > 0 else { return when }
        return others == 1 ? "\(when) · also in 1 more conversation" : "\(when) · also in \(others) more conversations"
    }

    @ViewBuilder private var people: some View {
        if !model.display.people.isEmpty {
            SettingsSectionHeader(title: Copy.Voices.people)
            ListCard(rowVerticalPadding: 11) {
                ForEach(model.display.people) { person in
                    NavigationLink { VoiceProfileScreen(personId: person.id, model: model) } label: {
                        HStack(spacing: 10) {
                            VoiceAvatar(name: person.person.name, isCurrentUser: person.person.isCurrentUser,
                                        colorIndex: person.colorIndex, size: 24)
                            Text(person.name).font(AppFont.bodyPlain).foregroundStyle(Tokens.label).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if person.speechMs > 0 {
                                Text(VoiceDuration.text(person.speechMs)).font(AppFont.subBody).foregroundStyle(Tokens.meta)
                                    .monospacedDigit()
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    /// Whether it's on, what it's doing, and the rarely needed controls.
    @ViewBuilder private var recognition: some View {
        if !model.display.enabled {
            Text(Copy.Voices.introduction)
                .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                .padding(.vertical, 8)
        } else {
            SettingsSectionHeader(title: Copy.Voices.recognition)
        }
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
        if model.needsOwnVoice {
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
        if model.display.enabled {
            if let run = model.display.run {
                VoiceRunCard(run: run, heading: model.display.runHeading, waiting: model.display.waiting != nil,
                             onStop: { Task { await model.cancel(run) } }, onUndo: { undoRun = run })
            }
            if model.display.run?.isRunning != true {
                ListCard {
                    TintActionRow(title: Copy.Voices.allRecordings) {
                        Task { await model.recognizeHistory(days: nil) }
                    }
                }.disabled(model.working)
            }
            if !model.display.people.isEmpty {
                Button(Copy.Voices.clearAutomatic, role: .destructive) { clearing = true }
                    .font(AppFont.callout).frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.working)
            }
        }
    }
}

/// The share of everything said that has a name, and whose: readable at a glance by shape alone.
struct VoiceCoverageCard: View {
    let coverage: VoiceCoverageDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(coverage.percent)%").font(.system(.title, weight: .bold)).foregroundStyle(Tokens.label)
                    .monospacedDigit()
                Text(Copy.Voices.coverageLine).font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
            }
            GeometryReader { geometry in
                let gaps = CGFloat(max(0, visible.count)) * 2
                HStack(spacing: 2) {
                    ForEach(visible) { share in
                        Rectangle().fill(PersonPalette.fill(share.colorIndex))
                            .frame(width: max(3, (geometry.size.width - gaps) * share.fraction))
                    }
                    Rectangle().fill(Tokens.grayChipFill)
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
        }
        .padding(.vertical, 13).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(coverage.percent)% \(Copy.Voices.coverageLine)")
        .accessibilityValue(visible.map { "\($0.name) \(Int(($0.fraction * 100).rounded()))%" }.joined(separator: ", "))
    }

    /// Slivers too thin to see don't take a place in the bar.
    private var visible: [VoiceCoverageDisplay.Share] { coverage.shares.filter { $0.fraction >= 0.005 } }
}

/// The question at the top of People & voices. The buttons answer it for the whole voice; the card
/// itself opens every conversation it was heard in, to listen through first.
struct VoiceReviewCard: View {
    let voice: UnknownVoiceDisplay
    let title: String
    let detail: String
    let confirm: String
    let decline: String
    var confirmDisabled = false
    let player: WhoIsThisModel
    let onOpen: () -> Void
    let onConfirm: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let lead = voice.lead { VoicePlayButton(clip: lead, player: player, size: 44) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                    Text(detail).font(AppFont.footnote).foregroundStyle(Tokens.meta)
                    if let quote = voice.lead?.quote {
                        Text(quote).font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Copy.Voices.listenToAll)
            }
            HStack(spacing: 8) {
                Button(confirm, action: onConfirm).buttonStyle(.inCardFilled).disabled(confirmDisabled)
                Button(decline, action: onDecline).buttonStyle(.borderedTint).disabled(confirmDisabled)
            }
        }
        .padding(.top, 11).padding(.bottom, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
    }
}

/// The voices still without a name, most heard first.
struct VoicesToNameScreen: View {
    let model: VoiceSettingsModel
    @State private var asking: UnknownVoiceDisplay?

    var body: some View {
        SettingsScroll {
            if model.toName.isEmpty {
                VoiceMessageCard(text: Copy.Voices.noneToName)
            } else {
                ListCard {
                    ForEach(model.toName) { voice in
                        Button { Task { asking = await model.detail(voice) } } label: {
                            HStack(spacing: 12) {
                                VoiceAvatar(name: "?", isUnknown: true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(voice.heardFor).font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                                    if !voice.detail.isEmpty {
                                        Text(voice.detail).font(AppFont.footnote).foregroundStyle(Tokens.meta)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Tokens.chevron).accessibilityHidden(true)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("voice.\(voice.id)")
                        .contextMenu {
                            Button(Copy.Voices.dontAsk, systemImage: "nosign") {
                                Task { await model.stopAsking(about: voice) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(Copy.Voices.toName)
        .task { await model.observe() }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $asking, onDismiss: { Task { await model.refresh() } }) { voice in
            WhoIsThisSheet(voice: voice) { UndoCenter.shared.snackbar = $0 }
        }
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

/// A small coloured circle with an initial, one colour per person. A photo can take its place.
struct VoiceAvatar: View {
    let name: String
    var isCurrentUser = false
    /// A voice with no name yet: grey, so it doesn't read as a person.
    var isUnknown = false
    var colorIndex: Int? = nil
    var size: CGFloat = 28

    private var initial: String {
        if isUnknown { return "?" }
        return isCurrentUser ? "Y" : String(name.prefix(1)).uppercased()
    }

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(isUnknown ? Tokens.secondaryBody : Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(isUnknown ? Tokens.grayChipFill
                                      : PersonPalette.fill(colorIndex ?? (isCurrentUser ? PersonPalette.youIndex : 1))))
            .accessibilityHidden(true)
    }
}

/// Plays a clip, stops it, and shows which.
struct VoicePlayButton: View {
    let clip: UnknownVoiceClip
    let player: WhoIsThisModel
    var size: CGFloat = 40

    var body: some View {
        Button { if player.playing == clip.id { player.stop() } else { player.toggle(clip) } } label: {
            Image(systemName: player.playing == clip.id ? "stop.fill" : "play.fill")
                .font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(Tokens.onTint)
                .frame(width: size, height: size).background(Circle().fill(Tokens.tint))
                .frame(width: max(size, 44), height: max(size, 44)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.playing == clip.id ? "Stop" : "Play clip from \(clip.heardAt.map(WhoIsThisSheet.when) ?? "earlier")")
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
