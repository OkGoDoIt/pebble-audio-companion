import Foundation

// Display models for the Live Conversation screen (LiveDetail artboard, extraction §2.17).

/// Speaker identity coloring (extraction §3): you = tint, other = teal, unresolved =
/// `captured` marker with dimmed text.
enum LiveSpeaker: Equatable {
    case you(String)
    case other(String)
    /// Diarization hasn't resolved this voice yet; rendered as a `captured`-colored "·".
    case unresolved
}

struct LiveTurn: Equatable, Identifiable {
    let id: String
    let speaker: LiveSpeaker
    let text: String
    /// Wall-clock start of this turn — the stamp shown in the leading time rail. Formatted in
    /// `LiveSnapshot.timeZone` (Q16), never here. Nil while the turn's start isn't yet known.
    var startedAt: Date?
    /// The growing tail: dimmed text, `captured` speaker marker, and deliberately NO clock
    /// stamp — its text is still being revised, so a final-looking time would be a lie.
    var isInProgress: Bool = false
}

/// A non-speech row in the live transcript. Loss and quiet are never conflated: `quiet` is calm
/// known-silence (VAD-skipped or simply nobody talking), `missing` is genuine loss.
struct LiveMarker: Equatable, Identifiable {
    enum Kind: Equatable {
        case quiet
        case missing
    }

    let id: String
    /// e.g. "quiet for 2 min" / "2 sec missing · Bluetooth hiccup".
    let text: String
    var kind: Kind = .quiet
    var startedAt: Date?
}

/// Transcript stream items in display order — turns with inline quiet/missing markers where
/// they happened (never banners).
enum LiveTranscriptItem: Equatable, Identifiable {
    case turn(LiveTurn)
    case marker(LiveMarker)

    var id: String {
        switch self {
        case .turn(let turn): return turn.id
        case .marker(let marker): return marker.id
        }
    }

    /// The moment this row belongs to, or nil when it must not carry a stamp.
    var stampedAt: Date? {
        switch self {
        case .turn(let turn): return turn.isInProgress ? nil : turn.startedAt
        case .marker(let marker): return marker.startedAt
        }
    }
}

struct LiveSnapshot: Equatable {
    /// e.g. "Started 12:04 PM · 48 min so far".
    var startedLine: String
    /// False once the conversation ended (paused/stopped) — the screen pops back.
    var isLive: Bool
    var items: [LiveTranscriptItem]
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
    /// repeated-minute suppression in the time rail, and the missing-audio row.
    static func demo(isLive: Bool, now: Date = .now) -> LiveSnapshot {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: now
            ) ?? now
        }
        return LiveSnapshot(
            startedLine: Copy.Live.startedLine(time: "12:04 PM", elapsed: "48 min"),
            isLive: isLive,
            items: Array<LiveTranscriptItem>().isEmpty ? [] : [
                .turn(
                    LiveTurn(
                        id: "t1", speaker: .you("Roger"),
                        text: "The settings pages each push from one clean root instead of the "
                            + "giant scroll.",
                        startedAt: at(12, 31)
                    )),
                .marker(
                    LiveMarker(
                        id: "q1", text: Copy.Conversation.quietFor("2 min"),
                        kind: .quiet, startedAt: at(12, 33)
                    )),
                .turn(
                    LiveTurn(
                        id: "t2", speaker: .you("Roger"),
                        text: "Okay, and the tag editor gets the rename cursor —",
                        startedAt: at(12, 42)
                    )),
                .turn(
                    LiveTurn(
                        id: "t3", speaker: .other("Dana"),
                        text: "That one I want to try on the watch before we commit to it.",
                        startedAt: at(12, 42)
                    )),
                .marker(
                    LiveMarker(
                        id: "m1", text: Copy.Conversation.missingMarker("2 sec"),
                        kind: .missing, startedAt: at(12, 49)
                    )),
                .turn(
                    LiveTurn(
                        id: "t4", speaker: .unresolved,
                        text: "so the suggestions row can stay under the field…",
                        startedAt: at(12, 51), isInProgress: true
                    )),
            ]
        )
    }
}
