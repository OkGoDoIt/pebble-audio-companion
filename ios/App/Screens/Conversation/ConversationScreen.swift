import SwiftUI
import AppDB

/// Conversation detail (mockup 2.6 + States · Conversation): the system navigation bar
/// (its back button names whichever parent pushed us — Today or Library — and the title
/// fades in once the header scrolls away), header (title / meta / summary /
/// editable-on-tap tags), player card, lifecycle state cards, speaker-colored transcript
/// with inline markers, and the [Ask][Notes][Follow-ups] bottom bar. No tab bar.
struct ConversationScreen: View {
    let conversationId: String
    var atMs: Int64?
    /// The cited member a Saved Notes / Ask chip sent us to: the transcript scrolls to it,
    /// bands it, and offers to play from there. Nil on every ordinary open.
    var focusSegmentId: String?

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model = ConversationViewModel()
    @State private var player = PlayerModel()
    /// True once the in-content title has scrolled under the navigation bar, which is when
    /// the bar takes the title over (Mail/Podcasts behavior — never both at once).
    @State private var titleInBar = false
    /// One jump per arrival: re-scrolling on every reload (rename, tag edit, retranscribe)
    /// would yank the screen back under the user mid-read.
    @State private var didScrollToCited = false

    var body: some View {
        Group {
            if let display = model.display {
                content(display)
            } else {
                placeholder
            }
        }
        .background(Tokens.ground)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(titleInBar ? (model.display?.title ?? "") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .safeAreaInset(edge: .bottom) {
            if model.display != nil { bottomBar }
        }
        .task(id: conversationId) { await load() }
        // Stay live while it is open. A conversation opened straight from Today is usually
        // still being transcribed and has no title yet; without this the transcript, the AI
        // title and summary, and the follow-ups all land invisibly and the screen only catches
        // up if you navigate away and back.
        .task(id: conversationId) {
            for await _ in AskLibraryDataSources.current.conversations.updates(
                conversationId: conversationId)
            {
                await load()
            }
        }
        .onDisappear { player.stop() }
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
                router.push(.note(id: note.id))
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

    // MARK: - Content

    private func content(_ display: ConversationDisplay) -> some View {
        ScrollViewReader { proxy in
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
                        provenance: display.provenance,
                        timeZone: display.timeZone,
                        focusSegmentId: focusSegmentId,
                        onSpeakerTap: { turn in model.renameTurn = turn },
                        // Playing is always the user's move: arriving from a citation cues the
                        // scrubber to the moment, and this is the tap that starts it.
                        onPlayFrom: display.player == nil
                            ? nil
                            : { offsetMs in
                                player.seek(positionMs: offsetMs)
                                if !player.playing { player.togglePlay() }
                            }
                    )
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
        .onAppear { scrollToCitedMoment(proxy, transcript: display.transcript) }
        }
    }

    /// Land on the cited stretch rather than at the top of a long transcript — the chip named
    /// a moment, so the moment is what should be on screen.
    private func scrollToCitedMoment(_ proxy: ScrollViewProxy, transcript: [TranscriptItem]) {
        guard let focusSegmentId, !didScrollToCited else { return }
        let present = transcript.contains { item in
            if case .turn(let turn) = item { return turn.segmentId == focusSegmentId }
            return false
        }
        guard present else { return }
        didScrollToCited = true
        Task { @MainActor in
            // One frame after the transcript is laid out; scrolling into a card that does not
            // have its height yet lands short.
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(Motion.animation(.easeOut(duration: 0.25))) {
                proxy.scrollTo(TranscriptView.citedAnchor, anchor: .center)
            }
        }
    }

    /// Loading and not-found. Neither used to exist: a slow (or missing) conversation left
    /// the screen completely blank under the nav bar with no way to tell which it was.
    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 10) {
            if model.loaded {
                Text(Copy.Conversation.unavailable)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .tint(Tokens.meta)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Tokens.screenMargin)
    }

    // MARK: - Navigation bar
    //
    // The system bar draws itself (iOS 26 Liquid Glass, the scroll-edge effect, and the
    // ≥44 pt hit regions); these items only say what goes in it. The back button is the
    // system's, so it names the ACTUAL parent — the hand-rolled bar it replaced took an
    // `originLabel` parameter that Today never passed, and Today never reached this screen
    // at all.

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if let shareText = model.display?.shareText {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Copy.A11y.share)
            }
        }
        if model.display != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ellipsisMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(Copy.A11y.more)
            }
        }
    }

    private func load() async {
        await model.load(id: conversationId)
        guard let display = model.display, let playerDisplay = display.player else { return }
        // `configure` is a no-op once this conversation's engine is attached, so the reloads
        // after a rename or a tag edit never interrupt playback.
        var engine: (any ConversationPlayback)?
        if player.needsEngine(for: conversationId) {
            engine = try? await AskLibraryDataSources.current.conversations.playback(
                id: conversationId)
        }
        player.configure(playerDisplay, atMs: atMs, id: conversationId, engine: engine)
    }

    // MARK: - Header

    private func header(_ display: ConversationDisplay) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(display.title)
                .font(AppFont.detailTitle)
                .foregroundStyle(Tokens.label)
                .fixedSize(horizontal: false, vertical: true)
                // Hand-off point for the bar title: once this line's bottom edge passes
                // under the bar, the bar carries the title instead.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .scrollView).maxY
                } action: { maxY in
                    let shouldShow = maxY < 4
                    guard shouldShow != titleInBar else { return }
                    withAnimation(Motion.animation(.snappy)) { titleInBar = shouldShow }
                }
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
                    FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
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

    @ViewBuilder
    private var ellipsisMenuItems: some View {
        Group {
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
        // One calm line, one action — but the line now says WHAT went wrong when the queue
        // recorded it, instead of the same reassurance for a missing key and a lost connection.
        case .failed(let reason):
            stateCard(
                dot: Tokens.attention,
                headline: Copy.Conversation.didntFinish,
                line: reason ?? Copy.Conversation.didntFinishLine,
                actionTitle: Copy.Conversation.retryNow
            ) {
                Task {
                    try? await AskLibraryDataSources.current.conversations.retryNow(
                        id: conversationId)
                    await load()
                }
            }
        // Background AI. One calm line, no action, no bar — the transcript below is already
        // final, and this only explains the missing title/summary/tags.
        case .summaryComing:
            stateCard(
                dot: Tokens.captured,
                headline: Copy.Conversation.summaryComing,
                line: Copy.Conversation.summaryComingLine,
                actionTitle: nil,
                action: {}
            )
        case .noSummary(let gaveUp):
            stateCard(
                dot: Tokens.faint,
                headline: gaveUp ? Copy.Conversation.summaryGaveUp : Copy.Conversation.noSummary,
                line: gaveUp
                    ? Copy.Conversation.summaryGaveUpLine : Copy.Conversation.noSummaryLine,
                actionTitle: nil,
                action: {}
            )
        }
    }

    /// One calm line and at most one action. `actionTitle: nil` renders the state without a
    /// button — for background work there is nothing useful to press.
    private func stateCard(
        dot: Color, headline: String, line: String, actionTitle: String?,
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
                if let actionTitle {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(AppFont.smallButton)
                            .foregroundStyle(Tokens.tint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Tokens.tintBorder))
                            .frame(minHeight: 44)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Bottom bar [Ask][Notes][Follow-ups]

    private var bottomBar: some View {
        // Wraps onto extra rows at large Dynamic Type sizes instead of crushing the pills.
        FlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                router.push(.note(id: first.id))
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
    /// False until the first load finishes, so the screen can tell "still loading" from
    /// "there is no such conversation".
    var loaded = false
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
        loaded = true
    }

    func exportAudio(id: String) {
        actionResult = "Exporting…"
        Task {
            do {
                // The real file count: one WAV per member segment, so a conversation that
                // survived reconnects writes several. Reporting a hard-coded "1 file exported"
                // sent people to Files looking for a single recording that was actually four.
                let written = try await AskLibraryDataSources.current.conversations.exportAudio(
                    id: id)
                actionResult = Copy.Settings.Storage.exported(written)
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
