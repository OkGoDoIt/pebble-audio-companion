import AppDB
import CompanionRuntime
import SwiftUI

struct VoiceSplitDraft: Equatable, Identifiable {
    var id: String
    var groups: [[UnknownVoiceClip]]
    var payload: VoiceSplitPreview? = nil
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.groups == rhs.groups }
    var clipCount: Int { groups.reduce(0) { $0 + $1.count } }
}

/// What saving a split made: the way to take it back, and each group as a voice that can be named.
struct VoiceSplitResult: Equatable {
    var undoToken: String
    /// One per group of the draft, in order.
    var groupIDs: [String]
}

/// Who a group was said to be, before anything is saved.
enum VoiceSplitName: Equatable {
    case person(Person), me(String), someoneNew(String)
    /// "You" or "Dana", as a heading.
    var title: String {
        switch self {
        case .person(let person): person.isCurrentUser ? Copy.Speaker.you : person.name
        case .me: Copy.Speaker.you
        case .someoneNew(let name): name
        }
    }
    var isCurrentUser: Bool {
        switch self {
        case .person(let person): person.isCurrentUser
        case .me: true
        case .someoneNew: false
        }
    }
}

@MainActor @Observable
final class VoiceSplitModel {
    var draft: VoiceSplitDraft?
    var working = false
    var error: String?
    private(set) var people: [Person] = []
    /// By the clips a group holds: a group that is split again is a new question.
    private var names: [Set<String>: VoiceSplitName] = [:]
    private let source: (any VoiceRecognitionDataSource)?
    private let injectedPeople: (any PeopleDataSource)?
    private var peopleSource: any PeopleDataSource { injectedPeople ?? AskLibraryDataSources.current.people }
    init(source: (any VoiceRecognitionDataSource)? = nil, people: (any PeopleDataSource)? = nil) {
        self.source = source ?? VoiceSources.current
        injectedPeople = people
    }

    func load(_ id: String) async {
        guard draft == nil else { return }
        if people.isEmpty { people = (try? await peopleSource.people()) ?? [] }
        await perform { self.draft = try await self.requiredSource().prepareVoiceSplit(id: id) }
    }
    func refine(_ index: Int, individual: Bool = false) async {
        guard let draft else { return }
        await perform { self.draft = try await self.requiredSource().refineVoiceSplit(draft, group: index, individual: individual) }
    }
    func separate(_ selected: Set<String>, from index: Int) {
        guard var draft, draft.groups.indices.contains(index), !working else { return }
        let group = draft.groups[index]
        let kept = group.filter { selected.contains($0.id) }, rest = group.filter { !selected.contains($0.id) }
        guard !kept.isEmpty, !rest.isEmpty else { return }
        // The clips taken out are the other person; what stays keeps its name.
        if let name = names.removeValue(forKey: Self.key(group)) { names[Self.key(rest)] = name }
        draft.groups.replaceSubrange(index...index, with: [kept,rest])
        self.draft = draft
    }

    private static func key(_ group: [UnknownVoiceClip]) -> Set<String> { Set(group.map(\.id)) }
    func name(of index: Int) -> VoiceSplitName? {
        guard let draft, draft.groups.indices.contains(index) else { return nil }
        return names[Self.key(draft.groups[index])]
    }
    func setName(_ name: VoiceSplitName?, for index: Int) {
        guard let draft, draft.groups.indices.contains(index) else { return }
        names[Self.key(draft.groups[index])] = name
    }
    var hasNames: Bool { draft?.groups.contains { names[Self.key($0)] != nil } ?? false }
    var canSave: Bool { !working && (draft?.groups.count ?? 0) > 1 }

    /// Saves the groups, then names the ones that were answered. The rest stay voices to name.
    func save() async -> SnackbarItem? {
        guard let draft, draft.groups.count > 1 else { return nil }
        var saved: VoiceSplitResult?
        var named: [(voice: String, person: Person)] = []
        var asked = 0
        await perform {
            let source = try self.requiredSource()
            // People first: a name that can't be made leaves the voice as it was.
            var chosen: [Int: Person] = [:], made: [String: Person] = [:]
            for (index, group) in draft.groups.enumerated() {
                switch self.names[Self.key(group)] {
                case .person(let person): chosen[index] = person
                case .me(let name): chosen[index] = try await source.currentUser(name: name)
                case .someoneNew(let name):
                    if made[name.lowercased()] == nil { made[name.lowercased()] = try await self.peopleSource.createPerson(name: name) }
                    chosen[index] = made[name.lowercased()]
                case nil: break
                }
            }
            asked = chosen.count
            let result = try await source.saveVoiceSplit(draft)
            saved = result
            for (index, person) in chosen.sorted(by: { $0.key < $1.key }) where result.groupIDs.indices.contains(index) {
                if (try? await source.nameUnknownVoice(id: result.groupIDs[index], personId: person.id, clips: nil)) != nil {
                    named.append((result.groupIDs[index], person))
                }
            }
        }
        guard let saved else { return nil }
        let source = source
        if asked > 0 {
            guard named.count == asked else { return SnackbarItem(message: "Groups saved, but not every name. Name them from Voices to name.") }
            var titles: [String] = []
            for entry in named {
                let title = entry.person.isCurrentUser ? "you" : entry.person.name
                if !titles.contains(title) { titles.append(title) }
            }
            return SnackbarItem(message: "Named \(Self.list(titles))", actionTitle: Copy.Common.undo) {
                Task { @MainActor in
                    for entry in named { try? await source?.undoNaming(id: entry.voice, personId: entry.person.id) }
                    NotificationCenter.default.post(name: .voiceAnswerTakenBack, object: nil)
                }
            }
        }
        return SnackbarItem(message: "Voice split into \(draft.groups.count) groups", actionTitle: Copy.Common.undo) {
            Task { @MainActor in
                do { try await source?.undoVoiceSplit(id: saved.undoToken) }
                catch { UndoCenter.shared.snackbar = SnackbarItem(message: error.localizedDescription) }
                NotificationCenter.default.post(name: .voiceAnswerTakenBack, object: nil)
            }
        }
    }
    /// "Dana", "Dana and Sam", "Dana, Sam, and Oliver".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
    }
    func discard() { if let draft { source?.discardVoiceSplit(id: draft.id) } }
    private func requiredSource() throws -> any VoiceRecognitionDataSource {
        guard let source else { throw VoiceSplitError.unavailable }; return source
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !working else { return }
        working = true; error = nil
        defer { working = false }
        do { try await action() }
        catch is CancellationError { }
        catch let error as VoiceSplitError { self.error = error.localizedDescription }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? Copy.Speaker.saveFailed }
    }
}

/// A split is a reviewable partition, independent of names. All clips remain reachable, including
/// single samples and two voices in the same recording. A group can be named where it is heard;
/// nothing is persisted until the button at the bottom.
struct VoiceSplitScreen: View {
    let voice: UnknownVoiceDisplay
    let onSaved: (SnackbarItem) -> Void
    @State private var model = VoiceSplitModel()
    @State private var player = WhoIsThisModel()
    @State private var operation: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let draft = model.draft {
                    Text("Listen to each group and say who it is. Split any that still mix people.")
                        .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                    ForEach(draft.groups.indices, id: \.self) { index in
                        groupCard(draft.groups[index], index: index)
                    }
                } else if model.working {
                    ProgressView("Finding smaller groups…").frame(maxWidth: .infinity).padding(.top, 32)
                }
                if let error = model.error { VoiceMessageCard(text: error) }
            }.padding(16)
        }
        .background(Tokens.ground)
        .navigationTitle("Split this voice")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let draft = model.draft {
                    Button {
                        player.stop()
                        operation = Task { if let notice = await model.save() { onSaved(notice) } }
                    } label: {
                        HStack {
                            if model.working { ProgressView().tint(Tokens.onTint) }
                            Text(model.hasNames ? "Save" : "Keep \(draft.groups.count) groups")
                        }
                    }.buttonStyle(.primaryFilled).disabled(!model.canSave)
                } else if !model.working {
                    Button("Try again") { operation = Task { await model.load(voice.id) } }.buttonStyle(.primaryFilled)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12).background(Tokens.ground)
        }
        .task { await model.load(voice.id) }
        .onDisappear { player.stop(); operation?.cancel() }
        // Discard belongs to the owning sheet's lifetime, not a push to the clip review page.
        .onChange(of: voice.id) { _, _ in operation?.cancel(); model.discard() }
    }

    private func groupCard(_ clips: [UnknownVoiceClip], index: Int) -> some View {
        let name = model.name(of: index)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let name {
                    VoiceAvatar(name: name.title, isCurrentUser: name.isCurrentUser, colorIndex: colorIndex(name))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name?.title ?? "Group \(index + 1)").font(AppFont.rowTitle).foregroundStyle(Tokens.label).lineLimit(1)
                    Text(clips.count == 1 ? "1 clip" : "\(clips.count) clips").font(AppFont.footnote).foregroundStyle(Tokens.meta)
                }
                Spacer(minLength: 8)
                NavigationLink {
                    VoiceSplitNameScreen(model: model, groupIndex: index)
                } label: {
                    Text(name == nil ? Copy.Voices.whoIsThis : "Change").font(AppFont.subBody.weight(.semibold)).frame(minHeight: 44)
                }
                .accessibilityIdentifier("split.name.\(index)")
                .simultaneousGesture(TapGesture().onEnded { player.stop() })
            }.padding(.horizontal, 14).padding(.top, 6)
            if let first = clips.first { VoiceClipRow(clip: first, player: player).padding(.horizontal,14).padding(.vertical,10) }
            // A second recording is more useful than another nearly identical neighboring sample.
            if let other = clips.first(where: { $0.segmentId != clips.first?.segmentId }) {
                Divider().padding(.leading, 14)
                VoiceClipRow(clip: other, player: player).padding(.horizontal,14).padding(.vertical,10)
            }
            Divider()
            HStack {
                NavigationLink {
                    VoiceSplitClipsScreen(model: model, groupIndex: index)
                } label: { Text("Review clips").frame(minHeight:44) }
                Spacer()
                Button("Split further") {
                    player.stop(); operation = Task { await model.refine(index) }
                }.frame(minHeight:44).disabled(clips.count < 2 || model.working)
            }.font(AppFont.subBody).padding(.horizontal,14)
        }
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .disabled(model.working)
    }

    private func colorIndex(_ name: VoiceSplitName) -> Int? {
        guard case .person(let person) = name else { return nil }
        return PersonPalette.indices(of: model.people)[person.id]
    }
}

/// "Who is this?" for one group of a split. Choosing someone answers and goes back; the answer
/// is saved with the split.
private struct VoiceSplitNameScreen: View {
    let model: VoiceSplitModel
    let groupIndex: Int
    private enum Typing { case me, someoneNew }
    @Environment(\.dismiss) private var dismiss
    @State private var player = WhoIsThisModel()
    @State private var typing: Typing?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private var clips: [UnknownVoiceClip] {
        guard let draft = model.draft, draft.groups.indices.contains(groupIndex) else { return [] }
        return draft.groups[groupIndex]
    }
    private var current: VoiceSplitName? { model.name(of: groupIndex) }
    private var typed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// You, then everyone else by name.
    private var orderedPeople: [Person] {
        model.people.sorted { a, b in
            if a.isCurrentUser != b.isCurrentUser { return a.isCurrentUser }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        SettingsScroll {
            ListCard(rowVerticalPadding: 8, rowHorizontalPadding: 14) {
                ForEach(clips.prefix(3)) { clip in VoiceClipRow(clip: clip, player: player) }
            }
            SettingsSectionHeader(title: "This is")
            let colors = PersonPalette.indices(of: model.people)
            ListCard(rowVerticalPadding: 8, rowHorizontalPadding: 14) {
                ForEach(orderedPeople, id: \.id) { person in
                    VoicePersonChoiceRow(person: person, colorIndex: colors[person.id] ?? 1,
                                         selected: typing == nil && current == .person(person)) { answer(.person(person)) }
                }
                if !model.people.contains(where: \.isCurrentUser) {
                    VoicePersonChoiceRow(person: nil, title: Copy.Speaker.thisIsMe, selected: typing == .me) { type(.me) }
                }
                VoiceNewPersonRow(selected: typing == .someoneNew) { type(.someoneNew) }
            }
            if let typing {
                ListCard {
                    TextField(typing == .me ? Copy.Voices.yourName : Copy.Speaker.namePlaceholder, text: $newName)
                        .font(AppFont.callout).textContentType(.name).submitLabel(.done)
                        .focused($nameFocused).onSubmit { answerTyped() }
                }
            }
            if current != nil {
                Button("Leave unnamed") { answer(nil) }
                    .font(AppFont.callout).frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .navigationTitle(Copy.Voices.whoIsThis)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let typing {
                Button(typing == .me ? Copy.Voices.thats("you") : typed.isEmpty ? Copy.Voices.nameVoice : "Name \(typed)") { answerTyped() }
                    .buttonStyle(.primaryFilled).disabled(typed.isEmpty)
                    .padding(.horizontal, 16).padding(.vertical, 12).background(Tokens.ground)
            }
        }
        .onAppear {
            switch current {
            case .me(let name): typing = .me; newName = name
            case .someoneNew(let name): typing = .someoneNew; newName = name
            case .person, nil: break
            }
        }
        .onDisappear { player.stop() }
    }

    private func type(_ kind: Typing) {
        if typing != kind { newName = "" }
        typing = kind
        nameFocused = true
    }
    private func answerTyped() {
        guard let typing, !typed.isEmpty else { return }
        // A name already in the list is that person, not a second one.
        if typing == .someoneNew,
           let known = model.people.first(where: { !$0.isCurrentUser && $0.name.localizedCaseInsensitiveCompare(typed) == .orderedSame }) {
            answer(.person(known))
        } else {
            answer(typing == .me ? .me(typed) : .someoneNew(typed))
        }
    }
    private func answer(_ name: VoiceSplitName?) {
        player.stop()
        model.setName(name, for: groupIndex)
        dismiss()
    }
}

private struct VoiceSplitClipsScreen: View {
    let model: VoiceSplitModel
    let groupIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var player = WhoIsThisModel()
    @State private var operation: Task<Void, Never>?
    private var clips: [UnknownVoiceClip] {
        guard let draft = model.draft, draft.groups.indices.contains(groupIndex) else { return [] }
        return draft.groups[groupIndex]
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Select clips of the same person to move into a separate group.")
                    .font(AppFont.subBody).foregroundStyle(Tokens.secondaryBody)
                HStack {
                    Text("\(selected.count) selected").font(AppFont.footnote).foregroundStyle(Tokens.meta)
                    Spacer()
                    Button(selected.isEmpty ? "Select all" : "Clear selection") {
                        selected = selected.isEmpty ? Set(clips.map(\.id)) : []
                    }.font(AppFont.subBody).frame(minHeight:44)
                }
                LazyVStack(spacing: 0) {
                    ForEach(clips) { clip in
                        VoiceClipRow(clip: clip, player: player, checked: selected.contains(clip.id)) {
                            if selected.contains(clip.id) { selected.remove(clip.id) } else { selected.insert(clip.id) }
                        }.padding(.horizontal,14).padding(.vertical,10)
                        Divider().padding(.leading,14)
                    }
                }.background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.cardRadius))
                if let error = model.error { VoiceMessageCard(text: error) }
            }.padding(16)
        }
        .background(Tokens.ground)
        .navigationTitle("Group \(groupIndex + 1)")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Button("Separate selected clips") { player.stop(); model.separate(selected, from: groupIndex); dismiss() }
                    .buttonStyle(.primaryFilled).disabled(selected.isEmpty || selected.count == clips.count || model.working)
                Button("Separate every clip") {
                    player.stop()
                    operation = Task { await model.refine(groupIndex, individual: true); if model.error == nil { dismiss() } }
                }.font(AppFont.callout.weight(.semibold)).frame(minHeight:44).disabled(clips.count < 2 || model.working)
            }.padding(.horizontal,16).padding(.vertical,12).background(Tokens.ground)
        }
        .onDisappear { player.stop(); operation?.cancel() }
    }
}
