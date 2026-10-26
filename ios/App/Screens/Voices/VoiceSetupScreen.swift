import AppDB
import AVFoundation
import SwiftUI

/// A few short samples, each in a different situation. Recognition hears people through the
/// watch, so the watch is the main microphone here; the phone adds a different view of the
/// same voice. Each row is one sample; recording one opens in place and returns to the list.
struct VoiceSetupScreen: View {
    var person: Person?
    @State private var model: VoiceSettingsModel
    @State private var recorder = VoiceSampleRecorder()
    @State private var watch: VoiceWatchSampleRecorder
    @State private var name = ""
    @State private var prepared = false
    @State private var active: VoiceSampleKind?
    @State private var operation: Task<Void, Never>?
    @FocusState private var editingName: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(person: Person? = nil, model: VoiceSettingsModel = .init(),
         watch: VoiceWatchSampleRecorder = .init()) {
        self.person = person
        _model = State(initialValue: model)
        _watch = State(initialValue: watch)
    }

    private var profile: VoicePersonDisplay? {
        model.display.people.first { person == nil ? $0.person.isCurrentUser : $0.id == person?.id }
    }
    private func samples(of kind: VoiceSampleKind) -> Int {
        (profile?.examples ?? []).filter {
            $0.kind == kind || ($0.kind == nil && kind == .phone && $0.microphone == .phone)
        }.count
    }
    private var recordedKinds: Int { VoiceSampleKind.allCases.filter { samples(of: $0) > 0 }.count }
    private var needsName: Bool { person == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var busy: Bool {
        recorder.isRecording || watch.phase == .recording || watch.phase == .collecting || model.working
    }

    var body: some View {
        NavigationStack {
            SettingsScroll {
                header
                if !prepared {
                    prepareCard
                } else if let active {
                    if active.microphone == .watch { watchCard(active) } else { phoneCard }
                } else {
                    checklist
                }
                if let error = watch.errorMessage ?? recorder.errorMessage ?? model.errorMessage {
                    VoiceMessageCard(text: error)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if active != nil {
                        Button("Back") { closeSample() }.disabled(model.working)
                    } else if recordedKinds == 0 {
                        Button(Copy.Common.cancel) { leave() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if active == nil && recordedKinds > 0 { Button(Copy.Common.done) { leave() } }
                }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
        }
        .tint(Tokens.tint)
        .interactiveDismissDisabled(busy)
        .task {
            await model.refresh()
            if model.display.modelsReady { prepared = true }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { recorder.interrupt(enteredBackground: phase == .background) } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            recorder.interrupt()
        }
        .onDisappear {
            operation?.cancel()
            recorder.cancel()
            watch.cancel()
            Task { await model.cancelEnrollment() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VoiceAvatar(name: person?.name ?? "", isCurrentUser: person?.isCurrentUser ?? true)
            Text(active?.title ?? (person.map { "Remember \($0.name)’s voice" } ?? Copy.Voices.setupTitle))
                .font(AppFont.screenTitle).foregroundStyle(Tokens.label)
                .fixedSize(horizontal: false, vertical: true)
            Text(headerDetail)
                .font(AppFont.callout).foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 16)
    }

    private var headerDetail: String {
        if let active { return active.instruction }
        if let person, !person.isCurrentUser {
            return "Have \(person.name) speak near your watch for about 20 seconds. Samples from a few different places help most."
        }
        return "Record a few short samples through your watch, each somewhere different. Every place it has heard you makes recognition more reliable."
    }

    // MARK: - Models

    private var prepareCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label(Copy.Voices.local, systemImage: "iphone")
                    .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                Text(Copy.Voices.downloadDetail).font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                if let progress = model.downloadProgress {
                    ProgressView(value: progress).tint(Tokens.tint)
                } else {
                    Button(Copy.Voices.prepare) {
                        operation = Task { prepared = await model.prepareForEnrollment() }
                    }.buttonStyle(.inCardFilled).disabled(model.working)
                }
            }
        }
    }

    // MARK: - The list of samples

    @ViewBuilder private var checklist: some View {
        if person == nil {
            ListCard {
                TextField(Copy.Voices.yourName, text: $name)
                    .textContentType(.name).font(AppFont.callout)
                    .focused($editingName).submitLabel(.done)
                    .onSubmit { editingName = false }
            }
        }
        SettingsSectionHeader(title: Copy.Voices.samples)
        ListCard {
            ForEach(VoiceSampleKind.allCases) { kind in sampleRow(kind) }
        }
        SettingsFooter(text: coverageLine)
        if recordedKinds > 0 {
            ListCard {
                TintActionRow(title: Copy.Voices.allRecordings) {
                    operation = Task { await model.recognizeHistory(days: nil) }
                }
            }.disabled(model.working)
            SettingsFooter(text: Copy.Voices.historyDetail)
        }
    }

    private var coverageLine: String {
        switch recordedKinds {
        case 0: return "Start with a quiet room. Each sample takes about 20 seconds."
        case VoiceSampleKind.allCases.count: return "Every situation is covered. You can add more samples at any time."
        default: return "Recognition is on. Each new situation helps it recognize this voice in more places."
        }
    }

    private func sampleRow(_ kind: VoiceSampleKind) -> some View {
        let count = samples(of: kind)
        return Button { openSample(kind) } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(kind)).font(.system(size: 20)).foregroundStyle(Tokens.tint)
                    .frame(width: 44, height: 44).background(Circle().fill(Tokens.tintFill12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                    Text(count > 0 ? (count == 1 ? "Recorded" : "\(count) samples") : kind.detail)
                        .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: count > 0 ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: count > 0 ? 21 : 14, weight: count > 0 ? .regular : .semibold))
                    .foregroundStyle(count > 0 ? Tokens.tint : Tokens.chevron)
                    .accessibilityHidden(true)
            }.frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.working)
        .accessibilityValue(count > 0 ? "Recorded" : "Not recorded")
    }

    static func symbol(_ kind: VoiceSampleKind) -> String {
        switch kind {
        case .quiet: "house"
        case .noisy: "speaker.wave.2"
        case .outdoors: "figure.walk"
        case .phone: "iphone"
        }
    }

    // MARK: - Recording one sample

    private func watchCard(_ kind: VoiceSampleKind) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                switch watch.phase {
                case .idle, .recording:
                    HStack {
                        Label(watch.phase == .recording ? "Listening through your watch…" : "Read this, or talk about your day",
                              systemImage: watch.phase == .recording ? "watch.analog" : "text.quote")
                            .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                        Spacer(minLength: 8)
                        if watch.phase == .recording {
                            Text("\(Int(watch.elapsed)) / \(Int(VoiceWatchSampleRecorder.length)) sec")
                                .monospacedDigit().font(AppFont.footnote).foregroundStyle(Tokens.meta)
                        }
                    }
                    Text(Copy.Voices.prompt).font(AppFont.bodyPlain).foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    if watch.phase == .recording {
                        ProgressView(value: min(watch.elapsed, VoiceWatchSampleRecorder.length),
                                     total: VoiceWatchSampleRecorder.length).tint(Tokens.tint)
                        Button("Finish") { Task { await watch.finish() } }.buttonStyle(.borderedTint)
                    } else {
                        Button("Start listening") {
                            editingName = false
                            operation = Task { await watch.start() }
                        }.buttonStyle(.inCardFilled).disabled(needsName || model.working)
                        if needsName {
                            Text("Add your name first.").font(AppFont.footnote).foregroundStyle(Tokens.meta)
                        }
                    }
                case .collecting:
                    HStack(spacing: 12) {
                        ProgressView().tint(Tokens.tint)
                        Text("Getting the audio from your watch…").font(AppFont.callout).foregroundStyle(Tokens.label)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                case .ready:
                    listenSection(play: { watch.play() }, again: { watch.cancel() })
                }
            }
        }.disabled(model.working)
    }

    @ViewBuilder private var phoneCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                if recorder.pcm == nil {
                    HStack {
                        Text(recorder.isRecording ? Copy.Voices.recording : "Read this, or talk about your day")
                            .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                        Spacer(minLength: 8)
                        if recorder.isRecording {
                            Text("\(Int(recorder.elapsed)) / 20 sec")
                                .monospacedDigit().font(AppFont.footnote).foregroundStyle(Tokens.meta)
                        }
                    }
                    Text(Copy.Voices.prompt).font(AppFont.bodyPlain).foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    if recorder.isRecording {
                        ProgressView(value: recorder.elapsed, total: 20).tint(Tokens.tint)
                        GeometryReader { geometry in
                            Capsule().fill(Tokens.tintFill12)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Tokens.tint).frame(width: geometry.size.width * recorder.level)
                                }
                        }.frame(height: 8).accessibilityLabel("Microphone level")
                        Button(Copy.Voices.stop) { recorder.finish() }.buttonStyle(.borderedTint)
                    } else {
                        Button(Copy.Voices.record) {
                            editingName = false
                            operation = Task { await recorder.start() }
                        }.buttonStyle(.inCardFilled).disabled(needsName || model.working)
                        if needsName {
                            Text("Add your name first.").font(AppFont.footnote).foregroundStyle(Tokens.meta)
                        }
                    }
                } else {
                    listenSection(play: { recorder.play() }, again: { recorder.cancel() })
                }
            }
        }.disabled(model.working)
        SettingsFooter(text: Copy.Voices.samplePrivacy)
    }

    private func listenSection(play: @escaping () -> Void, again: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Listen before saving", systemImage: "waveform")
                .font(AppFont.cardHead).foregroundStyle(Tokens.label)
            Text("Make sure only this person is speaking and the voice sounds clear.")
                .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
            Button(Copy.Voices.listen, action: play).buttonStyle(.borderedTint)
            Button(Copy.Voices.retry, action: again)
                .font(AppFont.callout).foregroundStyle(Tokens.tint)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    @ViewBuilder private var saveBar: some View {
        if let active, (active.microphone == .watch ? watch.phase == .ready : recorder.pcm != nil) {
            Button { save(active) } label: {
                HStack {
                    if model.working { ProgressView().tint(Tokens.onTint) }
                    Text(model.working ? "Learning this voice…" : Copy.Voices.save)
                }
            }.buttonStyle(.primaryFilled).disabled(model.working)
                .padding(16).background(Tokens.ground)
        }
    }

    // MARK: - Actions

    private func openSample(_ kind: VoiceSampleKind) {
        editingName = false
        watch.cancel()
        recorder.cancel()
        active = kind
    }

    private func closeSample() {
        operation?.cancel()
        watch.cancel()
        recorder.cancel()
        Task { await model.cancelEnrollment() }
        active = nil
    }

    private func save(_ kind: VoiceSampleKind) {
        operation = Task {
            let saved: Bool
            if kind.microphone == .watch, let window = watch.watchWindow {
                saved = await model.saveWatchEnrollment(name: name, person: person, fromWallMs: window.lowerBound,
                    toWallMs: window.upperBound, sessionID: watch.sessionID, kind: kind)
            } else if let pcm = recorder.pcm {
                saved = await model.saveEnrollment(name: name, person: person, pcm: pcm,
                                                   sessionID: recorder.sessionID, kind: kind)
            } else { return }
            if saved {
                watch.cancel()
                recorder.cancel()
                active = nil
            }
        }
    }

    private func leave() {
        operation?.cancel()
        recorder.cancel()
        watch.cancel()
        Task { await model.cancelEnrollment() }
        dismiss()
    }
}
