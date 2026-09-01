import Foundation

// Display models for the Live Conversation screen (LiveDetail artboard, extraction §2.17).
//
// The transcript itself is NOT a separate model any more: the live screen renders the same
// `TranscriptItem`s the Conversation screen does, because a live conversation is that
// conversation — it just happens to be appending at the bottom.

/// What is true about the live transcript right now, when it is not simply arriving.
///
/// The screen used to render ONE calm line — "Listening — words appear here as they are
/// recognized" — for every reason a transcript can be empty at once: audio arriving and not yet
/// recognised, a watch sending nothing at all, transcription never set up, a live engine that
/// has stopped working. Roger watched that line for nineteen minutes while no audio had reached
/// the phone for eleven of them, and the app's only claim was "Live". Each of these says which.
enum LiveTranscriptStatus: Equatable {
    /// Audio is arriving; nothing has been recognised yet. The original, and now the only case
    /// the calm line describes.
    case listening
    /// The watch is capturing and deliberately sending nothing — voice-activity silence. Calm,
    /// and never to be confused with loss (Q6).
    case quiet
    /// Nothing is reaching the phone. The watch keeps what it captures and re-sends it.
    case notHearingWatch
    /// Transcription was never set up, so no words will appear here for any recording.
    case transcriptsOff
    /// Audio is arriving and the live engine is not producing text — a cloud socket that keeps
    /// failing, or an on-device pass that keeps throwing.
    case liveTranscriptionDown

    /// The one line the card shows.
    var line: String {
        switch self {
        case .listening: return Copy.Live.waiting
        case .quiet: return Copy.Live.quiet
        case .notHearingWatch: return Copy.Live.notHearing
        case .transcriptsOff: return Copy.Live.transcriptsOff
        case .liveTranscriptionDown: return Copy.Live.transcriptionDown
        }
    }

    /// True while nothing is wrong — the transcript is simply young. Everything else is worth
    /// saying even once words are on screen, because it explains why they stopped.
    var isUneventful: Bool { self == .listening }

    /// The Today row's version: the same answer, short enough for one line under a title, and
    /// nil while the honest thing to say is "nothing yet" — Today has the status card directly
    /// above it for that, and two calm sentences saying the same nothing is noise.
    var rowLine: String? {
        switch self {
        case .listening: return nil
        case .quiet: return Copy.Today.liveQuiet
        case .notHearingWatch: return Copy.Today.liveNotHearing
        case .transcriptsOff: return Copy.Today.liveTranscriptsOff
        case .liveTranscriptionDown: return Copy.Today.liveTranscriptionDown
        }
    }
}

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
    /// Why there is nothing new to show — see `LiveTranscriptStatus`.
    var status: LiveTranscriptStatus = .listening
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
