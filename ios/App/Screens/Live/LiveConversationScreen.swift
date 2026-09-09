import SwiftUI

/// Live Conversation (LiveDetail artboard, extraction §2.17): back "Today", "Recording now"
/// header with the Live badge, the growing timeline, the AI summary as it stands, the
/// conversation's transcript growing at the bottom, and a bar carrying both the conversation's
/// own [Ask][Notes][Follow-ups] and the [Pause][Stop] transport. No tab bar.
///
/// A LIVE CONVERSATION IS A CONVERSATION. It just happens to still be appending. This screen
/// used to be a transcript with two unlabelled buttons under it — no summary, no AI actions,
/// no timeline — so the one conversation you were actually in was the only one you could do
/// nothing with. Everything here is keyed by `LiveSnapshot.conversationId`, which is the SAME
/// id the Library shows afterwards (`ConversationGrouper.adoptStableIds` keeps it across the
/// regroup that closes it), so nothing opened from here breaks when the recording ends.
///
/// The summary here is provisional (the enrichment worker rewrites it as the text grows), and
/// Ask/Notes read durable transcripts while follow-ups are only extracted from a finished
/// conversation. Both used to be said in captions on this screen; the headline "Recording now"
/// and the Live badge already say that everything here is still being written, so the captions
/// were removed rather than shortened.
///
/// This is the Conversation screen's transcript card, not a parallel one: same speaker
/// blocks, same clock stamps beside the names, same inline quiet/missing markers. What the
/// user watches being written here is exactly what they will find in the Library afterwards
/// — including everything captured before the current segment, which this screen used to
/// throw away every time the link dropped and a new segment opened.
///
/// Times: absolute clock stamps, not elapsed offsets. The header already anchors the session
/// ("Started 12:04 PM"), a stamp has to survive into the finished Conversation unchanged, and
/// Q16 pins every displayed time to the zone the audio was RECORDED in. The still-growing
/// turn gets no stamp at all — its words are still being revised.
struct LiveConversationScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = LiveViewModel()
    @State private var showTemplates = false
    @State private var showFollowUps = false
    /// False the moment the reader scrolls up off the tail. Without it the transcript snapped
    /// back to the bottom on every revision of the in-progress line — which is several times a
    /// second — so nothing above the newest words (the timeline, the summary, anything said
    /// five minutes ago) could be read at all while recording.
    @State private var followsTail = true
    /// Whether to offer the ⌄ ride back to the newest words — the same rule and the same control
    /// as the finished Conversation, with `rearmsWhenContentGrows` because this one is still
    /// being said. `followsTail` and this share their at-the-end reading, so the screen cannot
    /// hold two answers to "is the reader at the tail".
    @State private var jumpToEnd = JumpToEndPolicy(rearmsWhenContentGrows: true)
    /// The two halves of "does this run on below the fold". Measured, because it has to be known
    /// before anybody has scrolled — opening a live conversation that is ALREADY long is the
    /// case with no auto-follow behind it (`follow` runs on change, and nothing has changed yet).
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// The conversation this screen was watching, kept after the live snapshot stops carrying
    /// one. `LiveTodayDataSource` publishes an EMPTY snapshot the moment there is no live row —
    /// no id, no started line — so without this, a recording that ends while you are looking at
    /// it leaves a screen that can no longer say what it was about or open what it produced.
    @State private var lastKnownId = ""

    private let bottomAnchor = "live-transcript-bottom"

    /// Taller than the screen by more than this and there is something worth jumping to. Below
    /// it a flick gets there and a button would be furniture. Same figure as the Conversation.
    private static let belowFoldSlack: CGFloat = 24

    /// The conversation everything on this screen addresses: the live one, or the one that has
    /// just ended under it.
    private var conversationId: String {
        viewModel.snapshot.conversationId.isEmpty
            ? lastKnownId : viewModel.snapshot.conversationId
    }

    /// Nothing being recorded and nothing that just was: no conversation to act on, so no bar.
    /// Three greyed-out pills over an empty screen is furniture, not an offer.
    private var showsBottomBar: Bool {
        viewModel.snapshot.isLive || !conversationId.isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.blockGap) {
                    header
                    // The timeline goes first, in the same place the finished Conversation
                    // puts its player card — this screen's answer to "how much of this have we
                    // actually got, and where did it break".
                    if let timeline = viewModel.snapshot.timeline {
                        LiveTimelineCard(timeline: timeline)
                    }
                    transcriptCard
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, Tokens.screenMargin)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .background { heightProbe { contentHeight = $0 } }
            }
            .background { heightProbe { viewportHeight = $0 } }
            // Within 48 pt of the end counts as "at the end": the tail grows while the gesture
            // finishes, so an exact comparison would drop out of follow mode on its own.
            // Compared against the MAXIMUM offset (content + bottom inset − container) rather
            // than the raw content height, so the pinned bar's inset does not read as "the
            // reader has scrolled away", and content shorter than the screen stays following.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let maxOffset =
                    geometry.contentSize.height + geometry.contentInsets.bottom
                    - geometry.containerSize.height
                return geometry.contentOffset.y >= maxOffset - 48
            } action: { _, atBottom in
                followsTail = atBottom
                jumpToEnd.atEndChanged(atBottom)
            }
            // The reader's hand wins immediately — before the geometry catches up — so the
            // button cannot linger through the gesture that is dismissing it. `.interacting` is
            // the drag itself; `.animating` is our own `follow`, and keying on that would arm
            // the offer every time we scrolled on the reader's behalf.
            .onScrollPhaseChange { _, phase, _ in
                guard phase == .interacting else { return }
                jumpToEnd.readerTookOver()
            }
            .onChange(of: newestRowKey) { _, _ in follow(proxy) }
            // A genuinely new turn, not the tail being revised: the reader has been left behind
            // rather than choosing to be, so offer the way back. `follow` has already taken
            // anyone still at the end, so this only ever reaches someone who is not.
            .onChange(of: newestTurnId) { _, _ in jumpToEnd.contentGrew() }
            .onChange(of: contentHeight) { _, _ in updateBelowFold() }
            .onChange(of: viewportHeight) { _, _ in updateBelowFold() }
            // An inset, not an overlay: the scroll view's safe area already excludes the
            // [Stop][Ask][Notes] bar, so this lands above it and the newest line is never left
            // underneath the control.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                jumpToEndButton(proxy)
                    .motionAware(.snappy(duration: 0.25), value: jumpToEnd.shows)
            }
        }
        .background(Tokens.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsBottomBar { bottomBar }
        }
        .task { await viewModel.observe() }
        .onChange(of: viewModel.snapshot.conversationId) { _, id in
            if !id.isEmpty { lastKnownId = id }
        }
        .onAppear {
            let id = viewModel.snapshot.conversationId
            if !id.isEmpty { lastKnownId = id }
        }
        .sheet(isPresented: $showTemplates) {
            TemplateSheet(conversationId: conversationId) { note in
                showTemplates = false
                router.push(.note(id: note.id))
            }
        }
        .sheet(isPresented: $showFollowUps) {
            FollowUpsSheet(conversationId: conversationId)
        }
    }

    // MARK: Header ("Recording now" · started line · Live badge · summary)
    //
    // Same shape as the finished Conversation's header — title, meta line, summary — because
    // it is the same conversation. The summary is provisional (the enrichment worker rewrites
    // it as the text grows) and used to carry a caption saying so; the headline and the Live
    // badge above it already do.

    /// "Recording now" only while that is true. When the recording ends somewhere else — the
    /// watch out of range, capture turned off from Today, Settings, Control Center or a
    /// Shortcut — the screen used to keep the headline and lose only the badge, which on this
    /// product is the worst sentence it could be left holding.
    private var headline: String {
        if viewModel.snapshot.isLive { return Copy.Live.title }
        return conversationId.isEmpty ? Copy.Live.idleTitle : Copy.Live.endedTitle
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(AppFont.detailTitle)
                        .foregroundStyle(Tokens.label)
                    if !viewModel.snapshot.startedLine.isEmpty {
                        Text(viewModel.snapshot.startedLine)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                    }
                    if !viewModel.snapshot.isLive, !conversationId.isEmpty {
                        Text(Copy.Live.endedLine)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if viewModel.snapshot.isLive {
                    LiveBadge()
                }
            }
            .accessibilityElement(children: .combine)

            // Nothing at all until AI has written something. An empty card headed "Summary"
            // would report a failure where the truth is "not yet".
            if let summary = viewModel.snapshot.summary?
                .trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty
            {
                Text(summary)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.secondaryBody)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
    }

    // MARK: Transcript (the Conversation card, still being written)

    @ViewBuilder
    private var transcriptCard: some View {
        if viewModel.snapshot.items.isEmpty {
            Card {
                // ONE line, and it says which of the reasons is true. This used to be the
                // fixed "Listening…" sentence whatever was happening — including a phone that
                // had heard nothing from the watch for eleven minutes.
                Text(viewModel.snapshot.status.line)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                // Words already on screen do not make a stalled link uninteresting: this is
                // what explains a transcript that has stopped growing.
                if !viewModel.snapshot.status.isUneventful {
                    LiveStatusNote(text: viewModel.snapshot.status.line)
                }
                TranscriptView(
                    transcript: viewModel.snapshot.items,
                    provenance: viewModel.snapshot.provenance,
                    timeZone: viewModel.snapshot.timeZone
                )
            }
        }
    }

    // MARK: Derivation

    /// Changes both when a row is added and when the in-progress tail grows, which is exactly
    /// when the view should follow along.
    private var newestRowKey: String {
        guard let last = viewModel.snapshot.items.last else { return "" }
        if case .turn(let turn) = last { return "\(last.id)-\(turn.text.count)" }
        return last.id
    }

    /// The ⌄ ride back to the newest words. `JumpToEndPolicy` decides when; `JumpToEndButton`
    /// is the control the finished Conversation draws, so the two screens offer the same thing
    /// in the same corner. Taking it also re-arms following: the reader asked to be at the tail,
    /// and staying there is what they asked for.
    @ViewBuilder
    private func jumpToEndButton(_ proxy: ScrollViewProxy) -> some View {
        if jumpToEnd.shows {
            JumpToEndButton {
                jumpToEnd.jumped()
                followsTail = true
                withAnimation(Motion.animation(.easeOut(duration: 0.3))) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    /// The identity of the newest row, which changes only when one is APPENDED — unlike
    /// `newestRowKey`, which also changes on every revision of the in-progress line, several
    /// times a second.
    private var newestTurnId: String { viewModel.snapshot.items.last?.id ?? "" }

    /// Reports a view's height once when it appears and again whenever it changes — and the
    /// "once when it appears" is the point. `onScrollGeometryChange` runs its action only when
    /// the value it derives *changes*, so a conversation that is already longer than the screen
    /// when it opens never produces a first reading from it. `onChange(initial: true)` always
    /// fires. Neither of these runs per scrolled frame: a height changes when the transcript
    /// does, or on rotation.
    private func heightProbe(_ report: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.height, initial: true) { _, height in
                    report(height)
                }
        }
    }

    /// Both halves or neither: the two probes report in the same layout pass but in no fixed
    /// order, and answering from one of them would flash the button onto a screen that fits.
    private func updateBelowFold() {
        guard contentHeight > 0, viewportHeight > 0 else { return }
        jumpToEnd.contentBelowFoldChanged(contentHeight > viewportHeight + Self.belowFoldSlack)
    }

    /// Keep the newest words on screen — but only while the reader is already there. Reduce
    /// Motion still scrolls, it just doesn't animate.
    private func follow(_ proxy: ScrollViewProxy) {
        guard viewModel.snapshot.isLive, followsTail else { return }
        if reduceMotion {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    // MARK: Bottom bar ([Stop][Ask][Notes][Follow-ups])
    //
    // The actions are in the same place, in the same order, with the same labels as the
    // finished Conversation's bar — a person who knows that screen finds them here without
    // being told. The transport sits below them, closest to the thumb, because it is the one
    // control on this screen that might be needed in a hurry.
    //
    // They are only pinned together like this because they belong to the same object: the
    // conversation you are in. Once that conversation ends the transport goes — there is
    // nothing left to pause — and the bar offers the finished conversation instead; with no
    // conversation at all the whole bar is gone rather than three pills scoped to nothing.

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionsRow
            if !viewModel.snapshot.isLive, !conversationId.isEmpty {
                // Nothing left to pause or stop; the useful move is the finished conversation,
                // which has the player, the final transcript and the ⋯ menu this screen cannot.
                Button(Copy.Live.openConversation) { showEndedConversation() }
                    .buttonStyle(.inCardFilled)
            }
        }
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // Room for the note-job card, which parks itself above whatever a screen keeps at its
        // bottom edge. Without this it lands on these pills — which is the report that started
        // this: a card covering the controls underneath it.
        .noteJobDockClearance()
        .background(Tokens.barBg)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.barHairline).frame(height: 0.5)
        }
    }

    /// Wraps onto extra rows at large Dynamic Type sizes instead of crushing the pills — the
    /// same `FlowLayout` the Conversation screen's bar uses.
    private var actionsRow: some View {
        FlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
            // One control, in the same row as everything else. This was a separate section
            // holding both Pause and Stop: two buttons for one intention, in a bar of their own,
            // each explaining itself underneath. Stop is what a person means here — the
            // recording ends — and turning it back on is the switch on Today, which is where
            // every other capture decision already lives.
            if viewModel.snapshot.isLive {
                ActionPill(title: Copy.Live.stop, systemImage: "stop.fill", style: .stop) {
                    Haptics.captureEnded()
                    viewModel.stopTapped()
                    showEndedConversation()
                }
            }
            ActionPill(title: Copy.Conversation.ask, systemImage: "sparkles", style: .filled) {
                let id = conversationId
                guard !id.isEmpty else { return }
                router.navigate(
                    to: .ask(
                        scope: AskScope.conversation(id: id, title: headline).routeKey,
                        query: nil))
            }
            ActionPill(title: Copy.Conversation.notes) { openNotes() }
            // Not while it is live. `FollowUpWorker` requires `!conversation.isOpen` and every
            // member closed and fully transcribed, so a live conversation cannot have produced a
            // single follow-up and the sheet is guaranteed empty — a button whose only possible
            // outcome is an empty list. It comes back with the finished conversation.
            if !viewModel.snapshot.isLive {
                ActionPill(title: Copy.Conversation.followUps) {
                    guard !conversationId.isEmpty else { return }
                    showFollowUps = true
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(conversationId.isEmpty)
        .opacity(conversationId.isEmpty ? 0.4 : 1)
    }

    // MARK: Actions

    /// Plan 6.9, same rule as the Conversation screen: existing notes open directly, otherwise
    /// the template sheet.
    /// Always the sheet — it lists the notes this conversation already has above the templates.
    /// Opening the first existing note directly (what this did, mirroring the conversation
    /// screen) made [Notes] a one-shot button: once any note existed, no other template could be
    /// reached from the bar.
    private func openNotes() {
        guard !conversationId.isEmpty else { return }
        showTemplates = true
    }

    /// Where Pause and Stop leave you: on the conversation you just finished, not back on
    /// Today.
    ///
    /// Both used to `dismiss()`, which made sense when this screen was a transcript and two
    /// buttons — there was nothing here to stay for. Now that it carries the summary and the AI
    /// actions, being thrown to Today at the exact moment the recording becomes a finished,
    /// richer conversation (real player, final transcript as it lands, tags, share, ⋯ menu) is
    /// the app taking the thing away as you reach for it.
    ///
    /// The `.live` entry in the stack is REPLACED rather than pushed over, so Back still goes
    /// to Today and there is no dead screen behind. If `.live` is not in the stack (or there is
    /// no conversation to show) this falls back to the old behaviour rather than stranding the
    /// user on a screen that has stopped being live.
    private func showEndedConversation() {
        let id = conversationId
        guard !id.isEmpty, let index = router.todayPath.lastIndex(of: .live) else {
            dismiss()
            return
        }
        router.todayPath =
            Array(router.todayPath.prefix(index)) + [.conversation(id: id, atMs: nil)]
    }
}

// MARK: - Previews

#Preview("Live conversation") {
    NavigationStack {
        LiveConversationScreen()
    }
    .environment(AppRouter())
    .tint(Tokens.tint)
}
