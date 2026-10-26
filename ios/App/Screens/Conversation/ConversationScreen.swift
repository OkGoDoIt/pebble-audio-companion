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
    /// Where the transcript lands on arrival. A citation's stretch (a Saved Notes / Ask chip)
    /// is scrolled to, banded and offered to play from; a moment (History) is scrolled to and
    /// nothing more. Nil on every ordinary open.
    var focus: TranscriptFocus?

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = ConversationViewModel()
    @State private var player = PlayerModel()
    /// The cold-audio fetch in progress, and why the last one failed. Both live on the screen:
    /// a fetch is a thing this screen asked for, and its outcome is shown where it was asked.
    @State private var fetchingAudio = false
    @State private var fetchError: String?
    /// Paragraphs picked for a speaker change, by turn id; nil when not picking.
    @State private var picked: Set<String>?
    @State private var clearingNames = false
    /// True once the in-content title has scrolled under the navigation bar, which is when
    /// the bar takes the title over (Mail/Podcasts behavior — never both at once).
    @State private var titleInBar = false
    /// One jump per arrival: re-scrolling on every reload (rename, tag edit, retranscribe)
    /// would yank the screen back under the user mid-read.
    @State private var didScrollToFocus = false
    /// True once the reader has dragged the transcript. The arrival's settling scroll stands
    /// down from then on.
    @State private var readerHasScrolled = false
    /// True once the header has scrolled off the top, which is when a playing player is pinned
    /// and needs a bar behind it rather than the page colour. Only ever true while playing —
    /// `pinnedViews` is empty otherwise, so nothing is docked to dress.
    @State private var headerScrolledPast = false
    /// Whether the transcript is still keeping up with the audio. Starts armed, switches off
    /// the moment the reader scrolls, and comes back on a tap or on pressing play.
    @State private var following = true
    /// Whether the end of the conversation is on screen. The ⌄ button is the negative of this
    /// and nothing else — see `ScrollToBottom`. Starts true so a screen that has not been
    /// measured yet stays quiet.
    @State private var isAtBottom = true
    /// Drives the ride to the bottom. A `ScrollPosition` asks the scroll view for its own bottom
    /// EDGE, which is why there is no longer a marker view at the end of the stack to aim at —
    /// see `scrollToBottom()`.
    @State private var scrollPosition = ScrollPosition()

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
        .task(id: "\(conversationId)-\(scenePhase)") {
            guard scenePhase == .active else { return }
            for await _ in AskLibraryDataSources.current.conversations.updates(
                conversationId: conversationId)
            {
                await load()
            }
        }
        .onDisappear { player.stop() }
        // iOS 27 on-screen awareness: the open conversation, as the scene's activity (no-op below 27).
        .conversationEntityAwareness(id: conversationId)
        .sheet(item: $model.renameTurns, onDismiss: { player.pause() }) { passages in
            SpeakerRenameSheet(conversationId: conversationId, turns: passages.turns,
                               onPlay: playback(of: passages.turns), onStop: { player.pause() }) {
                picked = nil
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
                joins: model.boundaries.joins,
                notice: model.boundaryNotice,
                timeZone: model.display?.timeZone ?? .current,
                onToggleJoinWithPrevious: { on in
                    Task { await model.setJoinWithPrevious(id: conversationId, on: on) }
                },
                onSplit: { point in
                    Task {
                        await model.split(
                            conversationId: conversationId, at: point,
                            timeZone: model.display?.timeZone ?? .current)
                    }
                },
                onSeparate: { point in
                    Task { await model.separate(conversationId: conversationId, at: point) }
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
            .scrollPosition($scrollPosition)
            // The reader's hand wins over PLAYBACK: once they scroll, the transcript stops
            // being moved under them and offers a way back instead (the Podcasts /
            // Music-lyrics contract). It does not affect the ⌄ button, which asks only where
            // the view is, never how it got there. `.interacting` is the drag itself —
            // `.animating` is our own scrollTo, and keying on that would switch following off
            // the moment it turned on.
            .onScrollPhaseChange { _, phase, _ in
                if phase == .interacting, !readerHasScrolled { readerHasScrolled = true }
                guard phase == .interacting, following else { return }
                withAnimation(Motion.animation(.snappy(duration: 0.25))) { following = false }
            }
            .onAtBottomChange { isAtBottom = $0 }
            .onChange(of: player.playhead.turnId) { _, turnId in
                followPlayhead(proxy, turnId: turnId)
            }
            // Starting playback is an explicit "take me along", so it re-arms following even if
            // the reader had scrolled off earlier.
            .onChange(of: player.playing) { _, playing in
                guard playing, !following else { return }
                withAnimation(Motion.animation(.snappy(duration: 0.25))) { following = true }
            }
            // "Back to playing" keeps its inset — it reports something, and pushing the last
            // line clear of it is right. The ⌄ floats instead: an inset would change the very
            // scroll geometry that decides whether to show it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                backToPlaying(proxy)
                    .motionAware(.snappy(duration: 0.25), value: showsBackToPlaying)
            }
            .overlay(alignment: .bottomTrailing) {
                if showsScrollToBottom {
                    ScrollToBottomButton { scrollToBottom() }
                }
            }
            .motionAware(.snappy(duration: 0.25), value: showsScrollToBottom)
            .onAppear { scrollToFocus(proxy, display: display) }
        }
    }

    /// Everything below the player. Its own function only because it is the `Section` content
    /// and a `ViewBuilder` reads better than a nested closure this long.
    @ViewBuilder
    private func blocks(_ display: ConversationDisplay) -> some View {
        lifecycleCard(display.lifecycle)
            .padding(.horizontal, Tokens.screenMargin)
        if !display.voiceMatches.isEmpty {
            ConversationVoiceMatchesCard(matches: display.voiceMatches,
                canPlay: display.player != nil && display.audioAvailability == .onPhone,
                onPlay: { player.play(fromMs: $0.playbackStartMs, untilMs: $0.playbackEndMs) },
                onStop: { player.pause() }, conversationId: conversationId,
                onChanged: { Task { await load() } })
                .padding(.horizontal, Tokens.screenMargin)
        }
        if !display.transcript.isEmpty {
            TranscriptView(
                transcript: display.transcript,
                provenance: display.provenance,
                timeZone: display.timeZone,
                focus: focus,
                onSpeakerTap: { turn in model.renameTurns = SpeakerPassages(turns: [turn]) },
                // Playing is always the user's move: arriving from a citation cues the
                // scrubber to the moment, and this is the tap that starts it. A double tap
                // on the words is the same move.
                onPlayFrom: display.player == nil
                    ? nil : { mediaMs in player.play(fromMs: mediaMs) },
                // A single tap moves the scrubber and leaves the transport alone: reading
                // along and jumping about is not the same act as starting the audio.
                onSeekTo: display.player == nil
                    ? nil : { mediaMs in player.seek(positionMs: mediaMs) },
                playhead: display.player == nil ? nil : player.playhead,
                selection: picked,
                onSelectRun: { run in pick(run) },
                onToggleTurn: { turn in toggle(turn) }
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
        if display.player != nil, display.audioAvailability != .onPhone {
            // The audio is in iCloud. Same place, same insets as the player it stands in for,
            // so fetching it swaps one card for the other without the page moving.
            CloudAudioCard(
                availability: display.audioAvailability,
                fetching: fetchingAudio,
                error: fetchError
            ) {
                fetchAudio()
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.vertical, 6)
        } else if display.player != nil {
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

    /// The ⌄ appears for one reason: the bottom of the conversation is not on screen.
    ///
    /// The single extra condition is playback, and it is not about the reader's intent — it is
    /// about who owns the corner. While audio runs, either the transcript is following the
    /// playhead (the view is already moving, so there is nothing to offer) or the reader has
    /// scrolled off it and "Back to playing" is the offer. Two floating buttons pointing at two
    /// different places is a worse screen than either alone.
    private var showsScrollToBottom: Bool {
        !isAtBottom && !player.playhead.isPlaying
    }

    private var showsBackToPlaying: Bool {
        !following && player.playhead.isPlaying && player.playhead.turnId != nil
    }

    /// Offered only while the audio has run on somewhere the reader can no longer see. Cheap,
    /// one tap, and it leaves the transcript where it is until they ask.
    @ViewBuilder
    private func backToPlaying(_ proxy: ScrollViewProxy) -> some View {
        if showsBackToPlaying, let turnId = player.playhead.turnId {
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

    /// The bottom EDGE of the scroll view, not a marker view near the bottom of the content.
    ///
    /// The version this replaces put a 1 pt `Color.clear` at the end of the stack and asked the
    /// proxy to scroll to it, and that landed short twice over. It sat ABOVE the stack's own
    /// trailing padding, so a perfect jump still left `Tokens.blockGap` below the fold; and
    /// `scrollTo` aims at an offset derived from the content size, which in a `LazyVStack` is
    /// part estimate — the rows below get their real heights as they are laid out, and the
    /// scroll settles short of where it was aiming. That is the "it stops with the provenance
    /// line still cut off, and a second press fixes it" report: by the second press everything
    /// is laid out and the estimate is exact. Asking for the edge asks the scroll view for its
    /// own maximum offset, which is exact whatever the content is doing.
    ///
    /// Taken as arriving straight away, so the button does not sit there through its own scroll
    /// animation; the next geometry reading confirms it either way.
    private func scrollToBottom() {
        isAtBottom = true
        withAnimation(Motion.animation(.easeOut(duration: 0.3))) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// A little above centre, so there is something to read ahead into: where the paragraph
    /// being spoken is kept, and where a moment's row is put on arrival.
    private static let readingLine = UnitPoint(x: 0, y: 0.34)

    /// Keeps the paragraph being spoken on screen at the reading line.
    private func followPlayhead(_ proxy: ScrollViewProxy, turnId: String?) {
        guard following, player.playhead.isPlaying, let turnId else { return }
        withAnimation(Motion.animation(.easeInOut(duration: 0.35))) {
            proxy.scrollTo(turnId, anchor: Self.readingLine)
        }
    }

    /// Land where the link pointed rather than at the top of a long transcript.
    ///
    /// A citation lands on its band, centred, and only when the band exists — a row inside the
    /// stretch. A moment lands on the row it would be reading at that time
    /// (`MomentResolver.rowIndex`), which exists in a gap too: the last row before the gap.
    private func scrollToFocus(_ proxy: ScrollViewProxy, display: ConversationDisplay) {
        guard let focus, !didScrollToFocus else { return }
        let transcript = display.transcript
        // The same rows the transcript draws: scroll targets have to be ROW ids, because a lazy
        // stack can only find a row it has not built yet by the id its `ForEach` knows it by.
        let layout = TranscriptLayout(
            transcript: transcript, provenance: display.provenance, focus: focus)
        let target: String
        let anchor: UnitPoint
        switch focus.style {
        case .citation:
            guard let band = layout.citedRowId else { return }
            target = band
            anchor = .center
        case .moment:
            guard let wallMs = focus.startMs,
                let row = MomentResolver.rowIndex(in: transcript, atWallMs: wallMs)
            else { return }
            target = layout.rowId(forItemId: transcript[row].id)
            anchor = Self.readingLine
        }
        didScrollToFocus = true
        Task { @MainActor in
            // A beat after the first rows are laid out; aiming before the stack has measured
            // anything lands short.
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(Motion.animation(.easeOut(duration: 0.25))) {
                proxy.scrollTo(target, anchor: anchor)
            }
            // One settling request. The transcript is a lazy stack, so a far scroll is aimed
            // through rows it has only estimated. Mid-transcript it lands anyway (measured on a
            // 6,000-row day: the row settles at the reading line as the ride ends), but near the
            // end the estimate of what lies below runs long and the ride stopped ~115 pt short
            // of the bottom. By now the rows around the target are real, and asking again lands.
            // Not once the reader has taken the scroll: that would yank it back from under them.
            //
            // The ride stays animated even thousands of rows away. An instant jump avoids
            // building the rows the animation passes (a ~0.14 s stall as it arrives), but near
            // the end it stranded the view short of the target, and settling sooner after it
            // left the view further off still.
            try? await Task.sleep(for: .milliseconds(400))
            guard !readerHasScrolled else { return }
            proxy.scrollTo(target, anchor: anchor)
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

    /// Brings the audio back from iCloud, then reloads: the display's availability flips to
    /// `.onPhone`, the player appears, and `load()` attaches the engine as it always does.
    private func fetchAudio() {
        guard !fetchingAudio else { return }
        fetchingAudio = true
        fetchError = nil
        Task {
            do {
                try await AskLibraryDataSources.current.conversations.fetchAudio(id: conversationId)
            } catch {
                fetchError = Copy.Conversation.fetchFailed(describing: error)
            }
            fetchingAudio = false
            await load()
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
        // The Lock Screen / Control Center item, named the way the header names it.
        player.nowPlaying = AppComposition.shared?.nowPlaying
        player.describe(title: display.title, subtitle: display.metaLine)
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

    @ViewBuilder private var bottomBar: some View {
        if let picked { pickBar(picked) } else { actionBar }
    }

    /// While paragraphs are picked, the bar is about them: how many, and what to do.
    private func pickBar(_ picked: Set<String>) -> some View {
        let turns = pickedTurns
        let named = turns.contains { $0.role != .unresolved }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(turns.isEmpty ? "Tap paragraphs to select them"
                     : turns.count == 1 ? "1 paragraph selected" : "\(turns.count) paragraphs selected")
                    .font(AppFont.footnote.monospacedDigit()).foregroundStyle(Tokens.meta)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(Copy.Common.cancel) { self.picked = nil }
                    .font(AppFont.callout).foregroundStyle(Tokens.tint).fixedSize()
            }
            FlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                ActionPill(title: "Change speaker", systemImage: "person.crop.circle", style: .filled) {
                    player.pause()
                    model.renameTurns = SpeakerPassages(turns: turns)
                }.disabled(turns.isEmpty || clearingNames)
                if named {
                    ActionPill(title: "Clear name") { clearNames(turns) }
                        .disabled(clearingNames)
                }
                let whole = wholeSpeaker(of: turns)
                if whole.count > turns.count {
                    ActionPill(title: "All by this speaker (\(whole.count))") {
                        Haptics.checkedOff()
                        self.picked = Set(whole.map(\.id))
                    }.disabled(clearingNames)
                }
            }
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

    private var actionBar: some View {
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
        // Inside the background, so the note-job card is drawn over this bar's own strip rather
        // than over the pills: the bar grows by exactly the card's height and its colour carries
        // on behind it, and the two read as one bottom assembly instead of a card floating on
        // the transcript. Because this bar is a safe-area inset, the transcript's last line
        // comes up with it.
        .noteJobDockClearance()
        .background(Tokens.barBg)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.barHairline).frame(height: 0.5)
        }
    }

    // MARK: - Picking paragraphs for a speaker change

    /// The picked paragraphs, in transcript order.
    private var pickedTurns: [TranscriptTurn] {
        guard let picked, let transcript = model.display?.transcript else { return [] }
        return transcript.compactMap { item in
            if case .turn(let turn) = item, picked.contains(turn.id) { return turn }
            return nil
        }
    }

    /// Every paragraph the transcription service gave the same speaker as the picked ones, in
    /// the same recording (its numbering restarts with each recording), that still has the same
    /// name: a paragraph already named differently is a decision this must not overwrite.
    private func wholeSpeaker(of turns: [TranscriptTurn]) -> [TranscriptTurn] {
        Self.wholeSpeaker(of: turns, in: model.display?.transcript ?? [])
    }

    static func wholeSpeaker(of turns: [TranscriptTurn], in transcript: [TranscriptItem]) -> [TranscriptTurn] {
        guard let first = turns.first, !first.speakerLabel.isEmpty,
              turns.allSatisfy({ $0.segmentId == first.segmentId && $0.speakerLabel == first.speakerLabel
                  && $0.personId == first.personId }) else { return [] }
        return transcript.compactMap { item in
            guard case .turn(let turn) = item, turn.canIdentifyPassage, turn.segmentId == first.segmentId,
                  turn.speakerLabel == first.speakerLabel, turn.personId == first.personId else { return nil }
            return turn
        }
    }

    /// A speaker's run: picks all of it, or unpicks it when it is already all picked.
    private func pick(_ run: [TranscriptTurn]) {
        guard !run.isEmpty else { return }
        var set = picked ?? []
        let ids = Set(run.map(\.id))
        if ids.isSubset(of: set) { set.subtract(ids) } else { set.formUnion(ids) }
        Haptics.checkedOff()
        picked = set
    }

    private func toggle(_ turn: TranscriptTurn) {
        guard turn.canIdentifyPassage else { return }
        Haptics.checkedOff()
        var set = picked ?? []
        if set.remove(turn.id) == nil { set.insert(turn.id) }
        picked = set
    }

    /// Leaves the picked paragraphs unnamed. Kept as a decision, so voice recognition won't
    /// name them again.
    private func clearNames(_ turns: [TranscriptTurn]) {
        clearingNames = true
        Task {
            defer { clearingNames = false }
            do {
                for turn in turns {
                    try await AskLibraryDataSources.current.people.assignPassage(turn, personId: nil, makeCurrentUser: false)
                }
                picked = nil
                UndoCenter.shared.snackbar = SnackbarItem(
                    message: turns.count == 1 ? "Name cleared" : "Names cleared from \(turns.count) paragraphs")
            } catch {
                UndoCenter.shared.snackbar = SnackbarItem(message: Copy.Speaker.saveFailed)
            }
            await load()
        }
    }

    /// Plays the picked stretch, from the first paragraph's start to the last one's end.
    private func playback(of turns: [TranscriptTurn]) -> (() -> Void)? {
        guard model.display?.audioAvailability == .onPhone, model.display?.player != nil,
              let first = turns.first, let start = first.identificationMediaOffsetMs ?? first.mediaOffsetMs
        else { return nil }
        let end = turns.last.flatMap { $0.identificationMediaEndMs ?? $0.mediaEndMs }
        return {
            if let end, end > start { player.play(fromMs: start, untilMs: end) } else { player.play(fromMs: start) }
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
    var renameTurns: SpeakerPassages?
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
    /// What the last split did, for the sheet to say under its list: the row that was tapped
    /// leaves it (that place now starts another conversation), and a list that silently gets
    /// shorter reads as a tap that did nothing.
    var boundaryNotice: String?
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
        boundaryNotice = nil
        boundaries =
            (try? await AskLibraryDataSources.current.conversations.boundaries(id: id)) ?? .none
        showBoundaries = true
    }

    /// `conversationId` is the screen's, for the reload — the write itself is keyed only by the
    /// position the new conversation starts at.
    func split(
        conversationId: String, at point: ConversationBoundaryPoint, timeZone: TimeZone
    ) async {
        do {
            try await AskLibraryDataSources.current.conversations.split(at: point.cut)
            // Q16: in the zone the conversation was recorded in, like every stamp beside it.
            boundaryNotice = Copy.Boundaries.didSplit(
                at: point.startedAt.formatted(
                    Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)))
        } catch {
            boundaryNotice = nil
        }
        await loadBoundariesKeepingSheet(id: conversationId)
    }

    func setJoinWithPrevious(id: String, on: Bool) async {
        boundaryNotice = nil
        try? await AskLibraryDataSources.current.conversations.setJoinWithPrevious(
            conversationId: id, on: on)
        await loadBoundariesKeepingSheet(id: id)
    }

    /// Takes back a join the person made inside this conversation.
    func separate(conversationId: String, at point: ConversationBoundaryPoint) async {
        boundaryNotice = nil
        try? await AskLibraryDataSources.current.conversations.separate(at: point.cut)
        await loadBoundariesKeepingSheet(id: conversationId)
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
                                StagedFollowUpRow(item: item, now: now) { remind(item) }
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
                        value: items.map { "\($0.id)\($0.done)\($0.stage)" }.joined())
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
        // The conversation's own screen shows everything it produced — waiting for review,
        // skipped, ticked, filed away: on this screen "where did the other one go?" is the
        // question, not "what is left to do today". In the order it was said.
        items = ((try? await source.items(conversationId: conversationId)) ?? [])
            .sorted { $0.said < $1.said }
        loaded = true
    }

    /// "Remind Me" on one waiting for review, or one skipped: a reminder now, out of the review.
    private func remind(_ item: FollowUpItem) {
        Haptics.checkedOff()
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].stage = .reminder
        }
        Task {
            try? await source.setStage(id: item.id, stage: .reminder)
            if item.dueAtMs != nil {
                await ReminderHomeSources.current.askForAlertPermissionIfNeeded()
            }
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

/// One of a conversation's follow-ups, with where it stands at the trailing edge: "✓ Reminder"
/// once it is one, and "Remind Me" while it waits for review or after it was skipped.
private struct StagedFollowUpRow: View {
    let item: FollowUpItem
    let now: Date
    let remind: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(AppFont.callout)
                    .foregroundStyle(item.done ? Tokens.meta : Tokens.label)
                    .strikethrough(item.done, color: Tokens.meta)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if item.stage == .reminder {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    Text(Copy.Reminders.stateReminder).font(AppFont.smallButton)
                }
                .foregroundStyle(Tokens.tint)
                .fixedSize()
                .accessibilityElement(children: .combine)
            } else {
                Button(action: remind) {
                    Text(Copy.Reminders.remindMeButton)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.tint)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(Tokens.tintFill12))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
    }

    /// Done or filed away when it is; otherwise when it was said.
    private var meta: String {
        if item.done || item.isArchived,
            let line = FollowUpFormatting.metaLine(item, now: now)?.text
        {
            return line
        }
        return TimeFmt.time(item.said)
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

/// The passages a "Who's speaking?" sheet is naming.
struct SpeakerPassages: Identifiable {
    let turns: [TranscriptTurn]
    var id: String { turns.map(\.id).joined(separator: "|") }
}
