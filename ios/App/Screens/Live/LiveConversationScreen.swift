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
/// What is honestly different while it is still being written is said, once, where it matters:
/// the summary is provisional and gets rewritten (`Copy.Live.summarySoFar`), and Ask/Notes read
/// durable transcripts while follow-ups are only extracted from a finished conversation
/// (`Copy.Live.aiHorizon`). Neither is hidden and neither is dressed up.
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
    /// The conversation this screen was watching, kept after the live snapshot stops carrying
    /// one. `LiveTodayDataSource` publishes an EMPTY snapshot the moment there is no live row —
    /// no id, no started line — so without this, a recording that ends while you are looking at
    /// it leaves a screen that can no longer say what it was about or open what it produced.
    @State private var lastKnownId = ""

    private let bottomAnchor = "live-transcript-bottom"

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
            }
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
            }
            .onChange(of: newestRowKey) { _, _ in follow(proxy) }
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

    // MARK: Header ("Recording now" · started line · Live badge · summary so far)
    //
    // Same shape as the finished Conversation's header — title, meta line, summary — because
    // it is the same conversation. The one addition is the caption under the summary: the
    // enrichment worker runs a PROVISIONAL pass while a conversation is open and rewrites it as
    // the text grows, so a summary presented here as final would be wrong within the minute.

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
                Text(Copy.Live.summarySoFar)
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.faint)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Bottom bar ([Ask][Notes][Follow-ups] · the AI horizon line · [Pause][Stop])
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
            ActionPill(title: Copy.Conversation.followUps) {
                guard !conversationId.isEmpty else { return }
                showFollowUps = true
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
