import SwiftUI
import AppDB

/// Conversation detail (mockup 2.6 + States · Conversation): custom nav (back names the
/// actual parent — B15; Share + ⋯), header (title / meta / summary / editable-on-tap tags),
/// player card, lifecycle state cards, speaker-colored transcript with inline markers, and
/// the [Ask][Notes][Follow-ups] bottom bar. No tab bar.
struct ConversationScreen: View {
    let conversationId: String
    var atMs: Int64?
    var originLabel: String = Copy.Library.title

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model = ConversationViewModel()
    @State private var player = PlayerModel()

    var body: some View {
        VStack(spacing: 0) {
            DetailNavBar(
                backLabel: originLabel,
                onBack: { dismiss() },
                shareText: model.display?.shareText,
                menu: { ellipsisMenu }
            )

            if let display = model.display {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.blockGap) {
                        header(display)
                        if display.player != nil {
                            PlayerCard(model: player)
                        }
                        lifecycleCard(display.lifecycle)
                        if !display.transcript.isEmpty {
                            TranscriptView(
                                transcript: display.transcript,
                                provenance: display.provenance
                            ) { turn in
                                model.renameTurn = turn
                            }
                        }
                        if let result = model.actionResult {
                            Text(result)
                                .font(AppFont.footnote)
                                .foregroundStyle(Tokens.meta)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Tokens.screenMargin)
                    .padding(.top, 4)
                    .padding(.bottom, Tokens.blockGap)
                }
            } else {
                Spacer()
            }
        }
        .background(Tokens.ground)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task(id: conversationId) { await load() }
        .sheet(item: $model.renameTurn) { turn in
            SpeakerRenameSheet(conversationId: conversationId, turn: turn) {
                Task { await load() }
            }
        }
        .sheet(isPresented: $model.showTagEditor, onDismiss: { Task { await load() } }) {
            TagEditorSheet(conversationId: conversationId)
        }
        .sheet(isPresented: $model.showTemplates) {
            TemplateSheet(conversationId: conversationId) { note in
                model.showTemplates = false
                router.libraryPath.append(Route.note(id: note.id))
            }
        }
        .sheet(isPresented: $model.showFollowUps, onDismiss: { Task { await load() } }) {
            FollowUpsSheet(conversationId: conversationId)
        }
        .alert(Copy.Conversation.rename, isPresented: $model.showRename) {
            TextField("", text: $model.renameDraft)
            Button(Copy.Common.cancel, role: .cancel) {}
            Button(Copy.Common.save) {
                Task {
                    try? await AskLibraryDataSources.current.conversations.rename(
                        id: conversationId, to: model.renameDraft)
                    await load()
                }
            }
        }
        .confirmationDialog(
            Copy.Conversation.exportAudio, isPresented: $model.confirmExport,
            titleVisibility: .visible
        ) {
            Button("Export WAV") { model.exportAudio(id: conversationId) }
        }
        .confirmationDialog(
            Copy.Conversation.delete, isPresented: $model.confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Conversation", role: .destructive) {
                Haptics.destructiveConfirmed()
                deleteConversation()
            }
        }
    }

    private func load() async {
        await model.load(id: conversationId)
        if let display = model.display, let playerDisplay = display.player {
            player.configure(playerDisplay, atMs: atMs)
        }
    }

    // MARK: - Header

    private func header(_ display: ConversationDisplay) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(display.title)
                .font(AppFont.detailTitle)
                .foregroundStyle(Tokens.label)
                .fixedSize(horizontal: false, vertical: true)
            Text(display.metaLine)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
            if let summary = display.summary {
                Text(summary)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.secondaryBody)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !display.tags.isEmpty {
                Button {
                    model.showTagEditor = true
                } label: {
                    HStack(spacing: 6) {
                        ForEach(display.tags, id: \.id) { tag in
                            TagChip(text: tag.name, style: .onGround)
                        }
                    }
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Conversation.editTags)
            }
        }
    }

    // MARK: - ⋯ menu (Rename / Edit Tags / Re-transcribe / Export Audio… / Delete…)

    private var ellipsisMenu: some View {
        EllipsisMenu {
            Button(Copy.Conversation.rename) {
                model.renameDraft = model.display?.title ?? ""
                model.showRename = true
            }
            Button(Copy.Conversation.editTags) { model.showTagEditor = true }
            Button(Copy.Conversation.retranscribe) {
                Task {
                    try? await AskLibraryDataSources.current.conversations.retranscribe(
                        id: conversationId)
                    await load()
                }
            }
            Button(Copy.Conversation.exportAudio) { model.confirmExport = true }
            Button(Copy.Conversation.delete, role: .destructive) {
                model.confirmDelete = true
            }
        }
    }

    private func deleteConversation() {
        let id = conversationId
        Task {
            try? await AskLibraryDataSources.current.conversations.delete(id: id)
            dismiss()
            UndoCenter.shared.snackbar = SnackbarItem(
                message: Copy.Conversation.deleted,
                actionTitle: Copy.Common.undo,
                action: {
                    Task {
                        try? await AskLibraryDataSources.current.conversations.undoDelete(id: id)
                    }
                }
            )
        }
    }

    // MARK: - Lifecycle state cards (States · Conversation artboard)

    @ViewBuilder
    private func lifecycleCard(_ lifecycle: LifecycleDisplay) -> some View {
        switch lifecycle {
        case .complete:
            EmptyView()
        case .capturedWaiting(let queueLine):
            stateCard(
                dot: Tokens.captured,
                headline: Copy.Conversation.capturedWaiting,
                line: queueLine,
                actionTitle: Copy.Conversation.transcribeNow
            ) {
                Task {
                    try? await AskLibraryDataSources.current.conversations.transcribeNow(
                        id: conversationId)
                    await load()
                }
            }
        case .transcribing(let progress, let line):
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusDot(color: Tokens.tint, size: .lifecycle)
                        Text(Copy.Conversation.transcribing)
                            .font(AppFont.cardHead)
                            .foregroundStyle(Tokens.label)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tokens.fieldFill)
                            Capsule().fill(Tokens.tint)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    Text(line)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
            }
        case .failed:
            stateCard(
                dot: Tokens.attention,
                headline: Copy.Conversation.didntFinish,
                line: Copy.Conversation.didntFinishLine,
                actionTitle: Copy.Conversation.retryNow
            ) {
                Task {
                    try? await AskLibraryDataSources.current.conversations.retryNow(
                        id: conversationId)
                    await load()
                }
            }
        }
    }

    private func stateCard(
        dot: Color, headline: String, line: String, actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatusDot(color: dot, size: .lifecycle)
                    Text(headline)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                }
                Text(line)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                Button(action: action) {
                    Text(actionTitle)
                        .font(AppFont.smallButton)
                        .foregroundStyle(Tokens.tint)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Tokens.tintBorder))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Bottom bar [Ask][Notes][Follow-ups]

    private var bottomBar: some View {
        HStack(spacing: 10) {
            ActionPill(
                title: Copy.Conversation.ask, systemImage: "sparkles", style: .filled
            ) {
                let title = model.display?.title ?? ""
                router.askSheet = .ask(
                    scope: AskScope.conversation(id: conversationId, title: title).routeKey,
                    query: nil)
            }
            ActionPill(title: Copy.Conversation.notes) { openNotes() }
            ActionPill(title: Copy.Conversation.followUps) { model.showFollowUps = true }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.bottom, 8)
        .background(Tokens.barBg)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.barHairline).frame(height: 0.5)
        }
    }

    /// Plan 6.9: existing notes open directly; otherwise the template sheet.
    private func openNotes() {
        Task {
            let notes = (try? await AskLibraryDataSources.current.notes.notes(
                conversationId: conversationId)) ?? []
            if let first = notes.first {
                router.libraryPath.append(Route.note(id: first.id))
            } else {
                model.showTemplates = true
            }
        }
    }
}

// MARK: - View model

@MainActor
@Observable
final class ConversationViewModel {
    var display: ConversationDisplay?
    var renameTurn: TranscriptTurn?
    var showTagEditor = false
    var showTemplates = false
    var showFollowUps = false
    var showRename = false
    var renameDraft = ""
    var confirmExport = false
    var confirmDelete = false
    /// Inline action result (B10 — actions always show progress and a result).
    var actionResult: String?

    func load(id: String) async {
        display = try? await AskLibraryDataSources.current.conversations.display(id: id)
    }

    func exportAudio(id: String) {
        actionResult = "Exporting…"
        Task {
            do {
                try await AskLibraryDataSources.current.conversations.exportAudio(id: id)
                actionResult = Copy.Settings.Storage.exported(1)
            } catch {
                actionResult = nil
            }
            try? await Task.sleep(for: .seconds(4))
            actionResult = nil
        }
    }
}

// MARK: - Follow-ups sheet (conversation bottom bar)

struct FollowUpsSheet: View {
    let conversationId: String
    @Environment(\.dismiss) private var dismiss
    @State private var followUps: [FollowUp] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetGrabber()
            SheetTitleRow(title: Copy.Conversation.followUps) {
                Button(Copy.Common.done) { dismiss() }
                    .font(AppFont.headline)
                    .foregroundStyle(Tokens.tint)
                    .buttonStyle(.plain)
            }

            if loaded, followUps.isEmpty {
                Text(Copy.Empty.followUpsAllDone)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            } else if !followUps.isEmpty {
                ListCard(rowVerticalPadding: 11) {
                    ForEach(followUps, id: \.id) { followUp in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Button {
                                Haptics.checkedOff()
                                toggle(followUp)
                            } label: {
                                Image(systemName: followUp.done
                                    ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .light))
                                    .foregroundStyle(
                                        followUp.done ? Tokens.tint : Tokens.chevron)
                                    .hitTarget()
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, -10)
                            .accessibilityLabel(followUp.text)
                            .accessibilityValue(followUp.done
                                ? Copy.A11y.followUpDone : Copy.A11y.followUpNotDone)
                            .accessibilityHint(Copy.A11y.followUpHint)
                            Text(followUp.text)
                                .font(AppFont.subBody)
                                .foregroundStyle(Tokens.label)
                                .strikethrough(followUp.done, color: Tokens.meta)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityHidden(true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.screenMargin)
        .background(Tokens.ground)
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.hidden)
        .task { await reload() }
    }

    private func reload() async {
        let display = try? await AskLibraryDataSources.current.conversations.display(
            id: conversationId)
        followUps = display?.followUps ?? []
        loaded = true
    }

    private func toggle(_ followUp: FollowUp) {
        Task {
            try? await AskLibraryDataSources.current.conversations.toggleFollowUp(
                id: followUp.id)
            await reload()
        }
    }
}

#Preview("Conversation") {
    NavigationStack {
        ConversationScreen(conversationId: "planning-work")
    }
    .environment(AppRouter())
    .tint(Tokens.tint)
}

#Preview("Lifecycle: waiting") {
    NavigationStack {
        ConversationScreen(conversationId: "evening-home")
    }
    .environment(AppRouter())
    .tint(Tokens.tint)
}
