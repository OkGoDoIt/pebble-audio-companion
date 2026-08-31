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
    private var liveMinute: [WaveformBar] = []

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
                    liveMinute = bars.map(WaveformBar.init(kit:))
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

        todaySnapshotValue = TodaySnapshot(
            status: Self.status(composition),
            liveMinute: liveMinute,
            coverage: Self.coverage(
                nowMs: nowMs, zone: zone, dateKey: dateKey, segments: segments, pauses: pauses
            ),
            recap: Self.recap(
                recap, aiModelName: composition.settings.aiModel, rows: todaySection?.rows ?? []
            ),
            followUps: Self.followUpDisplays(followUps),
            conversations: (todaySection?.rows ?? []).map(Self.conversationRow)
        )
        await refreshLive(openSegmentId: openSegmentId, rows: todaySection?.rows ?? [])
        publish()
    }

    private func refreshLive(openSegmentId: String?, rows: [ConversationListRow]) async {
        guard let openSegmentId, let live = rows.first(where: \.isLive) else {
            liveSnapshotValue = LiveSnapshot(startedLine: "", isLive: false, items: [])
            return
        }
        let nowMs = composition.clock.nowMs
        let started = Date(timeIntervalSince1970: Double(live.startMs) / 1000)
        // Both live sources can have produced text for this segment — the realtime socket while
        // it was up, the chunk path before it connected or after it died — so the card shows
        // their union rather than dropping one, and names whichever produced the newest words.
        let preview = LiveTranscriptPreview.merged(
            cloud: await composition.cloudLive.previews[openSegmentId],
            local: await composition.localLive.previewFor(openSegmentId)
        )
        // The open segment's meta places the transcript in time and carries the gaps the watch
        // has already reported, so quiet/missing show up while recording rather than at the end.
        let meta = composition.files.readMeta(openSegmentId)

        liveSnapshotValue = LiveSnapshot(
            startedLine: Copy.Live.startedLine(
                time: TimeFmt.time(started),
                elapsed: Formatting.duration(max(0, nowMs - live.startMs))
            ),
            isLive: true,
            items: Self.liveItems(preview, meta: meta, startMs: live.startMs),
            timeZone: Self.liveTimeZone(meta),
            provenance: Self.liveProvenance(preview)
        )
    }

    private func publish() {
        for continuation in todayContinuations.values { continuation.yield(todaySnapshotValue) }
        for continuation in liveContinuations.values { continuation.yield(liveSnapshotValue) }
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
            watchServiceStateRaw: composition.runtime.watchServiceState.value
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
    private static func followUpDisplays(_ items: [FollowUp]) -> [FollowUpDisplay] {
        items
            .sorted { a, b in
                if a.done != b.done { return !a.done }
                return a.createdAtMs > b.createdAtMs
            }
            .prefix(20)
            .map { FollowUpDisplay(id: $0.id, text: $0.text, done: $0.done) }
    }

    private static func conversationRow(_ row: ConversationListRow) -> ConversationRowDisplay {
        let start = Date(timeIntervalSince1970: Double(row.startMs) / 1000)
        var meta = "\(TimeFmt.time(start)) · \(Formatting.duration(row.durationMs))"
        if row.isLive { meta += " so far" }
        return ConversationRowDisplay(
            id: row.id,
            title: row.title ?? (row.isLive ? "Recording now" : "Conversation"),
            meta: meta,
            snippet: nil,
            isLive: row.isLive
        )
    }

    /// The rolling live transcript, derived by the same `transcriptTimelineItems` the finished
    /// Conversation uses — so a turn keeps its wall-clock stamp, and the quiet/missing rows the
    /// watch already reported render inline while recording instead of only appearing at the
    /// end. Turn times are the segment's start plus the provider's offset; the tail is marked
    /// in-progress (dimmed, unstamped) because its text is still being revised.
    private static func liveItems(
        _ preview: LiveTranscriptPreview?, meta: SegmentMeta?, startMs: Int64
    ) -> [LiveTranscriptItem] {
        guard let preview else { return [] }
        let anchorMs = meta?.receivedAtMs ?? startMs
        func date(_ offsetMs: Int64) -> Date {
            Date(timeIntervalSince1970: Double(anchorMs + offsetMs) / 1000)
        }

        // No timings yet (or no meta to place them against): one unstamped in-progress tail.
        guard let meta, !preview.segments.isEmpty else {
            let text = preview.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                .turn(
                    LiveTurn(
                        id: "\(preview.segmentId)-tail", speaker: .unresolved, text: text,
                        isInProgress: true
                    ))
            ]
        }

        let timeline = transcriptTimelineItems(
            meta: meta,
            segments: preview.segments.map {
                SearchKit.TranscriptSegment(
                    text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker)
            }
        )
        let lastSpeechIndex = timeline.lastIndex { $0.asSpeech != nil }
        var items: [LiveTranscriptItem] = []
        for (offset, item) in timeline.enumerated() {
            let id = "\(preview.segmentId)-\(offset)"
            switch item {
            case .speech(let speech):
                items.append(
                    .turn(
                        LiveTurn(
                            id: id,
                            speaker: speech.speaker.map { LiveSpeaker.other($0) } ?? .unresolved,
                            text: speech.text,
                            startedAt: date(speech.startMs),
                            // Only the newest block is still growing.
                            isInProgress: offset == lastSpeechIndex
                        )))
            case .silenceBreak:
                break  // an unlabeled visual break; the card's row spacing carries it
            case .pause(let pause):
                items.append(
                    .marker(
                        LiveMarker(
                            id: id,
                            text: pause.label,
                            kind: pause.missing ? .missing : .quiet,
                            startedAt: date(pause.startMs)
                        )))
            }
        }
        return items
    }

    /// Q16: live stamps format in the zone the audio is being recorded in.
    private static func liveTimeZone(_ meta: SegmentMeta?) -> TimeZone {
        meta?.recordedTimeZone.flatMap { TimeZone(identifier: $0) } ?? .current
    }

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
    /// The four-state audio taxonomy, mapped from the kit's live monitor.
    init(kit bar: LiveAudio.WaveformBar) {
        // The kit reports what the AUDIO is; the strip's fourth state (transcribed) is a
        // display distinction the live monitor does not track, so captured is the honest floor.
        let state: WaveformBar.State
        switch bar.state {
        case .recorded: state = .captured
        case .silence, .suppressedSilence: state = .quiet
        case .gap: state = .missing
        }
        self.init(amplitude: Double(bar.amplitude), state: state)
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
