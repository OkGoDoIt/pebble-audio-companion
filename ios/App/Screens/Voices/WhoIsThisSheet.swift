import AppDB
import AVFoundation
import Observation
import SwiftUI

/// Asks who a voice is that the watch keeps hearing without a name. One answer names it in every
/// recording it was heard in and teaches the voice. A voice is one person, so the choice is single:
/// the iOS single-choice checkmark, not the multi-select circles. "More than one person" is the
/// answer for a group that mixes voices.
struct WhoIsThisSheet: View {
    let voice: UnknownVoiceDisplay
    /// Called after an answer, with the line to show once.
    let onAnswered: (SnackbarItem) -> Void

    private enum Choice: Equatable { case person(String), me, newPerson }
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router: AppRouter?
    @State private var model: WhoIsThisModel
    @State private var choice: Choice?
    @State private var newName = ""
    /// What was said, read once the sheet is up.
    @State private var full: UnknownVoiceDisplay?
    /// "More than one person": pick which recordings are the one person being named.
    @State private var splitting = false
    @State private var selecting = false
    @State private var kept: Set<String> = []

    init(voice: UnknownVoiceDisplay, model: WhoIsThisModel = .init(), onAnswered: @escaping (SnackbarItem) -> Void) {
        self.voice = voice
        self.onAnswered = onAnswered
        _model = State(initialValue: model)
        _choice = State(initialValue: voice.suggestion.map { .person($0.person.id) })
    }

    private var shown: UnknownVoiceDisplay { full ?? voice }

    var body: some View {
        NavigationStack {
            SettingsScroll {
                ListCard(rowVerticalPadding: 8, rowHorizontalPadding: 14) {
                    ForEach(shown.clips.prefix(3)) { clip in clipRow(clip) }
                }
                SettingsFooter(text: "Heard for \(shown.heardFor).")
                peoplePicker
            }
            .navigationTitle(Copy.Voices.whoIsThis)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Voices.notNow) { model.stop(); dismiss() }.disabled(model.working)
                }
            }
            .safeAreaInset(edge: .bottom) {
                actions(count: shown.recordingCount, clips: nil) {
                    Button(Copy.Voices.moreThanOne) {
                        model.stop()
                        kept = Set(shown.clips.map(\.id))
                        splitting = true
                    }
                    .font(AppFont.callout.weight(.semibold)).foregroundStyle(Tokens.tint)
                    .frame(maxWidth: .infinity, minHeight: 44).disabled(model.working)
                    Button("Select clips to name") {
                        model.stop(); kept = []; selecting = true
                    }.font(AppFont.callout).frame(maxWidth: .infinity, minHeight: 44).disabled(model.working)
                    Button(Copy.Voices.dontAsk) {
                        Task {
                            guard await model.ignoreAll(voice) else { return }
                            onAnswered(SnackbarItem(message: Copy.Voices.wontAsk))
                            dismiss()
                        }
                    }
                    .font(AppFont.callout).foregroundStyle(Tokens.tint)
                    .frame(maxWidth: .infinity, minHeight: 44).disabled(model.working)
                }
            }
            .navigationDestination(isPresented: $splitting) {
                VoiceSplitScreen(voice: shown) { notice in onAnswered(notice); dismiss() }
            }
            .navigationDestination(isPresented: $selecting) { splitPage }
        }
        .tint(Tokens.tint)
        .interactiveDismissDisabled(model.working)
        .task {
            await model.load()
            full = await model.detail(of: voice.id)
        }
        .onDisappear { model.stop() }
    }

    /// Every recording the voice was grouped from, to tick the ones that are this person.
    private var splitPage: some View {
        SettingsScroll {
            Text("Select clips of the same person.")
                .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            Button(kept.isEmpty ? "Select all" : "Clear selection") { kept = kept.isEmpty ? Set(shown.clips.map(\.id)) : [] }
                .frame(minHeight: 44)
            ListCard(rowVerticalPadding: 8, rowHorizontalPadding: 14) {
                ForEach(shown.clips) { clip in clipRow(clip, checkable: true) }
            }
            SettingsFooter(text: "The rest stay unnamed.")
            peoplePicker
        }
        .navigationTitle("Same person?")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actions(count: kept.count, clips: kept) { EmptyView() }
        }
        .onDisappear { model.stop() }
    }

    /// The closest match first, then you, then everyone else.
    private var orderedPeople: [Person] {
        let suggested = shown.suggestion?.person.id
        return model.people.sorted { a, b in
            if (a.id == suggested) != (b.id == suggested) { return a.id == suggested }
            if a.isCurrentUser != b.isCurrentUser { return a.isCurrentUser }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    @ViewBuilder private var peoplePicker: some View {
        SettingsSectionHeader(title: "This is")
        let colors = PersonPalette.indices(of: model.people)
        ListCard(rowVerticalPadding: 8, rowHorizontalPadding: 14) {
            ForEach(orderedPeople, id: \.id) { person in
                VoicePersonChoiceRow(person: person, colorIndex: colors[person.id] ?? 1,
                                     detail: person.id == shown.suggestion?.person.id ? Copy.Voices.closestMatch : nil,
                                     selected: choice == .person(person.id)) { choice = .person(person.id) }
            }
            if !model.people.contains(where: \.isCurrentUser) {
                VoicePersonChoiceRow(person: nil, title: Copy.Speaker.thisIsMe, selected: choice == .me) {
                    choice = .me; newName = ""
                }
            }
            VoiceNewPersonRow(selected: choice == .newPerson) { choice = .newPerson; newName = "" }
        }.disabled(model.working)
        if choice == .newPerson || choice == .me {
            ListCard {
                TextField(choice == .me ? Copy.Voices.yourName : Copy.Speaker.namePlaceholder, text: $newName)
                    .font(AppFont.callout).textContentType(.name).submitLabel(.done)
            }.disabled(model.working)
        }
        if let error = model.errorMessage { VoiceMessageCard(text: error) }
    }

    private var actionTitle: String {
        switch choice {
        case .person(let id):
            guard let person = model.people.first(where: { $0.id == id }) else { return Copy.Voices.nameVoice }
            return person.isCurrentUser ? Copy.Voices.thats("you") : "Name \(person.name)"
        case .me: return Copy.Voices.thats("you")
        case .newPerson:
            let typed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            return typed.isEmpty ? Copy.Voices.nameVoice : "Name \(typed)"
        case nil: return Copy.Voices.nameVoice
        }
    }

    private func actions(count: Int, clips: Set<String>?, @ViewBuilder secondary: () -> some View) -> some View {
        VStack(spacing: 2) {
            Button { name(count: count, clips: clips) } label: {
                HStack {
                    if model.working { ProgressView().tint(Tokens.onTint) }
                    Text(actionTitle)
                }
            }
            .buttonStyle(.primaryFilled).disabled(!canName || count == 0).padding(.bottom, 4)
            secondary()
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8).background(Tokens.ground)
    }

    private var canName: Bool {
        guard !model.working, let choice else { return false }
        if choice == .newPerson || choice == .me { return !newName.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    private func name(count: Int, clips: Set<String>?) {
        guard canName, let choice else { return }
        Task {
            let named: String?
            let personId: String?
            switch choice {
            case .person(let id):
                named = await model.name(voice, personId: id, clips: clips)
                personId = id
            case .me:
                named = await model.nameAsMe(voice, displayName: newName, clips: clips)
                personId = nil
            case .newPerson:
                named = await model.nameAsNewPerson(voice, name: newName, clips: clips)
                personId = nil
            }
            guard let named else { return }
            if let personId {
                onAnswered(WhoIsThisModel.namedNotice(named, count: model.namedRecordingCount, voiceId: voice.id, personId: personId) {})
            } else {
                onAnswered(SnackbarItem(message: Copy.Voices.named(named, in: model.namedRecordingCount)))
            }
            dismiss()
        }
    }

    private func clipRow(_ clip: UnknownVoiceClip, checkable: Bool = false) -> some View {
        VoiceClipRow(clip: clip, player: model, checked: checkable ? kept.contains(clip.id) : nil,
            onToggle: {
                if kept.contains(clip.id) { kept.remove(clip.id) } else { kept.insert(clip.id) }
            },
            onIgnore: {
                Task {
                    guard await model.ignore(clip) else { return }
                    onAnswered(SnackbarItem(message: "Clip ignored"))
                    dismiss()
                }
            },
            onOpen: clip.heardAt == nil ? nil : { show(clip) })
    }

    /// Leaves the question for the conversation, at the moment the clip was heard.
    private func show(_ clip: UnknownVoiceClip) {
        model.stop()
        Task {
            guard let route = await UnknownVoiceClip.route(clip) else { model.couldNotOpen(); return }
            dismiss()
            router?.navigate(to: route)
        }
    }

    /// "Today, 8:12 AM", "Saturday, 7:40 AM", "Oct 12, 7:40 AM".
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 99
        let day = days < 7 ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(.dateTime.month(.abbreviated).day())
        return "\(day), \(time)"
    }
}

/// One person in "This is": the same row wherever a voice is being named.
struct VoicePersonChoiceRow: View {
    var person: Person?
    var colorIndex: Int? = nil
    var title: String? = nil
    var detail: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VoiceAvatar(name: person?.name ?? "", isCurrentUser: person?.isCurrentUser ?? true, colorIndex: colorIndex)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? (person?.isCurrentUser == true ? Copy.Speaker.you : person?.name ?? ""))
                        .font(AppFont.bodyPlain).foregroundStyle(Tokens.label).lineLimit(1)
                    if let detail { Text(detail).font(AppFont.footnote).foregroundStyle(Tokens.meta) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                // iOS single choice: a checkmark on the chosen row only.
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Tokens.tint)
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
            }.frame(minHeight: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Someone new", under the people.
struct VoiceNewPersonRow: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.tint)
                    .frame(width: 28, height: 28).background(Circle().fill(Tokens.grayChipFill)).accessibilityHidden(true)
                Text(Copy.Voices.someoneNew).font(AppFont.bodyPlain).foregroundStyle(Tokens.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Tokens.tint)
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
            }.frame(minHeight: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension UnknownVoiceClip {
    /// The conversation at the moment this clip was heard.
    @MainActor static func route(_ clip: UnknownVoiceClip) async -> Route? {
        guard let heardAt = clip.heardAt else { return nil }
        return await Route.moment(atWallMs: Int64(heardAt.timeIntervalSince1970 * 1_000))
    }
}

/// Plays voice clips (a clip, or a clip with the audio around it), one at a time.
@MainActor @Observable
final class WhoIsThisModel {
    private(set) var people: [Person] = []
    private(set) var working = false
    private(set) var errorMessage: String?
    private(set) var playing: String?
    /// The clip playing is the longer one, with the audio around it.
    private(set) var playingLonger = false
    private var player: AVAudioPlayer?
    private let injectedVoices: (any VoiceRecognitionDataSource)?
    private let injectedPeople: (any PeopleDataSource)?
    private var voices: (any VoiceRecognitionDataSource)? { injectedVoices ?? VoiceSources.current }
    private var peopleSource: any PeopleDataSource { injectedPeople ?? AskLibraryDataSources.current.people }

    init(voices: (any VoiceRecognitionDataSource)? = nil, people: (any PeopleDataSource)? = nil) {
        injectedVoices = voices
        injectedPeople = people
    }

    func load() async {
        do { people = try await peopleSource.people() } catch { errorMessage = Copy.Speaker.loadFailed }
    }

    func toggle(_ clip: UnknownVoiceClip, longer: Bool = false) {
        if playing == clip.id, playingLonger == longer { stop(); return }
        stop()
        playing = clip.id
        playingLonger = longer
        Task {
            let audio = longer
                ? await voices?.clipContextAudio(segmentId: clip.segmentId, startMs: clip.startMs, endMs: clip.endMs)
                : await voices?.clipAudio(segmentId: clip.segmentId, startMs: clip.startMs, endMs: clip.endMs)
            guard let pcm = audio, playing == clip.id else { if playing == clip.id { playing = nil }; return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(data: VoiceWatchSampleRecorder.wav(pcm))
                player?.play()
                let length = Double(pcm.count) / 32_000
                try? await Task.sleep(for: .seconds(length))
                if playing == clip.id { playing = nil; playingLonger = false }
            } catch {
                playing = nil
                errorMessage = "Couldn’t play this clip."
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        playingLonger = false
    }

    func couldNotOpen() { errorMessage = "Couldn’t find this moment in a conversation." }

    /// The voice with what was said in each clip.
    func detail(of id: String) async -> UnknownVoiceDisplay? { await voices?.voiceDetail(id: id) }

    /// "Confirm 3 for Dana". Returns the line to show, with its offer to undo.
    func confirm(_ voice: UnknownVoiceDisplay, as suggestion: VoiceSuggestionDisplay, clips: Set<String>?) async -> SnackbarItem? {
        var count = 0
        let voices = self.voices
        guard await answer({
            guard let voices else { throw SpeakerEditorError.voiceUnavailable }
            count = try await voices.nameUnknownVoice(id: voice.id, personId: suggestion.person.id, clips: clips)
            return "named"
        }) != nil else { return nil }
        return Self.namedNotice(suggestion.name, count: count, voiceId: voice.id, personId: suggestion.person.id) {}
    }

    /// "None of these are Dana".
    func reject(_ voice: UnknownVoiceDisplay, as suggestion: VoiceSuggestionDisplay) async -> Bool {
        let voices = self.voices
        return await answer {
            guard let voices else { throw SpeakerEditorError.voiceUnavailable }
            try await voices.rejectSuggestion(id: voice.id, personId: suggestion.person.id)
            return "rejected"
        } != nil
    }

    /// "Named Dana in 4 conversations", and the way back.
    static func namedNotice(_ name: String, count: Int, voiceId: String, personId: String,
                            afterUndo: @escaping @MainActor () async -> Void) -> SnackbarItem {
        SnackbarItem(message: Copy.Voices.named(name, in: count), actionTitle: Copy.Common.undo, action: {
            Task { @MainActor in
                try? await VoiceSources.current?.undoNaming(id: voiceId, personId: personId)
                await afterUndo()
            }
        })
    }

    func ignore(_ clip: UnknownVoiceClip) async -> Bool {
        await answer {
            guard let voices = self.voices else { throw SpeakerEditorError.voiceUnavailable }
            try await voices.ignoreUnknownClip(clip)
            return "ignored"
        } != nil
    }

    func ignoreAll(_ voice: UnknownVoiceDisplay) async -> Bool {
        await answer {
            guard let voices = self.voices else { throw SpeakerEditorError.voiceUnavailable }
            try await voices.dismissUnknownVoice(id: voice.id)
            return "ignored"
        } != nil
    }

    private(set) var namedRecordingCount = 0

    /// The person's display name on success.
    func name(_ voice: UnknownVoiceDisplay, personId: String, clips: Set<String>? = nil) async -> String? {
        await answer {
            guard let person = self.people.first(where: { $0.id == personId }) else { throw SpeakerEditorError.voiceUnavailable }
            guard let voices = self.voices else { throw SpeakerEditorError.voiceUnavailable }
            self.namedRecordingCount = try await voices.nameUnknownVoice(id: voice.id, personId: personId, clips: clips)
            return person.isCurrentUser ? "you" : person.name
        }
    }

    func nameAsMe(_ voice: UnknownVoiceDisplay, displayName: String, clips: Set<String>? = nil) async -> String? {
        await answer {
            guard let voices = self.voices else { throw SpeakerEditorError.voiceUnavailable }
            let me = try await voices.currentUser(name: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            self.namedRecordingCount = try await voices.nameUnknownVoice(id: voice.id, personId: me.id, clips: clips)
            return "you"
        }
    }

    func nameAsNewPerson(_ voice: UnknownVoiceDisplay, name: String, clips: Set<String>? = nil) async -> String? {
        await answer {
            guard let voices = self.voices else { throw SpeakerEditorError.voiceUnavailable }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let person = try await self.peopleSource.createPerson(name: trimmed)
            self.namedRecordingCount = try await voices.nameUnknownVoice(id: voice.id, personId: person.id, clips: clips)
            return trimmed
        }
    }

    private func answer(_ work: () async throws -> String) async -> String? {
        guard !working else { return nil }
        stop()
        working = true
        errorMessage = nil
        defer { working = false }
        do { return try await work() } catch {
            errorMessage = Copy.Speaker.saveFailed
            return nil
        }
    }
}
