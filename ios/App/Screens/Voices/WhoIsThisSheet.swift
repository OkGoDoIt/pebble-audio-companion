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
    let onAnswered: (String) -> Void

    private enum Choice: Equatable { case person(String), me, newPerson }
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router: AppRouter?
    @State private var model: WhoIsThisModel
    @State private var choice: Choice?
    @State private var newName = ""
    /// "More than one person": pick which recordings are the one person being named.
    @State private var splitting = false
    @State private var kept: Set<String> = []

    init(voice: UnknownVoiceDisplay, model: WhoIsThisModel = .init(), onAnswered: @escaping (String) -> Void) {
        self.voice = voice
        self.onAnswered = onAnswered
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            SettingsScroll {
                ListCard {
                    ForEach(voice.clips.prefix(3)) { clip in clipRow(clip) }
                }
                if voice.clips.count > 3 {
                    SettingsFooter(text: "Also heard in \(voice.clips.count - 3) more recordings.")
                }
                peoplePicker
            }
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { model.stop(); dismiss() }.disabled(model.working)
                }
            }
            .safeAreaInset(edge: .bottom) {
                actions(count: voice.recordingCount, recordings: nil) {
                    Button("More than one person") {
                        model.stop()
                        kept = Set(voice.clips.map(\.segmentId))
                        splitting = true
                    }
                    .font(AppFont.callout.weight(.semibold)).foregroundStyle(Tokens.tint)
                    .frame(maxWidth: .infinity, minHeight: 44).disabled(model.working)
                }
            }
            .navigationDestination(isPresented: $splitting) { splitPage }
        }
        .tint(Tokens.tint)
        .interactiveDismissDisabled(model.working)
        .task { await model.load() }
        .onDisappear { model.stop() }
    }

    /// Every recording the voice was grouped from, to tick the ones that are this person.
    private var splitPage: some View {
        SettingsScroll {
            Text("Check the recordings where it’s the same person.")
                .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            ListCard {
                ForEach(voice.clips) { clip in clipRow(clip, checkable: true) }
            }
            SettingsFooter(text: "Unchecked recordings stay unnamed.")
            peoplePicker
        }
        .navigationTitle("Same person?")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actions(count: kept.count, recordings: kept) { EmptyView() }
        }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var peoplePicker: some View {
        SettingsSectionHeader(title: "This is")
        ListCard {
            ForEach(model.people.sorted { $0.isCurrentUser && !$1.isCurrentUser }, id: \.id) { person in
                choiceRow(.person(person.id), title: person.isCurrentUser ? "\(person.name) · You" : person.name) {
                    VoiceAvatar(name: person.name, isCurrentUser: person.isCurrentUser)
                }
            }
            if !model.people.contains(where: \.isCurrentUser) {
                choiceRow(.me, title: Copy.Speaker.thisIsMe) { VoiceAvatar(name: "", isCurrentUser: true) }
            }
            choiceRow(.newPerson, title: Copy.Speaker.newPerson) {
                Image(systemName: "person.badge.plus").font(.system(size: 20)).foregroundStyle(Tokens.meta)
                    .frame(width: 44, height: 44).accessibilityHidden(true)
            }
        }.disabled(model.working)
        if choice == .newPerson || choice == .me {
            ListCard {
                TextField(choice == .me ? Copy.Voices.yourName : Copy.Speaker.namePlaceholder, text: $newName)
                    .font(AppFont.callout).textContentType(.name).submitLabel(.done)
            }.disabled(model.working)
        }
        if let error = model.errorMessage { VoiceMessageCard(text: error) }
    }

    private func actions(count: Int, recordings: Set<String>?, @ViewBuilder secondary: () -> some View) -> some View {
        VStack(spacing: 4) {
            Button { name(count: count, recordings: recordings) } label: {
                HStack {
                    if model.working { ProgressView().tint(Tokens.onTint) }
                    Text(count == 1 ? "Name in 1 recording" : "Name in \(count) recordings")
                }
            }.buttonStyle(.primaryFilled).disabled(!canName || count == 0)
            secondary()
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8).background(Tokens.ground)
    }

    private var canName: Bool {
        guard !model.working, let choice else { return false }
        if choice == .newPerson || choice == .me { return !newName.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    private func name(count: Int, recordings: Set<String>?) {
        guard canName, let choice else { return }
        Task {
            let named: String?
            switch choice {
            case .person(let id): named = await model.name(voice, personId: id, recordings: recordings)
            case .me: named = await model.nameAsMe(voice, displayName: newName, recordings: recordings)
            case .newPerson: named = await model.nameAsNewPerson(voice, name: newName, recordings: recordings)
            }
            guard let named else { return }
            onAnswered(count == 1 ? "Named \(named) in 1 recording" : "Named \(named) in \(count) recordings")
            dismiss()
        }
    }

    private func clipRow(_ clip: UnknownVoiceClip, checkable: Bool = false) -> some View {
        HStack(spacing: 12) {
            Button { if model.playing == clip.id { model.stop() } else { model.toggle(clip) } } label: {
                Image(systemName: model.playing == clip.id ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.onTint)
                    .frame(width: 36, height: 36).background(Circle().fill(Tokens.tint))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.playing == clip.id ? "Stop" : "Play clip from \(clip.heardAt.map(Self.when) ?? "earlier")")
            Button {
                if checkable {
                    if kept.contains(clip.segmentId) { kept.remove(clip.segmentId) } else { kept.insert(clip.segmentId) }
                } else { model.toggle(clip) }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.heardAt.map(Self.when) ?? "Earlier").font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                        if let quote = clip.quote {
                            Text(quote).font(AppFont.footnote).foregroundStyle(Tokens.meta).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if checkable {
                        // Several can be the same person, so this one is a multi-select checkbox.
                        Image(systemName: kept.contains(clip.segmentId) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22)).foregroundStyle(kept.contains(clip.segmentId) ? Tokens.tint : Tokens.chevron)
                            .accessibilityHidden(true)
                    }
                }.frame(minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(checkable && kept.contains(clip.segmentId) ? .isSelected : [])
            // A clip is a few seconds; these are for when that isn't enough to tell.
            Menu {
                Button(model.playing == clip.id && model.playingLonger ? "Stop" : "Play Longer",
                       systemImage: "waveform") { model.toggle(clip, longer: true) }
                if clip.heardAt != nil {
                    Button("Open Conversation", systemImage: "text.bubble") { show(clip) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(Tokens.tint)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("More for this clip")
        }
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

    private func choiceRow(_ value: Choice, title: String, @ViewBuilder avatar: () -> some View) -> some View {
        Button { choice = value; if value == .newPerson || value == .me { newName = "" } } label: {
            HStack(spacing: 12) {
                avatar()
                Text(title).font(AppFont.callout).foregroundStyle(Tokens.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // iOS single choice: a checkmark on the chosen row only.
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Tokens.tint)
                    .opacity(choice == value ? 1 : 0).accessibilityHidden(true)
            }.frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice == value ? .isSelected : [])
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

    /// The person's display name on success.
    func name(_ voice: UnknownVoiceDisplay, personId: String, recordings: Set<String>? = nil) async -> String? {
        await answer {
            guard let person = self.people.first(where: { $0.id == personId }) else { throw SpeakerEditorError.voiceUnavailable }
            _ = try await self.voices?.nameUnknownVoice(id: voice.id, personId: personId, recordings: recordings)
            return person.isCurrentUser ? "you" : person.name
        }
    }

    func nameAsMe(_ voice: UnknownVoiceDisplay, displayName: String, recordings: Set<String>? = nil) async -> String? {
        await answer {
            guard let voices = self.voices else { throw SpeakerEditorError.voiceUnavailable }
            let me = try await voices.currentUser(name: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = try await voices.nameUnknownVoice(id: voice.id, personId: me.id, recordings: recordings)
            return "you"
        }
    }

    func nameAsNewPerson(_ voice: UnknownVoiceDisplay, name: String, recordings: Set<String>? = nil) async -> String? {
        await answer {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let person = try await self.peopleSource.createPerson(name: trimmed)
            _ = try await self.voices?.nameUnknownVoice(id: voice.id, personId: person.id, recordings: recordings)
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
