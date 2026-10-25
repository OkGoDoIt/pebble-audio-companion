import AppDB
import AVFoundation
import SwiftUI

struct VoiceSetupScreen: View {
    var person: Person?
    @State private var model: VoiceSettingsModel
    @State private var recorder = VoiceSampleRecorder()
    @State private var name = ""
    @State private var prepared = false
    @State private var saved = false
    @State private var operation: Task<Void, Never>?
    @FocusState private var editingName: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(person: Person? = nil, model: VoiceSettingsModel = .init()) {
        self.person = person
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            SettingsScroll {
                VStack(alignment: .leading, spacing: 12) {
                    VoiceAvatar(name: person?.name ?? "", isCurrentUser: person?.isCurrentUser ?? true)
                    Text(saved ? Copy.Voices.saved : (person.map { "Remember \($0.name)’s voice" } ?? Copy.Voices.setupTitle))
                        .font(AppFont.screenTitle).foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(saved ? Copy.Voices.savedDetail : Copy.Voices.setupDetail)
                        .font(AppFont.callout).foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 16)

                if saved {
                    if let profile = model.display.people.first(where: { profile in person == nil ? profile.person.isCurrentUser : profile.id == person?.id }), !profile.ready {
                        VoiceMessageCard(text: Copy.Voices.needsAnother)
                        Button(Copy.Voices.addSample) { saved = false }.buttonStyle(.borderedTint)
                    }
                    ListCard {
                        TintActionRow(title: Copy.Voices.allRecordings) {
                            operation = Task { await model.recognizeHistory(days: nil); if model.errorMessage == nil { dismiss() } }
                        }
                    }.disabled(model.working)
                    SettingsFooter(text: Copy.Voices.historyDetail)
                    Button(Copy.Common.done) { dismiss() }.buttonStyle(.primaryFilled)
                } else if !prepared {
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
                } else {
                    if person == nil {
                        ListCard {
                            TextField(Copy.Voices.yourName, text: $name)
                                .textContentType(.name).font(AppFont.callout)
                                .focused($editingName).submitLabel(.done)
                                .onSubmit { editingName = false }
                                .disabled(recorder.isRecording || model.working)
                        }
                    }
                    if recorder.pcm == nil {
                        Card {
                            VStack(alignment: .leading, spacing: 16) {
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
                                    }.buttonStyle(.inCardFilled)
                                        .disabled(person == nil && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                    } else {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Listen before saving", systemImage: "waveform")
                                    .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                                Text("Make sure only this person is speaking and the voice sounds clear.")
                                    .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                                Button(Copy.Voices.listen) { recorder.play() }.buttonStyle(.borderedTint)
                                Button(Copy.Voices.retry) { recorder.cancel() }
                                    .font(AppFont.callout).foregroundStyle(Tokens.tint)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }.disabled(model.working)
                        SettingsFooter(text: "Saving turns on voice recognition for new recordings. Earlier recordings are checked only when you choose.")
                        Button {
                            guard let pcm = recorder.pcm else { return }
                            operation = Task {
                                if await model.saveEnrollment(name: name, person: person, pcm: pcm, sessionID: recorder.sessionID) {
                                    recorder.cancel()
                                    saved = true
                                }
                            }
                        } label: {
                            HStack {
                                if model.working { ProgressView().tint(Tokens.onTint) }
                                Text(model.working ? "Learning this voice…" : Copy.Voices.save)
                            }
                        }.buttonStyle(.primaryFilled).disabled(model.working)
                    }
                    SettingsFooter(text: Copy.Voices.samplePrivacy)
                }
                if let error = recorder.errorMessage ?? model.errorMessage { VoiceMessageCard(text: error) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !saved { Button(Copy.Common.cancel) { leave() } }
                }
            }
        }
        .tint(Tokens.tint)
        .interactiveDismissDisabled(recorder.isRecording || model.working)
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
            Task { await model.cancelEnrollment() }
        }
    }

    private func leave() {
        operation?.cancel()
        recorder.cancel()
        Task { await model.cancelEnrollment() }
        dismiss()
    }
}
