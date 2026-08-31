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
    /// The growing tail: dimmed text, `captured` speaker marker.
    var isInProgress: Bool = false
}

/// Transcript stream items in display order — turns with inline quiet markers where they
/// happened (never banners).
enum LiveTranscriptItem: Equatable, Identifiable {
    case turn(LiveTurn)
    /// e.g. "quiet for 2 min".
    case quiet(id: String, text: String)

    var id: String {
        switch self {
        case .turn(let turn): return turn.id
        case .quiet(let id, _): return id
        }
    }
}

struct LiveSnapshot: Equatable {
    /// e.g. "Started 12:04 PM · 48 min so far".
    var startedLine: String
    /// False once the conversation ended (paused/stopped) — the screen pops back.
    var isLive: Bool
    var items: [LiveTranscriptItem]
}

/// The live screen's read + transport surface; mirrors `TodayDataSource`'s seam.
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
