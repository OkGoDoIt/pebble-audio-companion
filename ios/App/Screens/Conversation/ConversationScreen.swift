import SwiftUI
import AppDB

/// Conversation detail (mockup 2.6 + States · Conversation): the system navigation bar
/// (its back button names whichever parent pushed us — Today or Library — and the title
/// fades in once the header scrolls away), header (title / meta / summary /
/// editable-on-tap tags), player card, lifecycle state cards, speaker-colored transcript
/// with inline markers, and the [Ask][Notes][Follow-ups] bottom bar. No tab bar.
///
/// Playing a recording turns the screen into a follow-along: the player pins under the
/// navigation bar once the header scrolls past, the transcript highlights the word being
/// spoken and scrolls to keep it in view, and a tap on the words moves the audio to them.
/// None of that is on when nothing is playing — the screen is a reading surface first.
struct ConversationScreen: View {
    let conversationId: String
    var atMs: Int64?
    /// The stretch a Saved Notes / Ask chip sent us to: the transcript scrolls to it, bands
    /// those lines, and offers to play from there. Nil on every ordinary open.
    var focus: TranscriptFocus?

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
    /// True once the header has scrolled off the top, which is when a playing player is pinned
    /// and needs a bar behind it rather than the page colour. Only ever true while playing —
    /// `pinnedViews` is empty otherwise, so nothing is docked to dress.
    @State private var headerScrolledPast = false
    /// Whether the transcript is still keeping up with the audio. Starts armed, switches off
    /// the moment the reader scrolls, and comes back on a tap or on pressing play.
    @State private var following = true

    private var playerDocked: Bool { player.isEngaged && headerScrolledPast }

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
            TemplateSheet(
                conversationId: conversationId,
                conversationTitle: model.display?.title
            ) { note in
                model.showTemplates = false
                router.push(.note(id: note.id))
            }
        }
        .sheet(isPresented: $model.showFollowUps, onDismiss: { Task { await load() } }) {
            FollowUpsSheet(conversationId: conversationId)
        }
        .sheet(isPresented: $model.showBoundaries) {
            ConversationBoundaryEditor(
                startReason: model.boundaries.startReason,
                canJoinWithPrevious: model.boundaries.canJoinWithPrevious,
                isJoinedWithPrevious: model.boundaries.isJoinedWithPrevious,
                points: model.boundaries.points,
                onToggleJoinWithPrevious: { on in
                    Task { await model.setJoinWithPrevious(id: conversationId, on: on) }
                },
                onToggleSplit: { segmentId, on in
                    Task { await model.setSplit(conversationId: conversationId, segmentId: segmentId, on: on) }
                },
                onDone: { model.showBoundaries = false }
            )
            .presentationDetents([.medium, .large])
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
                // A `Section` header rather than an overlay or a `safeAreaInset`, so the player
                // pins as the very view it already is: no second copy fading in, no scroll
                // inset appearing under the content and shoving it down. `pinnedViews` is empty
                // until somebody actually plays something, which is the whole
                // conditional-sticky rule — a docked player above a transcript nobody is
                // listening to is just a smaller screen. (`isEngaged`, not `playing`: the pause
                // button lives inside the docked player, and un-docking on pause would take it
                // away at the moment it was pressed.)
                //
                // The horizontal margin moved off the stack and onto each block because the
                // pinned header needs a full-bleed background behind it; the card inside keeps
                // exactly the insets it had.
                LazyVStack(
                    alignment: .leading, spacing: Tokens.blockGap,
                    pinnedViews: player.isEngaged ? [.sectionHeaders] : []
                ) {
                    header(display)
                        .padding(.horizontal, Tokens.screenMargin)
                    Section {
                        blocks(display)
                    } header: {
                        playerHeader(display)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, Tokens.blockGap)
            }
            // The reader's hand always wins. Once they scroll, playback stops moving the view
            // under them and offers a way back instead (the Podcasts / Music-lyrics contract).
            // `.interacting` is the drag itself — `.animating` is our own scrollTo, and keying
            // on that would switch following off the moment it turned on.
            .onScrollPhaseChange { _, phase, _ in
                guard phase == .interacting, following else { return }
                withAnimation(Motion.animation(.snappy(duration: 0.25))) { following = false }
            }
            .onChange(of: player.playhead.turnId) { _, turnId in
                followPlayhead(proxy, turnId: turnId)
            }
            // Starting playback is an explicit "take me along", so it re-arms following even if
            // the reader had scrolled off earlier.
            .onChange(of: player.playing) { _, playing in
                guard playing, !following else { return }
                withAnimation(Motion.animation(.snappy(duration: 0.25))) { following = true }
            }
            // An inset rather than an overlay: the scroll view's own safe area already excludes
            // the [Ask][Notes][Follow-ups] bar, so this lands above it, and the last line of the
            // transcript is never left underneath the pill.
            .safeAreaInset(edge: .bottom, spacing: 0) { backToPlaying(proxy) }
            .onAppear { scrollToCitedMoment(proxy, transcript: display.transcript) }
        }
    }

    /// Everything below the player. Its own function only because it is the `Section` content
    /// and a `ViewBuilder` reads better than a nested closure this long.
    @ViewBuilder
    private func blocks(_ display: ConversationDisplay) -> some View {
        lifecycleCard(display.lifecycle)
            .padding(.horizontal, Tokens.screenMargin)
        if !display.transcript.isEmpty {
            TranscriptView(
                transcript: display.transcript,
                provenance: display.provenance,
                timeZone: display.timeZone,
                focus: focus,
                onSpeakerTap: { turn in model.renameTurn = turn },
                // Playing is always the user's move: arriving from a citation cues the
                // scrubber to the moment, and this is the tap that starts it. A double tap
                // on the words is the same move.
                onPlayFrom: display.player == nil
                    ? nil : { mediaMs in player.play(fromMs: mediaMs) },
                // A single tap moves the scrubber and leaves the transport alone: reading
                // along and jumping about is not the same act as starting the audio.
                onSeekTo: display.player == nil
                    ? nil : { mediaMs in player.seek(positionMs: mediaMs) },
                playhead: display.player == nil ? nil : player.playhead
            )
            .padding(.horizontal, Tokens.screenMargin)
        }
        if let result = model.actionResult {
            Text(result)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Tokens.screenMargin)
        }
    }

    /// The player, plus the opaque strip it needs once it is pinned.
    ///
    /// The card's own geometry never changes between the two states — same insets, same
    /// controls, same size — so docking cannot make anything jump or shift under the finger.
    /// All that changes is the strip behind it: page-coloured (invisible) inline, bar-coloured
    /// with a hairline once content is passing underneath.
    @ViewBuilder
    private func playerHeader(_ display: ConversationDisplay) -> some View {
        if display.player != nil {
            PlayerCard(model: player)
                .padding(.horizontal, Tokens.screenMargin)
                .padding(.vertical, 6)
                .background(playerDocked ? Tokens.barBg : Tokens.ground)
                .overlay(alignment: .bottom) {
                    if playerDocked {
                        Rectangle().fill(Tokens.barHairline).frame(height: 0.5)
                    }
                }
                .animation(Motion.animation(.easeInOut(duration: 0.18)), value: playerDocked)
        }
    }

    /// Offered only while the audio has run on somewhere the reader can no longer see. Cheap,
    /// one tap, and it leaves the transcript where it is until they ask.
    @ViewBuilder
    private func backToPlaying(_ proxy: ScrollViewProxy) -> some View {
        if !following, player.playhead.isPlaying, let turnId = player.playhead.turnId {
            Button {
                withAnimation(Motion.animation(.snappy(duration: 0.25))) { following = true }
                followPlayhead(proxy, turnId: turnId)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                    Text(Copy.Playback.backToPlaying)
                        .font(AppFont.smallButton)
                }
                .foregroundStyle(Tokens.onTint)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Capsule().fill(Tokens.tint))
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
            .accessibilityHint(Copy.Playback.backToPlayingHint)
            .transition(Motion.transition(.move(edge: .bottom).combined(with: .opacity)))
        }
    }

    /// Keeps the paragraph being spoken on screen, a little above centre so there is something
    /// to read ahead into.
    private func followPlayhead(_ proxy: ScrollViewProxy, turnId: String?) {
        guard following, player.playhead.isPlaying, let turnId else { return }
        withAnimation(Motion.animation(.easeInOut(duration: 0.35))) {
            proxy.scrollTo(turnId, anchor: UnitPoint(x: 0, y: 0.34))
        }
    }

    /// Land on the cited stretch rather than at the top of a long transcript — the chip named
    /// a moment, so the moment is what should be on screen.
    private func scrollToCitedMoment(_ proxy: ScrollViewProxy, transcript: [TranscriptItem]) {
        guard let focus, !didScrollToCited else { return }
        let present = transcript.contains { item in
            if case .turn(let turn) = item {
                return focus.contains(segmentId: turn.segmentId, at: turn.startedAt)
            }
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
        guard let display = model.display else { return }
        // Re-indexed on every reload, not just the first: a re-transcribe replaces the words
        // under a conversation that may still be playing, and a playhead pointing into the old
        // transcript would light up whichever paragraph happened to inherit the id.
        player.loadTranscript(display.transcript)
        guard let playerDisplay = display.player else { return }
        // `configure` is a no-op once this conversation's engine is attached, so the reloads
        // after a rename or a tag edit never interrupt playback.
        var engine: (any ConversationPlayback)?
        if player.needsEngine(for: conversationId) {
            engine = try? await AskLibraryDataSources.current.conversations.playback(
                id: conversationId)
        }
        player.configure(playerDisplay, atMs: atMs, id: conversationId, engine: engine)
        // The scrubber names clock times, so it needs the same media->wall mapping the transcript
        // already carries on every turn, in the same recorded zone the stamps use (Q16).
        player.wallTimeZone = display.timeZone
        player.wallAnchors = display.transcript.compactMap { item in
            guard case .turn(let turn) = item, let mediaMs = turn.mediaOffsetMs,
                let startedAt = turn.startedAt
            else { return nil }
            return (mediaMs: mediaMs, wall: startedAt)
        }
        .sorted { $0.mediaMs < $1.mediaMs }
        player.wallStart = display.startedAt
        player.wallEnd = display.endedAt
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
            // Why this conversation starts where it does. Grouping is automatic, so without
            // this a split that surprised someone has no explanation anywhere in the app — and
            // no visible way to overrule it.
            ConversationStartCaption(startReason: model.boundaries.startReason)
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
        // The player sits immediately below this block, so the header clearing the top of the
        // scroll view is the moment a playing player is pinned. Reported as a Bool, not a
        // coordinate: an `onGeometryChange` that publishes a `CGFloat` fires on every scroll
        // frame, and this has to cost nothing while somebody is reading.
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .scrollView).maxY < 0
        } action: { past in
            headerScrolledPast = past
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
            Button(Copy.Boundaries.menuItem) {
                Task { await model.loadBoundaries(id: conversationId) }
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
                router.navigate(
                    to: .ask(
                        scope: AskScope.conversation(id: conversationId, title: title).routeKey,
                        query: nil))
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
    /// Always the template sheet. It used to open the FIRST EXISTING note instead whenever one
    /// existed, which quietly made [Notes] a one-shot button: a conversation that already had
    /// Meeting notes could never reach any other template from the bottom bar — you had to open
    /// the old note and find the "+" in ITS bar. Adding Extended summary is what made that
    /// unignorable, but it was always wrong: the sheet is the menu, and a menu you can only see
    /// once is not a menu.
    ///
    /// Existing notes are not lost by this — the sheet lists them above the templates.
    private func openNotes() {
        model.showTemplates = true
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
    var showBoundaries = false
    /// Loaded with the conversation so the start caption can render under the title, and
    /// reloaded when the sheet writes a decision.
    var boundaries: ConversationBoundariesDisplay = .none
    /// Inline action result (B10 — actions always show progress and a result).
    var actionResult: String?

    func load(id: String) async {
        display = try? await AskLibraryDataSources.current.conversations.display(id: id)
        loaded = true
        boundaries =
            (try? await AskLibraryDataSources.current.conversations.boundaries(id: id)) ?? .none
    }

    /// Opens the sheet on fresh values rather than whatever the last load left behind — a
    /// regroup elsewhere can have moved the members since.
    func loadBoundaries(id: String) async {
        boundaries =
            (try? await AskLibraryDataSources.current.conversations.boundaries(id: id)) ?? .none
        showBoundaries = true
    }

    /// `conversationId` is the screen's, for the reload — the write itself is keyed only by the
    /// segment that would start the new conversation.
    func setSplit(conversationId: String, segmentId: String, on: Bool) async {
        try? await AskLibraryDataSources.current.conversations.setSplit(
            atSegmentId: segmentId, on: on)
        await loadBoundariesKeepingSheet(id: conversationId)
    }

    func setJoinWithPrevious(id: String, on: Bool) async {
        try? await AskLibraryDataSources.current.conversations.setJoinWithPrevious(
            conversationId: id, on: on)
        await loadBoundariesKeepingSheet(id: id)
    }

    /// A write regroups, which can move this conversation's members — or dissolve it into the
    /// previous one. Re-reading keeps the switches showing what is actually stored, and never
    /// closes the sheet under the person who is still deciding.
    private func loadBoundariesKeepingSheet(id: String) async {
        boundaries =
            (try? await AskLibraryDataSources.current.conversations.boundaries(id: id)) ?? .none
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

/// This conversation's follow-ups, in the shape iOS already has for a short editable list:
/// navigation chrome, a real `List`, swipe to delete, a row that opens.
///
/// The version this replaces was a fixed 430 pt `VStack` with no scroll view, so an eleventh
/// follow-up simply fell off the bottom; its rows toggled and did nothing else; and its empty
/// state said "All caught up." whether you had ticked everything off or the conversation had
/// never produced anything at all.
struct FollowUpsSheet: View {
    let conversationId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @State private var items: [FollowUpItem] = []
    @State private var loaded = false
    @State private var now = Date()

    private var source: any FollowUpsDataSource { AskLibraryDataSources.current.followUps }

    var body: some View {
        NavigationStack {
            Group {
                if loaded && items.isEmpty {
                    Text(Copy.FollowUps.conversationEmpty)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Tokens.ground)
                } else {
                    List {
                        ForEach(items) { item in
                            NavigationLink {
                                FollowUpDetailScreen(id: item.id) { target in
                                    // Out of the sheet first: pushing onto a tab stack from
                                    // inside a modal shows nothing and leaves a screen waiting
                                    // behind it.
                                    dismiss()
                                    router.navigate(
                                        to: .conversation(
                                            id: target.conversationId,
                                            atMs: target.mediaOffsetMs, focus: target.focus))
                                }
                            } label: {
                                FollowUpRow(item: item, now: now, showsChevron: false) {
                                    Haptics.checkedOff()
                                    toggle(item)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(item)
                                } label: {
                                    Label(Copy.FollowUps.delete, systemImage: "trash")
                                }
                                .tint(Tokens.destructive)
                            }
                            .listRowBackground(Tokens.surface)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Tokens.ground)
                    .animation(
                        Motion.animation(.snappy(duration: 0.25)),
                        value: items.map { "\($0.id)\($0.done)" }.joined())
                }
            }
            .navigationTitle(Copy.Conversation.followUps)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Common.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await reload() }
    }

    private func reload() async {
        now = Date()
        let all = (try? await source.items(scope: .open)) ?? []
        let completed = (try? await source.items(scope: .completed)) ?? []
        let archived = (try? await source.items(scope: .archived)) ?? []
        // The conversation's own screen shows everything it produced, including what has been
        // ticked or filed away: on this screen "where did the other one go?" is the question,
        // not "what is left to do today".
        items = (all + completed + archived)
            .filter { $0.sourceConversationId == conversationId }
        loaded = true
    }

    private func toggle(_ item: FollowUpItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].done.toggle()
        }
        Task {
            try? await source.setDone(id: item.id, done: !item.done)
            await reload()
        }
    }

    private func delete(_ item: FollowUpItem) {
        Haptics.destructiveConfirmed()
        items.removeAll { $0.id == item.id }
        Task {
            try? await source.delete(id: item.id)
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
