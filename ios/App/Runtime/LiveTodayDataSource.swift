import AppDB
import CompanionRuntime
import Foundation
import Intelligence
import LiveAudio
import Receiver
import SearchKit
import SegmentStore
import StatusUI
import Transcription
import UIKit

// The real Today + Live sources. `PreviewTodayData` renders the artboards; this renders the
// database, the spool and the receiver — the mapping from kit types into the screens' display
// models lives here and nowhere else.
//
// One rebuild path: every trigger (receiver state, diagnostics, library changes, follow-up
// changes, the waveform, a slow tick for coverage) coalesces into `refresh()`, which publishes
// one `TodaySnapshot` and one `LiveSnapshot`.

@MainActor
final class LiveTodayDataSource {
    private let composition: AppComposition
    private var todaySnapshotValue: TodaySnapshot
    private var liveSnapshotValue = LiveSnapshot(startedLine: "", isLive: false, items: [])

    private var todayContinuations: [UUID: AsyncStream<TodaySnapshot>.Continuation] = [:]
    private var liveContinuations: [UUID: AsyncStream<LiveSnapshot>.Continuation] = [:]

    private var tasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?
    /// The monitor's raw bars, kept in kit form so the row can be re-placed on the time axis at
    /// every publish — a snapshot built ten seconds ago must not be redrawn as if it were now.
    private var liveBars: [LiveAudio.WaveformBar] = []
    /// How far transcription has got, per segment, as an exclusive stream sample index
    /// (`UInt64.max` once a durable transcript exists). This is what turns a live bar from
    /// captured to transcribed — without it the row had no path to the transcribed colour at
    /// all and stayed lilac no matter how well live transcription was keeping up.
    private var transcribedThrough: [String: UInt64] = [:]
    /// Wall clock of the last transcription-boundary poll, so the 4 Hz waveform tick re-reads the
    /// live previews about once a second instead of on every frame.
    private var lastBoundaryPollMs: Int64 = 0

    init(composition: AppComposition) {
        self.composition = composition
        todaySnapshotValue = TodaySnapshot(
            status: LiveTodayDataSource.status(composition),
            liveMinute: [],
            coverage: nil,
            recap: nil,
            followUps: [],
            conversations: []
        )
    }

    /// Starts the observations. Called once, from `AppComposition.install`.
    func start() {
        guard tasks.isEmpty else { return }
        let composition = self.composition

        tasks.append(
            Task { [weak self] in
                for await _ in composition.runtime.receiverState.stream() {
                    self?.scheduleRefresh()
                }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in composition.runtime.diagnostics.stream() {
                    self?.scheduleRefresh()
                }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in composition.runtime.library.observeLibrary() {
                    self?.scheduleRefresh()
                }
            })
        tasks.append(
            Task { [weak self] in
                for await _ in composition.runtime.library.observeOpenFollowUps() {
                    self?.scheduleRefresh()
                }
            })
        tasks.append(
            Task { [weak self] in
                for await bars in await composition.monitor.barsUpdates() {
                    guard let self else { return }
                    liveBars = bars
                    // The boundary moves on the transcribers' own schedule (~5 s), not on
                    // `refresh()`'s ten-second tick, so poll it here — cheap, throttled, and on
                    // the one path that already runs whenever the row is redrawn.
                    await pollTranscribedBoundary()
                    // The published snapshot has to carry the new row, not just the new field:
                    // `publish()` yields `todaySnapshotValue`, so assigning a private property
                    // and publishing left the waveform on screen frozen until the next full
                    // refresh — up to ten seconds behind the audio it was drawing.
                    todaySnapshotValue.liveMinute = liveMinuteSlots()
                    publish()
                }
            })
        // Coverage, the recap card and the elapsed-time lines are wall-clock derived, so they
        // need a slow tick even when nothing else changes.
        tasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    self?.scheduleRefresh()
                }
            })
        scheduleRefresh()
    }

    deinit {
        for task in tasks { task.cancel() }
        refreshTask?.cancel()
    }

    // MARK: - Rebuild

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            self?.refreshTask = nil
        }
    }

    private func refresh() async {
        let composition = self.composition
        let nowMs = composition.clock.nowMs
        let zone = TimeZone.current.identifier
        let dateKey = LogicalDay.dateKey(forMs: nowMs, timeZoneID: zone)

        let openSegmentId = await composition.store.openSegmentId
        composition.openSegment.set(openSegmentId)

        let segments = await composition.store.listSegments()
        let pauses = (try? await composition.pauseJournal.intervals(
            overlappingMs: nowMs - 48 * 60 * 60 * 1000, nowMs)) ?? []

        let sections = (try? await composition.runtime.library.library()) ?? []
        let todaySection = sections.first { $0.dateKey == dateKey }
        let followUps = (try? await composition.followUps.list()) ?? []
        let recap = try? await composition.recapStore.load(dateKey: dateKey)

        // Live first: the rolling line the live row shows comes out of the live transcript this
        // builds, so the Today snapshot below has something to put in `snippet` instead of the
        // hard-coded nil it used to carry.
        await refreshLive(openSegmentId: openSegmentId, rows: todaySection?.rows ?? [])
        let liveLine = Self.liveSnippet(liveSnapshotValue)

        let status = Self.status(composition)
        // The row's live-silence fill is gated on exactly the claim the card makes, so a quiet
        // minute can never be drawn as quiet under a headline that says we are not hearing the
        // watch — and the fill stops the moment "Recording" does.
        await composition.monitor.setStreamLive(status.family == .recording)

        todaySnapshotValue = TodaySnapshot(
            status: status,
            liveMinute: liveMinuteSlots(),
            coverage: Self.coverage(
                nowMs: nowMs, zone: zone, dateKey: dateKey, segments: segments, pauses: pauses
            ),
            recap: Self.recap(
                recap, aiModelName: composition.settings.aiModel, rows: todaySection?.rows ?? []
            ),
            followUps: Self.followUpDisplays(followUps),
            conversations: (todaySection?.rows ?? []).map {
                Self.conversationRow(
                    $0,
                    liveSnippet: liveLine,
                    // Only when there are no words to quote: a row already showing what is
                    // being said has answered the question the status line asks.
                    liveStatusLine: liveLine == nil ? liveSnapshotValue.status.rowLine : nil
                )
            },
            recovering: composition.startup.isRecovering
        )
        publish()
    }

    /// The live conversation, whole.
    ///
    /// This used to render ONLY the open segment's rolling preview, so everything captured
    /// before the current segment vanished from the screen the moment the link dropped and
    /// the watch opened a new one — while the user was watching. The conversation's members
    /// are walked in order instead: durable transcripts for the ones already transcribed,
    /// the live preview for the segment still open, and the newest block marked as the tail
    /// still being written.
    private func refreshLive(openSegmentId: String?, rows: [ConversationListRow]) async {
        guard let live = rows.first(where: \.isLive) else {
            liveSnapshotValue = LiveSnapshot(
                startedLine: "", isLive: false, items: [], status: liveStatus())
            pruneTranscribedThrough(keeping: [])
            return
        }
        let nowMs = composition.clock.nowMs
        let started = Date(timeIntervalSince1970: Double(live.startMs) / 1000)

        // Both live sources can have produced text for the open segment — the realtime socket
        // while it was up, the chunk path before it connected or after it died — so the screen
        // shows their union rather than dropping one, and names whichever produced the newest
        // words.
        var preview: LiveTranscriptPreview?
        if let openSegmentId {
            preview = LiveTranscriptPreview.merged(
                cloud: await composition.cloudLive.previews[openSegmentId],
                local: await composition.localLive.previewFor(openSegmentId)
            )
        }

        let detail = try? await composition.runtime.library.conversation(id: live.id)
        let assignments =
            (try? await composition.people.assignments(forConversation: live.id)) ?? []
        var items: [TranscriptItem] = []
        var zone: TimeZone?
        var openMeta: SegmentMeta?
        var memberIds: Set<String> = []

        for member in detail?.members ?? [] {
            // The open segment's meta places the transcript in time and carries the gaps the
            // watch has already reported, so quiet/missing show up while recording rather
            // than only at the end.
            guard let meta = composition.files.readMeta(member.segmentId) else { continue }
            if zone == nil { zone = TranscriptItems.timeZone(meta) }
            let isOpen = member.segmentId == openSegmentId
            if isOpen { openMeta = meta }
            let durable = composition.transcripts.load(member.segmentId)
            memberIds.insert(member.segmentId)
            // A finished transcript covers its whole segment, so every bar of it is transcribed.
            if durable != nil { transcribedThrough[member.segmentId] = .max }
            // Durable text wins wherever it exists — it is the same text this conversation
            // will keep. The preview only covers the segment still being recorded.
            let segments: [SearchKit.TranscriptSegment]
            if let durable {
                segments = durable.segments.map {
                    SearchKit.TranscriptSegment(
                        text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker)
                }
            } else if isOpen, let preview {
                segments = preview.segments.map {
                    SearchKit.TranscriptSegment(
                        text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker)
                }
            } else {
                segments = []
            }

            // No timings yet on the open segment: one unstamped, still-growing row.
            if isOpen, durable == nil, segments.isEmpty, let preview {
                items.append(
                    contentsOf: TranscriptItems.untimedTail(
                        segmentId: member.segmentId, text: preview.text))
                continue
            }

            let built = TranscriptItems.member(
                segmentId: member.segmentId,
                meta: meta,
                segments: segments,
                words: (durable?.words ?? []).map {
                    SearchKit.TranscriptWord(
                        text: $0.text, startMs: $0.startMs, endMs: $0.endMs)
                },
                assignments: assignments
            )
            var memberItems = built.items
            // Only the newest block of the open, not-yet-durable segment is still growing.
            if isOpen, durable == nil, let lastTurnId = built.lastTurnId,
                let index = memberItems.firstIndex(where: { $0.id == lastTurnId }),
                case .turn(var turn) = memberItems[index]
            {
                turn.isInProgress = true
                memberItems[index] = .turn(turn)
            }
            items.append(contentsOf: memberItems)
        }

        pruneTranscribedThrough(keeping: memberIds)

        liveSnapshotValue = LiveSnapshot(
            startedLine: Copy.Live.startedLine(
                time: TimeFmt.time(started),
                elapsed: Formatting.duration(max(0, nowMs - live.startMs))
            ),
            isLive: live.isLive,
            items: items,
            timeZone: zone ?? .current,
            provenance: Self.liveProvenance(preview),
            status: liveStatus()
        )
    }

    /// Why the live transcript has nothing new — the four honest answers behind what used to be
    /// one calm line for all of them (see `LiveTranscriptStatus`).
    ///
    /// The order is worst-first in terms of what a person can act on: a transcription that was
    /// never set up will never produce a word, so it outranks a missing link, which outranks a
    /// quiet room, which outranks an engine that is failing on audio we do have.
    private func liveStatus() -> LiveTranscriptStatus {
        Self.liveStatus(
            transcriptsConfigured: composition.settings.transcriptsConfigured,
            // The same evidence the status card weighs, so the two surfaces can never disagree
            // about whether this phone is hearing the watch.
            verdict: composition.runtime.streamEvidence.value.verdict(
                nowMs: composition.clock.nowMs),
            mode: composition.settings.transcriptionMode,
            cloudStatus: composition.cloudHealth.state.status,
            liveLocalFailing: composition.runtime.pipelineHealth.health[.liveLocal]
                .isPersistentlyFailing
        )
    }

    /// Pure, so the four answers can be tested without a composition root.
    ///
    /// Order is worst-first in terms of what a person can act on: transcription that was never
    /// set up will never produce a word, so it outranks a missing link, which outranks a quiet
    /// room, which outranks an engine failing on audio we do have.
    static func liveStatus(
        transcriptsConfigured: Bool,
        verdict: StreamVerdict,
        mode: TranscriptionMode,
        cloudStatus: CloudHealthStatus,
        liveLocalFailing: Bool
    ) -> LiveTranscriptStatus {
        if !transcriptsConfigured { return .transcriptsOff }

        switch verdict {
        case .unverified, .watchSaysNotStreaming: return .notHearingWatch
        case .watchSaysStreaming: return .quiet
        case .hearingAudio, .unchecked: break
        }

        // Audio IS arriving, so anything missing now is the live engine's own trouble. The two
        // live paths report through different channels — the realtime socket through cloud
        // health, the chunk path through the pipeline's stage health — and either one working
        // is enough to say nothing is wrong, because the screen shows whichever produced words.
        // Hence `remoteOnly` for the cloud half: in a `-first` mode the other path is a real
        // fallback, and calling live transcription down while it is quietly working would be
        // its own kind of lie.
        let cloudLiveDown = mode == .remoteOnly && cloudStatus == .failed
        if cloudLiveDown || liveLocalFailing { return .liveTranscriptionDown }
        return .listening
    }

    private func publish() {
        for continuation in todayContinuations.values { continuation.yield(todaySnapshotValue) }
        for continuation in liveContinuations.values { continuation.yield(liveSnapshotValue) }
    }

    /// The live row, placed on a time axis ending NOW rather than right-aligned on whatever
    /// arrived last. Audio that stops therefore drains leftwards out of the window instead of
    /// standing still against the right edge while the headline says "Recording".
    private func liveMinuteSlots() -> [WaveformBar?] {
        let transcribed = transcribedThrough
        return WaveformWindow.slots(
            bars: liveBars,
            nowMs: composition.clock.nowMs,
            slotCount: WaveformView.slotCount,
            windowMs: WaveformView.windowMs
        )
        .map { slot in slot.map { WaveformBar(kit: $0, transcribedThrough: transcribed) } }
    }

    /// Re-reads how far the live transcribers have consumed the open segment. Throttled to ~1 s:
    /// the waveform ticks at 4 Hz and the previews advance far more slowly than that.
    private func pollTranscribedBoundary() async {
        let nowMs = composition.clock.nowMs
        guard nowMs - lastBoundaryPollMs >= 1_000 else { return }
        lastBoundaryPollMs = nowMs
        guard let openSegmentId = composition.openSegment.value else { return }
        let merged = LiveTranscriptPreview.merged(
            cloud: await composition.cloudLive.previews[openSegmentId],
            local: await composition.localLive.previewFor(openSegmentId)
        )
        guard let merged else { return }
        // Monotonic: a preview that briefly loses its tail (a socket dying mid-segment, a prune)
        // must not repaint seconds that were already shown as transcribed.
        let previous = transcribedThrough[openSegmentId] ?? 0
        transcribedThrough[openSegmentId] = max(previous, merged.lastSampleIndexExclusive)
    }

    /// Bounded to the segments the live row can actually be drawing, so a long day's worth of
    /// boundaries never accumulates behind a screen that only shows one minute.
    private func pruneTranscribedThrough(keeping ids: Set<String>) {
        transcribedThrough = transcribedThrough.filter { ids.contains($0.key) }
    }

    // MARK: - Mapping

    /// The status card. `transcriptsOff` wins until the user has actually chosen where
    /// transcription happens (6.7) — recording is safe either way, so the card says so rather
    /// than implying something is broken.
    private static func status(_ composition: AppComposition) -> StatusModel {
        let settings = composition.settings
        if !settings.transcriptsConfigured, settings.captureIntent != .off {
            return .transcriptsOff
        }
        return statusModel(
            state: composition.runtime.receiverState.value,
            intent: settings.captureIntent,
            storagePauseRequested: composition.runtime.diagnostics.value.pauseRequested,
            watchServiceStateRaw: composition.runtime.watchServiceState.value,
            // The watch's own advertised name, so the sub-line names the device actually on the
            // other end. Without it the card rendered the constant "Pebble · connected" — a
            // sentence about a watch nobody had asked and a link nobody had checked.
            deviceName: composition.runtime.deviceName.value,
            // What the watch said when it refused, if it did. Without this the connect →
            // authorize → resync loop of a de-authorized receiver reads as "Connecting…" forever.
            linkFault: composition.watchLinkFault,
            // What still backs `.streaming`. The latch alone survives a watch that stops sending
            // without a clean stop, which is how the card came to say "Recording" with no live
            // conversation anywhere.
            streamVerdict: composition.runtime.streamEvidence.value.verdict(
                nowMs: composition.clock.nowMs
            )
        )
    }

    private static func coverage(
        nowMs: Int64,
        zone: String,
        dateKey: String,
        segments: [SegmentMeta],
        pauses: [PauseInterval]
    ) -> CoverageDisplay? {
        guard !segments.isEmpty || !pauses.isEmpty else { return nil }
        let day = CoverageComputer.todaySoFar(
            nowMs: nowMs,
            timeZoneID: zone,
            segments: segments.map { SegmentCoverageInput(meta: $0) },
            pauses: pauses
        )
        guard let bounds = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone),
            bounds.endMs > bounds.startMs, !day.spans.isEmpty
        else { return nil }

        let domain = Double(bounds.endMs - bounds.startMs)
        let spans = day.spans.map { span -> CoverageSpanDisplay in
            let lower = Double(span.startMs - bounds.startMs) / domain
            let upper = Double(span.endMs - bounds.startMs) / domain
            let range = min(max(lower, 0), 1)...min(max(upper, lower), 1)
            return CoverageSpanDisplay(
                span: CoverageSpan(kind: span.kind.displayKind, range: range),
                popoverText: popoverText(span)
            )
        }
        return CoverageDisplay(
            headline: Copy.Today.recorded(Formatting.duration(day.totalRecordedMs)),
            missingText: day.totalMissingMs > 0
                ? Copy.Today.missing(Formatting.duration(day.totalMissingMs)) : nil,
            spans: spans
        )
    }

    private static func popoverText(_ span: AppDB.CoverageSpan) -> String? {
        let range = "\(clockLabel(span.startMs))–\(clockLabel(span.endMs))"
        switch span.kind {
        case .off: return nil
        case .recorded: return "recorded \(range)"
        case .quiet: return Copy.Popover.quietSpan(range)
        case .missing: return Copy.Popover.missingSpan(Formatting.duration(span.durationMs))
        case .paused: return Copy.Popover.pausedSpan(range)
        }
    }

    private static func clockLabel(_ ms: Int64) -> String {
        TimeFmt.time(Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private static func recap(
        _ recap: DailyRecap?, aiModelName: String, rows: [ConversationListRow]
    ) -> RecapDisplay? {
        guard let recap, !recap.text.isEmpty else { return nil }
        let updated = Date(timeIntervalSince1970: Double(recap.updatedAtMs) / 1000)
        let titles = rows.compactMap(\.title).filter { !$0.isEmpty }
        let momentsFooter =
            titles.isEmpty
            ? ""
            : "\(titles.count) moment\(titles.count == 1 ? "" : "s") · "
                + titles.prefix(3).joined(separator: ", ")

        let bullets = recap.text
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { RecapBullet(id: $0.offset + 1, text: $0.element, citations: []) }

        return RecapDisplay(
            updatedText: Copy.Today.updatedAt(TimeFmt.time(updated)),
            digest: recap.text,
            detail: RecapDetailDisplay(
                id: RecapIndex.documentId(dateKey: recap.dateKey),
                title: Copy.Today.recapTitle,
                generatedLine:
                    "Generated \(TimeFmt.time(updated)) · "
                    + "\(AiModels.byId(recap.model ?? aiModelName).displayName) · from today",
                bullets: bullets,
                momentsFooter: momentsFooter
            )
        )
    }

    /// Open first, then the most recently completed — the card is a to-do list, not a log.
    static func followUpDisplays(_ items: [FollowUp]) -> [FollowUpDisplay] {
        items
            .sorted { a, b in
                if a.done != b.done { return !a.done }
                return a.createdAtMs > b.createdAtMs
            }
            .prefix(20)
            .map { FollowUpDisplay(id: $0.id, text: $0.text, done: $0.done) }
    }

    /// One Today row. `liveSnippet` is the rolling line for the conversation being recorded
    /// (Q6) — it belongs to the LIVE row and to no other, so a finished row never carries one.
    ///
    /// This used to pass `snippet: nil` unconditionally while `PreviewTodayData` supplied the
    /// line, so the calm rolling preview existed in every artboard and in no build: the live
    /// row on a real phone showed a title and a duration and nothing of what was being said.
    static func conversationRow(
        _ row: ConversationListRow, liveSnippet: String? = nil, liveStatusLine: String? = nil
    ) -> ConversationRowDisplay {
        let start = Date(timeIntervalSince1970: Double(row.startMs) / 1000)
        var meta = "\(TimeFmt.time(start)) · \(Formatting.duration(row.durationMs))"
        if row.isLive { meta += " so far" }
        return ConversationRowDisplay(
            id: row.id,
            title: row.title ?? (row.isLive ? "Recording now" : "Conversation"),
            meta: meta,
            snippet: row.isLive ? liveSnippet : nil,
            statusLine: row.isLive ? liveStatusLine : nil,
            isLive: row.isLive
        )
    }

    /// The newest thing actually said, quoted for the Today row: the last transcript turn of
    /// the live conversation, trimmed to its final sentence. Nil while nothing has been
    /// recognised yet — an empty quote would be a decoration, not information.
    static func liveSnippet(_ live: LiveSnapshot) -> String? {
        guard live.isLive else { return nil }
        let texts = live.items.compactMap { item -> String? in
            guard case .turn(let turn) = item else { return nil }
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard let line = AppComposition.lastLine(of: texts, limit: 120) else { return nil }
        return "“…\(line)”"
    }

    /// The rolling live transcript, derived by the same `transcriptTimelineItems` the finished
    /// Conversation uses — so a turn keeps its wall-clock stamp, and the quiet/missing rows the
    /// watch already reported render inline while recording instead of only appearing at the
    /// end. Turn times are the segment's start plus the provider's offset; the tail is marked
    /// in-progress (dimmed, unstamped) because its text is still being revised.
    /// Names the engine actually producing the live text — a cloud preview must not claim to be
    /// on-device, and an on-device fallback must not claim a cloud provider.
    ///
    /// Matched by PREFIX because the realtime backends carry their own ids ("soniox-realtime",
    /// "openai-realtime"): before this, a working Soniox live socket labelled itself
    /// "soniox-realtime" in the UI, and the on-device recognizer labelled itself
    /// "speechanalyzer" — accurate, but not what either of them is called.
    private static func liveProvenance(_ preview: LiveTranscriptPreview?) -> String {
        guard let providerId = preview?.providerId, !providerId.isEmpty else {
            // No engine has claimed this text; say nothing rather than assert on-device.
            return Copy.Live.provenance(source: Copy.Live.unknownSource)
        }
        if providerId.hasPrefix("soniox") { return Copy.Live.provenance(source: "Soniox") }
        if providerId.hasPrefix("openai") { return Copy.Live.provenance(source: "OpenAI") }
        // Every local engine (the system recognizer, "cactus-local") is on-device.
        return isOnDeviceProvider(providerId)
            ? Copy.Live.provenance()
            : Copy.Live.provenance(source: providerId)
    }

    private static func isOnDeviceProvider(_ providerId: String) -> Bool {
        providerId.hasSuffix("-local") || providerId.hasPrefix("apple")
            || providerId == SpeechAnalyzerProvider.providerId
    }
}

// MARK: - TodayDataSource

extension LiveTodayDataSource: TodayDataSource {
    func todaySnapshot() -> TodaySnapshot { todaySnapshotValue }

    func todayUpdates() -> AsyncStream<TodaySnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            todayContinuations[id] = continuation
            continuation.yield(todaySnapshotValue)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.todayContinuations[id] = nil }
            }
        }
    }

    /// Q13: pausing ends the conversation on the watch and writes a pause-journal row, so the
    /// coverage strip can render the window as paused rather than missing.
    func requestPause() {
        setIntent(.paused, source: .statusCard)
    }

    func perform(_ action: StatusAction) {
        switch action {
        case .start:
            // The one place the watch prompt is armed: an explicit Start. The settings write
            // comes first so the card flips the moment the user taps, rather than waiting for
            // a watch that may not be in range.
            composition.settings.captureIntent = .active
            Task { [composition] in
                await composition.runtime.startCapture()
                await self.refresh()
            }
        case .resume:
            setIntent(.active, source: .statusCard)
        case .stop:
            setIntent(.paused, source: .statusCard)
        case .findWatch:
            Task { [composition] in
                await composition.runtime.reconnect()
                await self.refresh()
            }
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .setUpTranscripts:
            // Through the app's own URL scheme, so a status-card tap and a pasted deep link
            // take exactly the same navigation path.
            UIApplication.shared.open(Route.settings(.transcription).url)
        case .tryAgain, .troubleshoot, .setUpAgain:
            UIApplication.shared.open(Route.settings(.watch).url)
        }
    }

    func setFollowUpDone(id: String, done: Bool) {
        Task { [composition] in
            try? await composition.followUps.setDone(id: id, done)
            await self.refresh()
        }
    }

    private func setIntent(_ intent: CaptureIntent, source: PauseSource) {
        let composition = self.composition
        composition.settings.captureIntent = intent
        Task {
            await composition.runtime.setCaptureIntent(intent, source: source)
            await self.refresh()
        }
    }
}

// MARK: - CaptureControlling

extension LiveTodayDataSource: CaptureControlling {
    /// The Settings "Background audio" switch, on the same rails as everything else that changes
    /// capture. `applyExternalCaptureIntent` is the runtime's one entry point for "apply this
    /// intent, whole": `.active` goes through `startCapture()` (arm the on-watch prompt, set the
    /// receiver's intent, dial the link) and `.off` through `setCaptureIntent` (stop receiving,
    /// close any open pause interval). The caller has already written `AppSettings.captureIntent`
    /// — same order as Today's Start and the Control Center intent — so the row flips at once.
    func applyCaptureIntent(_ intent: CaptureIntent) {
        let composition = self.composition
        Task {
            await composition.runtime.applyExternalCaptureIntent(intent)
            await self.refresh()
        }
    }
}

// MARK: - LiveDataSource

extension LiveTodayDataSource: LiveDataSource {
    func liveSnapshot() -> LiveSnapshot { liveSnapshotValue }

    func liveUpdates() -> AsyncStream<LiveSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            liveContinuations[id] = continuation
            continuation.yield(liveSnapshotValue)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.liveContinuations[id] = nil }
            }
        }
    }

    /// Explicit stop from the live screen: capture goes off entirely, not just paused.
    func requestStop() {
        setIntent(.off, source: .liveScreen)
    }
}

// MARK: - Kit → display

extension WaveformBar {
    /// The audio taxonomy, mapped from the kit's live monitor.
    ///
    /// `transcribedThrough` is how far transcription has consumed each segment, as an exclusive
    /// stream sample index. The kit reports what the AUDIO is and leaves transcription to the
    /// display — but this mapping used to answer `.captured` unconditionally, so the transcribed
    /// colour was unreachable from live data and the row stayed lilac however well live
    /// transcription was doing. Every bar carries the highest sample index in its bucket, which
    /// is exactly what the live preview's `lastSampleIndexExclusive` compares against.
    init(kit bar: LiveAudio.WaveformBar, transcribedThrough: [String: UInt64]) {
        let state: WaveformBar.State
        switch bar.state {
        case .recorded:
            state = Self.isTranscribed(bar, transcribedThrough) ? .transcribed : .captured
        case .silence: state = .quiet
        // No audio, but a live link that chose not to send it: quiet, drawn fainter than quiet
        // we decoded, and never confused with the blank of a slot we know nothing about.
        case .suppressedSilence: state = .skipped
        case .gap: state = .missing
        }
        self.init(amplitude: Double(bar.amplitude), state: state)
    }

    private static func isTranscribed(
        _ bar: LiveAudio.WaveformBar, _ transcribedThrough: [String: UInt64]
    ) -> Bool {
        guard let segmentId = bar.segmentId, let through = transcribedThrough[segmentId],
            let sample = bar.maxSampleIndex
        else { return false }
        return sample < through
    }
}

extension CoverageKind {
    var displayKind: CoverageSpan.Kind {
        switch self {
        case .recorded: return .recorded
        case .quiet: return .quiet
        case .missing: return .missing
        case .paused: return .paused
        case .off: return .off
        }
    }
}
