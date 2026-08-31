import Foundation
import StatusUI

/// Mockup-replica data source: the EXACT sample content of the Main + LiveDetail artboards
/// (extraction §2.4/§2.17), with just enough behavior to demonstrate the approved state
/// transitions — Pause/Resume flips the status family (Q13 ends the live conversation),
/// Stop turns capture off, follow-up circles check off. The runtime replaces this via
/// `AppDataSources.current`.
@MainActor
final class PreviewTodayData {
    private enum Phase { case recording, paused, stopped }

    private var phase: Phase = .recording
    private var followUps: [FollowUpDisplay] = [
        FollowUpDisplay(id: "fu-1", text: "Send Dana the new firmware build", done: false),
        FollowUpDisplay(id: "fu-2", text: "Book the theater walkthrough for Tuesday", done: false),
        FollowUpDisplay(id: "fu-3", text: "Reply to Paul about the lease paperwork", done: false),
        FollowUpDisplay(id: "fu-4", text: "Order spare straps for the Pebble", done: false),
        FollowUpDisplay(id: "fu-5", text: "Write up the reattach fix for the log", done: false),
        FollowUpDisplay(id: "fu-6", text: "Check the Soniox usage dashboard", done: false),
        FollowUpDisplay(id: "fu-7", text: "Charge the watch before the demo", done: false),
    ]

    private var todayContinuations: [UUID: AsyncStream<TodaySnapshot>.Continuation] = [:]
    private var liveContinuations: [UUID: AsyncStream<LiveSnapshot>.Continuation] = [:]

    // MARK: Sample content (artboard-exact)

    private static let deviceName = "Pebble Time 2"

    private static let recapDetail = RecapDetailDisplay(
        id: "day-2026-08-30",
        title: Copy.Today.recapTitle,
        generatedLine: "Generated 12:40 PM · GPT-5.6 Luna · from today",
        bullets: [
            RecapBullet(
                id: 1,
                text: "Quiet morning until coffee with Dana — she takes the new firmware build.",
                citations: [1]
            ),
            RecapBullet(
                id: 2,
                text: "Around noon you worked through the app redesign — simpler onboarding, "
                    + "conversations instead of segments.",
                citations: [2]
            ),
            RecapBullet(
                id: 3,
                text: "Decision: rebuild the app in Swift.",
                citations: [2]
            ),
        ],
        momentsFooter: "2 moments · Coffee with Dana, App redesign session"
    )

    private static let recap = RecapDisplay(
        updatedText: Copy.Today.updatedAt("12:40 PM"),
        digest: "Quiet morning. Around noon you worked through the app redesign — simpler "
            + "onboarding, conversations instead of segments. Decision: rebuild in Swift.",
        detail: recapDetail
    )

    /// The artboard strip with Q11 popover lines derived from the 5 AM → 5 AM domain.
    private static let coverage: CoverageDisplay = {
        let spans: [CoverageSpanDisplay] = [CoverageSpan].sampleDay.map { span in
            let text: String?
            switch span.kind {
            case .off:
                text = nil
            case .recorded:
                text = "recorded \(rangeLabel(span.range))"
            case .quiet:
                text = Copy.Popover.quietSpan(rangeLabel(span.range))
            case .missing:
                text = Copy.Popover.missingSpan("1 min")
            case .paused:
                text = Copy.Popover.pausedSpan(rangeLabel(span.range))
            }
            return CoverageSpanDisplay(span: span, popoverText: text)
        }
        return CoverageDisplay(
            headline: Copy.Today.recorded("4 hr 12 min"),
            missingText: Copy.Today.missing("1 min"),
            spans: spans
        )
    }()

    /// "h:mm AM–h:mm PM" for a fraction range of the logical day (5 AM start).
    private static func rangeLabel(_ range: ClosedRange<Double>) -> String {
        "\(timeLabel(range.lowerBound))–\(timeLabel(range.upperBound))"
    }

    private static func timeLabel(_ fraction: Double) -> String {
        let minutes = 5 * 60 + Int((fraction * 24 * 60).rounded())
        let hour24 = (minutes / 60) % 24
        let minute = minutes % 60
        let meridiem = hour24 < 12 ? "AM" : "PM"
        var hour = hour24 % 12
        if hour == 0 { hour = 12 }
        return String(format: "%d:%02d %@", hour, minute, meridiem)
    }

    // The LiveDetail sample conversation lives beside the screen it feeds
    // (`LiveSnapshot.demo`, Screens/Live).

    // MARK: Snapshot builders

    private func buildToday() -> TodaySnapshot {
        let status: StatusModel
        switch phase {
        case .recording:
            status = StatusModel(
                family: .recording,
                headline: StatusCopy.recording,
                detail: StatusCopy.connected(device: Self.deviceName),
                dot: .active,
                action: .stop
            )
        case .paused:
            status = StatusModel(
                family: .paused,
                headline: StatusCopy.paused,
                detail: StatusCopy.pausedLine,
                dot: .attention,
                action: .resume
            )
        case .stopped:
            status = StatusModel(
                family: .notRecording,
                headline: StatusCopy.notRecording,
                detail: StatusCopy.notRecordingLine,
                dot: .neutral,
                action: .start
            )
        }

        var conversations: [ConversationRowDisplay] = []
        if phase == .recording {
            conversations.append(
                ConversationRowDisplay(
                    id: "conv-redesign",
                    title: "App redesign session",
                    meta: "12:04 PM · 48 min so far",
                    snippet: "“…so the settings pages each push from one clean root…”",
                    isLive: true
                ))
        } else {
            // Q13: a pause or stop ends the conversation — the row finishes.
            conversations.append(
                ConversationRowDisplay(
                    id: "conv-redesign",
                    title: "App redesign session",
                    meta: "12:04 PM · 48 min",
                    snippet: nil,
                    isLive: false
                ))
        }
        conversations.append(
            ConversationRowDisplay(
                id: "conv-coffee",
                title: "Coffee with Dana",
                meta: "9:12 AM · 24 min",
                snippet: nil,
                isLive: false
            ))

        return TodaySnapshot(
            status: status,
            liveMinute: .sampleLiveMinute,
            coverage: Self.coverage,
            recap: Self.recap,
            followUps: followUps,
            conversations: conversations
        )
    }

    private func buildLive() -> LiveSnapshot {
        LiveSnapshot.demo(isLive: phase == .recording)
    }

    private func publish() {
        let today = buildToday()
        for continuation in todayContinuations.values { continuation.yield(today) }
        let live = buildLive()
        for continuation in liveContinuations.values { continuation.yield(live) }
    }
}

// MARK: - TodayDataSource

extension PreviewTodayData: TodayDataSource {
    func todaySnapshot() -> TodaySnapshot { buildToday() }

    func todayUpdates() -> AsyncStream<TodaySnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            todayContinuations[id] = continuation
            continuation.yield(buildToday())
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.todayContinuations[id] = nil }
            }
        }
    }

    func requestPause() {
        phase = .paused
        publish()
    }

    func perform(_ action: StatusAction) {
        switch action {
        case .start, .resume:
            phase = .recording
        case .stop:
            phase = .paused
        default:
            break
        }
        publish()
    }

    func setFollowUpDone(id: String, done: Bool) {
        guard let index = followUps.firstIndex(where: { $0.id == id }) else { return }
        followUps[index].done = done
        publish()
    }
}

// MARK: - LiveDataSource

extension PreviewTodayData: LiveDataSource {
    func liveSnapshot() -> LiveSnapshot { buildLive() }

    func liveUpdates() -> AsyncStream<LiveSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            liveContinuations[id] = continuation
            continuation.yield(buildLive())
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.liveContinuations[id] = nil }
            }
        }
    }

    func requestStop() {
        phase = .stopped
        publish()
    }
}
