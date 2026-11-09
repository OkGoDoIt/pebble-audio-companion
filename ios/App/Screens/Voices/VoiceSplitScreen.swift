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

@MainActor @Observable
final class VoiceSplitModel {
    var draft: VoiceSplitDraft?
    var working = false
    var error: String?
    private let source: (any VoiceRecognitionDataSource)?
    init(source: (any VoiceRecognitionDataSource)? = nil) { self.source = source ?? VoiceSources.current }

    func load(_ id: String) async {
        guard draft == nil else { return }
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
        draft.groups.replaceSubrange(index...index, with: [kept,rest])
        self.draft = draft
    }
    func save() async -> SnackbarItem? {
        guard let draft, draft.groups.count > 1 else { return nil }
        var token: String?
        await perform { token = try await self.requiredSource().saveVoiceSplit(draft) }
        guard let token else { return nil }
        let source = source
        return SnackbarItem(message: "Voice split into \(draft.groups.count) groups", actionTitle: Copy.Common.undo) {
            Task { @MainActor in
                do { try await source?.undoVoiceSplit(id: token) }
                catch { UndoCenter.shared.snackbar = SnackbarItem(message: error.localizedDescription) }
            }
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
        catch { self.error = error.localizedDescription }
    }
}

/// A split is a reviewable partition, independent of names. All clips remain reachable, including
/// single samples and two voices in the same recording. Nothing is persisted until Keep groups.
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
                    Text("Listen to each group. Split any that still contain different people.")
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
                            Text("Keep \(draft.groups.count) groups")
                        }
                    }.buttonStyle(.primaryFilled).disabled(model.working || draft.groups.count < 2)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Group \(index + 1)").font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                Spacer()
                Text(clips.count == 1 ? "1 clip" : "\(clips.count) clips").font(AppFont.footnote).foregroundStyle(Tokens.meta)
            }.padding(.horizontal, 14).padding(.top, 12)
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
