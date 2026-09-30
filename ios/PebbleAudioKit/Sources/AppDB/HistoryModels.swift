import Foundation

// The shapes the History tab reads (docs/redesign/2026-09-30-history-tab-plan.md, 7.10).
//
// These are the contract between the read side that produces them (`HistoryDayBuilder`, the
// week/month queries) and the screen that draws them. They carry facts and machine-readable
// kinds only — no display strings. Every word the user reads is chosen by the app's copy from
// these values, so nothing here can make a claim the data does not support.
//
// All times are epoch milliseconds on the wall clock. Day keys are `LogicalDay` keys
// ("YYYY-MM-DD", 5 AM → 5 AM) in the zone the moment was recorded in (`ZoneTimeline`).

// MARK: - Day

/// One logical day as a timeline.
///
/// Invariants (enforced by `HistoryDayHonestyTests`):
/// - `items` are in time order and tile `[items.first.startMs, items.last.endMs)` exactly: no
///   overlap and no hole. A `.zoneChange` item has no length and sits between two others.
/// - Loss is never reduced and never relabelled: the sum of `.audioMissing` gaps plus every
///   chapter's and gap's `missingMs` is at least the missing time the coverage computer reports
///   for the same span. It is never drawn as quiet, and suppressed silence is never drawn as missing.
/// - Time with no audio and no record of why is `.notRecording`, never `.quiet`.
/// - A recording that failed or has not been transcribed is never inside a chapter.
public struct HistoryDay: Equatable, Sendable {
    public var dateKey: String
    /// The zone of the day's first moment; the screen's title is formatted in it.
    public var zoneID: String
    public var isToday: Bool
    /// False when nothing at all was recorded on this day ("Nothing recorded"); `items` is
    /// then empty and both edges are nil.
    public var hasRecordings: Bool
    /// The compressed stretch before the first item ("Quiet until 8:12 AM"). Nil when the
    /// first item starts at the day's start, or when there are no items.
    public var leadingEdge: HistoryEdge?
    public var items: [HistoryItem]
    /// The compressed stretch after the last item ("Quiet after 9:44 PM"). Always nil on today.
    public var trailingEdge: HistoryEdge?

    public init(
        dateKey: String, zoneID: String, isToday: Bool, hasRecordings: Bool,
        leadingEdge: HistoryEdge?, items: [HistoryItem], trailingEdge: HistoryEdge?
    ) {
        self.dateKey = dateKey
        self.zoneID = zoneID
        self.isToday = isToday
        self.hasRecordings = hasRecordings
        self.leadingEdge = leadingEdge
        self.items = items
        self.trailingEdge = trailingEdge
    }
}

/// The one place the day's time is compressed: everything before the first item, or after the
/// last. Only calm time is ever folded into an edge — quiet, the watch's own power-save pause,
/// and time nothing was recording. Loss, a pause the user made, and anything openable are
/// items, never part of an edge.
public struct HistoryEdge: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Mostly known-quiet time (the watch was listening and heard nothing).
        case quiet
        /// Mostly time nobody was listening: the watch resting in power save, or no recording
        /// at all. The copy must not call this "quiet".
        case notListening
    }
    /// Where the timeline proper begins (leading) or ends (trailing).
    public var atMs: Int64
    public var kind: Kind

    public init(atMs: Int64, kind: Kind) {
        self.atMs = atMs
        self.kind = kind
    }
}

public enum HistoryItem: Equatable, Sendable, Identifiable {
    case chapter(HistoryChapterBlock)
    case gap(HistoryGap)
    case zoneChange(HistoryZoneChange)
    case live(HistoryLiveBlock)

    public var id: String {
        switch self {
        case .chapter(let block): return block.id
        case .gap(let gap): return gap.id
        case .zoneChange(let change): return "zone-\(change.atMs)"
        case .live: return "live"
        }
    }

    public var startMs: Int64 {
        switch self {
        case .chapter(let block): return block.startMs
        case .gap(let gap): return gap.startMs
        case .zoneChange(let change): return change.atMs
        case .live(let live): return live.startMs
        }
    }

    public var endMs: Int64 {
        switch self {
        case .chapter(let block): return block.endMs
        case .gap(let gap): return gap.endMs
        case .zoneChange(let change): return change.atMs
        case .live(let live): return live.endMs
        }
    }
}

/// A card on the day: a stretch of talk.
public struct HistoryChapterBlock: Equatable, Sendable, Identifiable {
    public enum Source: String, Sendable {
        /// A chapter the builder was handed (`HistoryChapterInput`): since conversations became
        /// topic-sized, a conversation — its title, summary and tags, and a snippet while it
        /// has no title yet.
        case chapter
        /// No chapter covers this talk yet (or AI is off): the card is a stretch of talk cut
        /// where the talk really stopped (`HistoryTalkCutter`). It carries no title (the
        /// grouper's conversations are not conversation-sized) — its `snippet` instead.
        case conversation
    }
    public var id: String
    public var startMs: Int64
    public var endMs: Int64
    public var zoneID: String
    public var source: Source
    /// Nil when there is no title to show (an untitled conversation stretch).
    public var title: String?
    public var summary: String?
    /// For a card with no title (`isUntitled`) — a stretch no chapter covers, or a chapter
    /// whose title has not been written yet: the first substantive thing that was said in it,
    /// verbatim from the transcript. Nil for a titled card.
    public var snippet: String?
    public var tags: [String]
    public var people: [String]
    /// Audio lost inside the card's range ("· 4 min missing"). Never a separate item.
    public var missingMs: Int64
    /// True when the times come from a recording whose clock is not exact ("about …").
    public var timesApproximate: Bool
    /// Already in display order: open first, then done, each by time.
    public var followUps: [HistoryFollowUpLine]
    /// The chapter this card is a piece of (`HistoryChapterInput.id`) — since conversations
    /// are topic-sized, the CONVERSATION's id — for every piece of it, the first (whose `id` it
    /// is) and the ones after a barrier (`<id>~<start>`). Nil for a stretch no chapter covers.
    ///
    /// A card's tap has to open this conversation, and its `startMs` alone cannot say so: the
    /// day's tidying can fold a few seconds of quiet in front of a card, and those seconds
    /// belong to the conversation before it — in the same recording, more often than not.
    public var chapterId: String?

    /// No title to show: the card leads with its time range and quotes its `snippet`. The same
    /// rule the app's card draws by (`HistoryLabels.isUntitled`).
    public var isUntitled: Bool { title?.isEmpty ?? true }

    public init(
        id: String, startMs: Int64, endMs: Int64, zoneID: String, source: Source,
        title: String?, summary: String?, snippet: String? = nil, tags: [String] = [], people: [String] = [],
        missingMs: Int64 = 0, timesApproximate: Bool = false,
        followUps: [HistoryFollowUpLine] = [], chapterId: String? = nil
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.zoneID = zoneID
        self.source = source
        self.title = title
        self.summary = summary
        self.snippet = snippet
        self.tags = tags
        self.people = people
        self.missingMs = missingMs
        self.timesApproximate = timesApproximate
        self.followUps = followUps
        self.chapterId = chapterId
    }
}

/// Time on the day that is not a card, and what it was.
public struct HistoryGap: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The watch was listening and heard nothing.
        case quiet
        /// Capture was paused: by the user, a timed pause, or the watch's own power save.
        case paused
        /// Audio was lost.
        case audioMissing
        /// No audio and no record of why (the watch was off, or capture was switched off).
        case notRecording
        /// Sound was recorded but holds no conversation.
        case noConversation
        /// Recorded, waiting for a transcript.
        case notTranscribedYet
        /// Recorded; transcription failed.
        case transcriptionFailed
        /// The recording was deleted.
        case deleted
    }

    public var id: String
    public var kind: Kind
    public var startMs: Int64
    public var endMs: Int64
    public var zoneID: String
    /// Set for `.paused`.
    public var pausedBy: HistoryPauseActor?
    /// Set for `.audioMissing`: the recorded causes, largest share of the gap first. Empty when
    /// no record says why. Never a guess. Also set on any gap with `missingMs > 0`, for that loss.
    public var lossCauses: [HistoryLossCause]
    /// Audio lost inside this gap that is not drawn as its own `.audioMissing` item ("· 4 s
    /// missing"), exactly as on a card. Always 0 for `.audioMissing` itself (its whole range is
    /// the loss). Non-zero only under `HistoryDayRules.carryShortLoss` (the default); a gap that
    /// carries loss is never folded into an edge or the live block.
    public var missingMs: Int64 = 0
    /// Set for `.noConversation` ONLY when the audio classifier supplied one that met its
    /// accuracy bar ("music", "TV or video"). Nil means "No conversation", styled like quiet.
    public var descriptor: String?
    /// Set for `.deleted`.
    public var deletedBy: HistoryDeletionCause?
    /// Set for `.transcriptionFailed` when the failure has a recorded reason.
    public var failureReason: String?
    /// True when there is audio behind the gap that can be opened.
    public var isOpenable: Bool

    public init(
        id: String, kind: Kind, startMs: Int64, endMs: Int64, zoneID: String,
        pausedBy: HistoryPauseActor? = nil, lossCauses: [HistoryLossCause] = [],
        descriptor: String? = nil, deletedBy: HistoryDeletionCause? = nil,
        failureReason: String? = nil, isOpenable: Bool = false, missingMs: Int64 = 0
    ) {
        self.id = id
        self.kind = kind
        self.startMs = startMs
        self.endMs = endMs
        self.zoneID = zoneID
        self.pausedBy = pausedBy
        self.lossCauses = lossCauses
        self.descriptor = descriptor
        self.deletedBy = deletedBy
        self.failureReason = failureReason
        self.isOpenable = isOpenable
        self.missingMs = missingMs
    }
}

public enum HistoryPauseActor: String, Sendable {
    /// The user paused from the phone (status card, Live screen, a Shortcut, Settings).
    case you
    /// A timed pause the user set.
    case timed
    /// The watch muted itself to save power while it was not being worn.
    case watchPowerSave
    /// Any other recorded source.
    case other
}

/// A recorded cause of lost audio. One case per thing a gap record can say; nothing inferred.
public enum HistoryLossCause: String, Sendable, CaseIterable {
    /// The watch's buffer filled while it could not reach the phone.
    case watchBufferFull
    /// Watch dictation had the microphone.
    case watchDictation
    /// Capture was stopped on the watch.
    case stoppedOnWatch
    /// The watch paused capture for its battery.
    case watchBattery
    /// The watch's encoder faulted.
    case watchAudioFault
    /// The connection was reset.
    case connectionReset
    /// Frames the phone never received, with no report from the watch.
    case phoneMissedAudio
}

public enum HistoryDeletionCause: String, Sendable {
    case user
    case retention
}

/// A change of time zone inside the day (travel). No length; hour labels after it use `zoneID`.
public struct HistoryZoneChange: Equatable, Sendable {
    public var atMs: Int64
    public var zoneID: String

    public init(atMs: Int64, zoneID: String) {
        self.atMs = atMs
        self.zoneID = zoneID
    }
}

/// The end of today's timeline while recording: the talk that has not settled into a card yet.
/// The words on it come from the live transcript, not from here.
public struct HistoryLiveBlock: Equatable, Sendable {
    public var startMs: Int64
    /// "Now" when the day was built.
    public var endMs: Int64
    public var zoneID: String

    public init(startMs: Int64, endMs: Int64, zoneID: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.zoneID = zoneID
    }
}

public struct HistoryFollowUpLine: Equatable, Sendable, Identifiable {
    public let id: String
    public var text: String
    public var done: Bool
    public var isSnoozed: Bool
    /// True when the moment it was said is only known roughly.
    public var isApproximate: Bool

    public init(id: String, text: String, done: Bool, isSnoozed: Bool = false, isApproximate: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
        self.isSnoozed = isSnoozed
        self.isApproximate = isApproximate
    }
}

// MARK: - Briefs

/// The AI summary at the top of a day, week or month.
public struct HistoryBrief: Equatable, Sendable {
    public var text: String
    public var headline: String?
    public var lineSummary: String?
    public var updatedAtMs: Int64

    public init(text: String, headline: String? = nil, lineSummary: String? = nil, updatedAtMs: Int64) {
        self.text = text
        self.headline = headline
        self.lineSummary = lineSummary
        self.updatedAtMs = updatedAtMs
    }
}

// MARK: - Week and month

public enum HistoryDayState: Equatable, Sendable {
    case nothingRecorded
    case recorded
    /// Recorded, but nothing of it is transcribed yet.
    case notTranscribedYet(waitingMs: Int64)
    case today(isLive: Bool)
}

/// One day on the week page.
public struct HistoryWeekRow: Equatable, Sendable, Identifiable {
    public var dateKey: String
    public var state: HistoryDayState
    public var headline: String?
    public var summary: String?
    /// At most three.
    public var tags: [String]
    /// At most two, open first.
    public var followUps: [HistoryFollowUpLine]
    /// Follow-ups of the day not shown in `followUps`, open or done.
    public var moreFollowUps: Int
    public var id: String { dateKey }

    public init(
        dateKey: String, state: HistoryDayState, headline: String? = nil, summary: String? = nil,
        tags: [String] = [], followUps: [HistoryFollowUpLine] = [], moreFollowUps: Int = 0
    ) {
        self.dateKey = dateKey
        self.state = state
        self.headline = headline
        self.summary = summary
        self.tags = tags
        self.followUps = followUps
        self.moreFollowUps = moreFollowUps
    }
}

/// One week on the month page.
public struct HistoryMonthRow: Equatable, Sendable, Identifiable {
    public var firstDateKey: String
    public var lastDateKey: String
    public var isCurrentWeek: Bool
    public var hasRecordings: Bool
    public var headline: String?
    public var summary: String?
    /// At most three.
    public var tags: [String]
    public var followUpTotal: Int
    public var followUpOpen: Int
    public var id: String { firstDateKey }

    public init(
        firstDateKey: String, lastDateKey: String, isCurrentWeek: Bool, hasRecordings: Bool,
        headline: String? = nil, summary: String? = nil, tags: [String] = [],
        followUpTotal: Int = 0, followUpOpen: Int = 0
    ) {
        self.firstDateKey = firstDateKey
        self.lastDateKey = lastDateKey
        self.isCurrentWeek = isCurrentWeek
        self.hasRecordings = hasRecordings
        self.headline = headline
        self.summary = summary
        self.tags = tags
        self.followUpTotal = followUpTotal
        self.followUpOpen = followUpOpen
    }
}

public struct HistoryTagCount: Equatable, Sendable, Identifiable {
    public var name: String
    /// The number of days in the period the tag appears on.
    public var days: Int
    public var id: String { name }

    public init(name: String, days: Int) {
        self.name = name
        self.days = days
    }
}

/// A week (rows are days) or a month (rows are weeks).
public struct HistoryPeriod<Row: Equatable & Sendable>: Equatable, Sendable {
    public var firstDateKey: String
    public var lastDateKey: String
    public var brief: HistoryBrief?
    /// Month only; empty on a week.
    public var tagCounts: [HistoryTagCount]
    public var rows: [Row]
    public var followUpTotal: Int
    public var followUpOpen: Int

    public init(
        firstDateKey: String, lastDateKey: String, brief: HistoryBrief? = nil,
        tagCounts: [HistoryTagCount] = [], rows: [Row], followUpTotal: Int = 0, followUpOpen: Int = 0
    ) {
        self.firstDateKey = firstDateKey
        self.lastDateKey = lastDateKey
        self.brief = brief
        self.tagCounts = tagCounts
        self.rows = rows
        self.followUpTotal = followUpTotal
        self.followUpOpen = followUpOpen
    }
}

/// What the pager needs to know about the whole archive.
public struct HistoryBounds: Equatable, Sendable {
    /// Nil when nothing has ever been recorded.
    public var firstDateKey: String?
    public var todayDateKey: String
    /// Day keys that have at least one recording.
    public var recordedDays: Set<String>

    public init(firstDateKey: String?, todayDateKey: String, recordedDays: Set<String>) {
        self.firstDateKey = firstDateKey
        self.todayDateKey = todayDateKey
        self.recordedDays = recordedDays
    }
}
