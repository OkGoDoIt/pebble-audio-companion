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
    /// The conversation this screen is watching being written. It is the SAME id the Library
    /// will show once it ends, which is what lets the live screen offer the conversation's own
    /// affordances — the AI summary, Ask, Notes, Follow-ups — instead of being a transcript
    /// with two buttons under it. Empty when nothing is being recorded.
    ///
    /// `ConversationGrouper.adoptStableIds` keeps the id across the regroup that closes the
    /// conversation, so anything opened from here is still valid after Pause or Stop.
    var conversationId: String = ""
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
    /// The AI summary as it stands. A live conversation genuinely has one: `EnrichmentWorker`
    /// runs a PROVISIONAL pass on an open conversation once there are `liveMinChars` of text,
    /// and rewrites it as the text grows. Nil until that first pass lands — and nil renders
    /// nothing at all, never an empty card.
    var summary: String?
    /// The growing timeline at the top of the screen. Nil while there is nothing to draw.
    var timeline: LiveTimelineDisplay?
}

/// The live read + transport surface; mirrors `TodayDataSource`'s seam.
@MainActor
protocol LiveDataSource: AnyObject {
    func liveSnapshot() -> LiveSnapshot
    /// Yields the current snapshot immediately, then every change.
    func liveUpdates() -> AsyncStream<LiveSnapshot>

    // Both of these END THE CONVERSATION (Q13 — the watch mints a fresh stream id on resume,
    // and `ConversationGrouper` splits on a pause interval or a user stop). The difference is
    // only what happens to CAPTURE afterwards, which is exactly what the transport bar's two
    // sublines have to say out loud: Roger reported not knowing what separates them.

    /// Capture goes to `.paused`: the receiver stays up, the watch is asked to pause, and a
    /// pause interval opens in the journal so the window draws as paused rather than missing.
    /// Resume is one tap on Today's status card.
    func requestPause()
    /// Capture goes to `.off`: `ReceiverService` closes any open pause interval and tears the
    /// receive path down. Nothing is captured again until an explicit Start.
    func requestStop()
}

// MARK: - Artboard sample content (LiveDetail §2.17)

extension LiveSnapshot {
    /// The `-demo-data` live conversation: the artboard's turns and quiet marker, plus one
    /// reply and one loss marker so a review build exercises the two speaker colors, the
    /// clock stamps, and the missing-audio row.
    ///
    /// The id is the one `MockWorld` and `PreviewTodayData` both use for the live row, so the
    /// screen's AI actions reach a conversation that exists in the mock world too — a demo
    /// [Ask] that scoped to a conversation nobody had heard of would be its own kind of stub.
    static func demo(isLive: Bool, now: Date = .now) -> LiveSnapshot {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        return LiveSnapshot(
            conversationId: "app-redesign",
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
            ],
            // A PROVISIONAL summary: the artboard has to show what the live enrichment pass
            // actually produces, so the caption under it ("rewritten as this keeps going")
            // has something to caption.
            summary: "Working through the redesign: settings push from one root, and the tag "
                + "editor is getting an inline rename.",
            timeline: .demo
        )
    }
}

extension LiveTimelineDisplay {
    /// The demo timeline over the artboard conversation's own span (12:04 PM → 12:52 PM, so
    /// 2880 s wide): recorded, the 2-minute quiet at 12:33, and the 2-second loss at 12:49 —
    /// the same three events the transcript above it names, so the strip and the words agree.
    ///
    /// The fractions are the real arithmetic, including a loss span that is 0.07% of the width:
    /// `CoverageStrip` floors every span at one point, and a demo that widened the gap to make
    /// it pretty would hide exactly the case the component has to survive.
    static let demo = LiveTimelineDisplay(
        headline: Copy.Today.recorded("45 min"),
        missingText: Copy.Today.missing("2 sec"),
        startLabel: "12:04 PM",
        spans: [
            CoverageSpanDisplay(
                span: CoverageSpan(kind: .recorded, range: 0...0.604167),
                popoverText: "recorded 12:04 PM–12:33 PM"),
            CoverageSpanDisplay(
                span: CoverageSpan(kind: .quiet, range: 0.604167...0.645833),
                popoverText: Copy.Popover.quietSpan("12:33 PM–12:35 PM")),
            CoverageSpanDisplay(
                span: CoverageSpan(kind: .recorded, range: 0.645833...0.9375),
                popoverText: "recorded 12:35 PM–12:49 PM"),
            CoverageSpanDisplay(
                span: CoverageSpan(kind: .missing, range: 0.9375...0.938194),
                popoverText: Copy.Popover.missingSpan("2 sec")),
            CoverageSpanDisplay(
                span: CoverageSpan(kind: .recorded, range: 0.938194...1),
                popoverText: "recorded 12:49 PM–12:52 PM"),
        ]
    )
}
