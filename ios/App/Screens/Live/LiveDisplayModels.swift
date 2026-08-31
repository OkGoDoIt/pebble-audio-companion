import Foundation

// Display models for the Live Conversation screen (LiveDetail artboard, extraction §2.17).
//
// The transcript itself is NOT a separate model any more: the live screen renders the same
// `TranscriptItem`s the Conversation screen does, because a live conversation is that
// conversation — it just happens to be appending at the bottom.

struct LiveSnapshot: Equatable {
    /// e.g. "Started 12:04 PM · 48 min so far".
    var startedLine: String
    /// False once the conversation ended (paused/stopped) — the screen pops back.
    var isLive: Bool
    /// Everything captured in this conversation so far: the durable transcripts of members
    /// already closed, then the open segment's live text still growing at the end.
    var items: [TranscriptItem]
    /// Q16: every clock time on this screen formats in the zone the audio is being recorded
    /// in, so a conversation keeps the times it actually happened at after you fly home.
    var timeZone: TimeZone = .current
    /// In-card provenance footnote; names the engine actually producing this text.
    var provenance: String = Copy.Live.provenance()
}

/// The live read + transport surface; mirrors `TodayDataSource`'s seam.
@MainActor
protocol LiveDataSource: AnyObject {
    func liveSnapshot() -> LiveSnapshot
    /// Yields the current snapshot immediately, then every change.
    func liveUpdates() -> AsyncStream<LiveSnapshot>

    /// Q13: pause ends the conversation (watch mints a fresh stream id on resume).
    func requestPause()
    /// Explicit stop: ends the conversation and turns capture off.
    func requestStop()
}

// MARK: - Artboard sample content (LiveDetail §2.17)

extension LiveSnapshot {
    /// The `-demo-data` live conversation: the artboard's turns and quiet marker, plus one
    /// reply and one loss marker so a review build exercises the two speaker colors, the
    /// clock stamps, and the missing-audio row.
    static func demo(isLive: Bool, now: Date = .now) -> LiveSnapshot {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        return LiveSnapshot(
            startedLine: Copy.Live.startedLine(time: "12:04 PM", elapsed: "48 min"),
            isLive: isLive,
            items: [
                .turn(
                    TranscriptTurn(
                        id: "t1", speakerLabel: "S1", name: "Roger", role: .you,
                        text: "The settings pages each push from one clean root instead of the "
                            + "giant scroll.",
                        startedAt: at(12, 31)
                    )),
                .quiet(
                    TranscriptMarker(
                        id: "q1", text: Copy.Conversation.quietFor("2 min"),
                        startedAt: at(12, 33))),
                .turn(
                    TranscriptTurn(
                        id: "t2", speakerLabel: "S1", name: "Roger", role: .you,
                        text: "Okay, and the tag editor gets the rename cursor —",
                        startedAt: at(12, 42)
                    )),
                .turn(
                    TranscriptTurn(
                        id: "t3", speakerLabel: "S2", name: "Dana", role: .other,
                        text: "That one I want to try on the watch before we commit to it.",
                        startedAt: at(12, 42)
                    )),
                .missing(
                    TranscriptMarker(
                        id: "m1", text: Copy.Conversation.missingMarker("2 sec"),
                        startedAt: at(12, 49))),
                .turn(
                    TranscriptTurn(
                        id: "t4", speakerLabel: "", name: "Speaker", role: .unresolved,
                        text: "so the suggestions row can stay under the field…",
                        startedAt: at(12, 51), isInProgress: true
                    )),
            ]
        )
    }
}
