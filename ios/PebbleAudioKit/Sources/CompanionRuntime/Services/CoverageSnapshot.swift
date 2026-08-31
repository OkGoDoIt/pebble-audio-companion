import AppDB
import Foundation
import StatusUI

// Plan 6.8 — the App Group hand-off to the widget. The widget renders from THIS FILE ALONE: it
// never opens the database, never reads the segment directory, and never runs the coverage
// computation itself.

/// `coverage_snapshot.json` — the live capture state, the current conversation, the recent
/// activity profile, open follow-ups, and today's coverage spans.
///
/// ## JSON contract (v2)
/// ```json
/// {
///   "version": 2,
///   "generatedAtMs": 1756512000000,
///   "dateKey": "2026-08-30",
///   "timeZoneID": "America/Los_Angeles",
///   "dayStartMs": 1756472400000,   // 5 AM logical-day start, in timeZoneID
///   "nowMs": 1756512000000,        // right edge of the strip; never in the future
///   "spans": [ { "kind": "recorded", "startMs": …, "endMs": … } ],
///   "totalRecordedMs": 5400000,
///   "totalMissingMs": 0,
///   "headline": "Recording",
///   "detail": "Pebble Time 2 · connected",
///   "dot": "active",               // neutral | info | active | attention | problem | consent
///   "isRecording": true,
///   // --- v2 ---
///   "state": "recording",          // StatusFamily, machine-readable (see `stateValue`)
///   "currentStartedAtMs": 1756509600000,   // start of the running stretch, or absent
///   "liveTitle": "Standup",
///   "liveLine": "…let's push the release to Thursday.",
///   "activity": [ { "kind": "recorded", "level": 0.82 } ],  // oldest → newest
///   "activityWindowMs": 600000,
///   "followUps": [ { "id": "…", "text": "…", "conversationId": "…" } ],
///   "openFollowUpCount": 4
/// }
/// ```
///
/// `kind` is `CoverageKind`'s raw value: `recorded` · `missing` · `quiet` · `paused` · `off`.
/// Spans are ordered, non-overlapping, and cover `[dayStartMs, nowMs)` exactly.
///
/// Compatibility rule: **`version` is the widget's only layout selector.** Add fields with
/// defaults and leave `version` alone; bump it only when an existing field changes meaning.
/// v2 bumped it because `state` gives the widget a claim v1 could not make — an older widget
/// binary must be able to tell "this file does not know" from "nothing is happening".
public struct CoverageSnapshot: Codable, Equatable, Sendable {
    public static let fileName = "coverage_snapshot.json"
    public static let currentVersion = 2

    /// One bucket of the recent-activity profile. NOT an audio waveform: the writer runs on
    /// Bluetooth wakes and must not Speex-decode audio, and a decoded waveform would freeze
    /// the moment the app suspended. `level` is the share of the bucket that carried
    /// voice-detected audio, which is both cheap (it comes off the spans already computed)
    /// and true when the app is asleep.
    public struct ActivityBar: Codable, Equatable, Sendable {
        public var kind: CoverageKind
        /// 0…1 — the fraction of this bucket that was recorded audio.
        public var level: Double

        public init(kind: CoverageKind, level: Double) {
            self.kind = kind
            self.level = min(max(level, 0), 1)
        }
    }

    /// An open follow-up, trimmed to what a widget row can show.
    public struct FollowUpRef: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var conversationId: String?

        public init(id: String, text: String, conversationId: String? = nil) {
            self.id = id
            self.text = text
            self.conversationId = conversationId
        }
    }

    public var version: Int
    public var generatedAtMs: Int64
    /// Logical-day key (5 AM boundary) in `timeZoneID`.
    public var dateKey: String
    public var timeZoneID: String
    public var dayStartMs: Int64
    /// The strip's right edge — "now", clamped into the logical day.
    public var nowMs: Int64
    public var spans: [CoverageSpan]
    public var totalRecordedMs: Int64
    public var totalMissingMs: Int64
    /// Status-card headline, already in approved plain language (never protocol vocabulary).
    public var headline: String
    public var detail: String?
    /// `StatusDot` as a lowercase string, so the widget needs no StatusUI import:
    /// `neutral` · `info` · `active` · `attention` · `problem` · `consent`.
    public var dot: String
    public var isRecording: Bool

    // --- v2 ---------------------------------------------------------------------------------

    /// `StatusFamily` as a lowercase string, so the widget picks a layout without parsing the
    /// prose headline (which is written for people and must never be pattern-matched).
    public var state: String
    /// Start of the stretch of capture that is still running, or nil when nothing is running.
    /// The widget renders elapsed time from this with a self-ticking timer — no extra reloads.
    public var currentStartedAtMs: Int64?
    /// Title of the conversation being recorded right now (nil until enrichment names it).
    public var liveTitle: String?
    /// The most recent line of transcript in that conversation.
    public var liveLine: String?
    /// Recent-activity buckets, oldest → newest, covering `activityWindowMs` ending at `nowMs`.
    public var activity: [ActivityBar]
    public var activityWindowMs: Int64
    /// The first few open follow-ups, newest first.
    public var followUps: [FollowUpRef]
    /// How many are open in total (`followUps` is only the head of the list).
    public var openFollowUpCount: Int

    public init(
        version: Int = CoverageSnapshot.currentVersion,
        generatedAtMs: Int64,
        dateKey: String,
        timeZoneID: String,
        dayStartMs: Int64,
        nowMs: Int64,
        spans: [CoverageSpan],
        totalRecordedMs: Int64,
        totalMissingMs: Int64,
        headline: String,
        detail: String? = nil,
        dot: String,
        isRecording: Bool,
        state: String = "",
        currentStartedAtMs: Int64? = nil,
        liveTitle: String? = nil,
        liveLine: String? = nil,
        activity: [ActivityBar] = [],
        activityWindowMs: Int64 = 0,
        followUps: [FollowUpRef] = [],
        openFollowUpCount: Int = 0
    ) {
        self.version = version
        self.generatedAtMs = generatedAtMs
        self.dateKey = dateKey
        self.timeZoneID = timeZoneID
        self.dayStartMs = dayStartMs
        self.nowMs = nowMs
        self.spans = spans
        self.totalRecordedMs = totalRecordedMs
        self.totalMissingMs = totalMissingMs
        self.headline = headline
        self.detail = detail
        self.dot = dot
        self.isRecording = isRecording
        self.state = state
        self.currentStartedAtMs = currentStartedAtMs
        self.liveTitle = liveTitle
        self.liveLine = liveLine
        self.activity = activity
        self.activityWindowMs = activityWindowMs
        self.followUps = followUps
        self.openFollowUpCount = openFollowUpCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        generatedAtMs = try c.decodeIfPresent(Int64.self, forKey: .generatedAtMs) ?? 0
        dateKey = try c.decodeIfPresent(String.self, forKey: .dateKey) ?? ""
        timeZoneID = try c.decodeIfPresent(String.self, forKey: .timeZoneID)
            ?? TimeZone.current.identifier
        dayStartMs = try c.decodeIfPresent(Int64.self, forKey: .dayStartMs) ?? 0
        nowMs = try c.decodeIfPresent(Int64.self, forKey: .nowMs) ?? 0
        spans = try c.decodeIfPresent([CoverageSpan].self, forKey: .spans) ?? []
        totalRecordedMs = try c.decodeIfPresent(Int64.self, forKey: .totalRecordedMs) ?? 0
        totalMissingMs = try c.decodeIfPresent(Int64.self, forKey: .totalMissingMs) ?? 0
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        dot = try c.decodeIfPresent(String.self, forKey: .dot) ?? "neutral"
        isRecording = try c.decodeIfPresent(Bool.self, forKey: .isRecording) ?? false
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        currentStartedAtMs = try c.decodeIfPresent(Int64.self, forKey: .currentStartedAtMs)
        liveTitle = try c.decodeIfPresent(String.self, forKey: .liveTitle)
        liveLine = try c.decodeIfPresent(String.self, forKey: .liveLine)
        activity = try c.decodeIfPresent([ActivityBar].self, forKey: .activity) ?? []
        activityWindowMs = try c.decodeIfPresent(Int64.self, forKey: .activityWindowMs) ?? 0
        followUps = try c.decodeIfPresent([FollowUpRef].self, forKey: .followUps) ?? []
        openFollowUpCount = try c.decodeIfPresent(Int.self, forKey: .openFollowUpCount) ?? 0
    }
}

extension StatusFamily {
    /// Stable wire spelling for `CoverageSnapshot.state`. Mirrored by the widget's
    /// `CoverageSnapshot.State` — the two lists must stay in step.
    public var snapshotValue: String {
        switch self {
        case .recording: return "recording"
        case .paused: return "paused"
        case .reconnecting: return "reconnecting"
        case .connecting: return "connecting"
        case .bluetoothOff: return "bluetoothOff"
        case .notRecording: return "notRecording"
        case .confirmOnWatch: return "confirmOnWatch"
        case .transcriptsOff: return "transcriptsOff"
        case .needsAttention: return "needsAttention"
        }
    }
}

extension StatusDot {
    /// Stable wire spelling for `CoverageSnapshot.dot`.
    public var snapshotValue: String {
        switch self {
        case .neutral: return "neutral"
        case .info: return "info"
        case .active: return "active"
        case .attention: return "attention"
        case .problem: return "problem"
        case .consent: return "consent"
        }
    }
}

/// The reasons a snapshot gets rewritten (plan 6.8: segment close, pause events, app background).
public enum CoverageSnapshotTrigger: String, Sendable, Equatable, CaseIterable {
    case segmentClosed
    case pauseChanged
    case appBackgrounded
    /// Explicit refresh (startup, foreground entry, retention cascade) — not one of the three
    /// required triggers, but harmless and keeps the widget honest after a delete.
    case manual
    /// The rate-limited write at the end of a pipeline pass. The three required triggers are
    /// events; this one is the heartbeat that keeps a widget current *between* them, so a
    /// conversation that has been running for an hour without rotating a segment does not age
    /// into "as of 10:14".
    case pipelinePass
}

/// Closes a construction-order loop: `ReceiverService` is built BEFORE
/// `CoverageSnapshotService` (the receiver's state is one of the inputs to the status the
/// snapshot carries), so the trigger the receiver fires on segment open/close cannot be handed
/// to it at construction. The receiver fires into this relay from the moment it exists and the
/// composition connects it as soon as the snapshot service is built.
///
/// This is not a nicety. Without it the `onCoverageTrigger` parameter defaults to a no-op, and
/// nothing that happens on the *receive* path — the only thing happening while the app is
/// backgrounded and actually recording — ever reaches the widget's file.
///
/// A fire before `connect` is dropped, not queued: the snapshot is a statement about *now*, and
/// replaying a stale trigger later would only rewrite the same file the connection already does.
public final class CoverageTriggerRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (CoverageSnapshotTrigger) async -> Void)?

    public init() {}

    public func connect(_ sink: @escaping @Sendable (CoverageSnapshotTrigger) async -> Void) {
        lock.withLock { self.sink = sink }
    }

    public var isConnected: Bool {
        lock.withLock { sink != nil }
    }

    public func fire(_ trigger: CoverageSnapshotTrigger) async {
        // The lock is released before the await: a snapshot refresh must never be run while
        // holding it, and nothing here needs the two to be atomic.
        let sink = lock.withLock { self.sink }
        await sink?(trigger)
    }
}

/// Writes `coverage_snapshot.json` into the App Group container (temp file + atomic rename).
public struct CoverageSnapshotWriter: Sendable {
    public let directory: URL
    private let log: RuntimeLog

    /// Resolves the App Group container, falling back to Application Support so unit tests and
    /// macOS hosts (no App Group entitlement) still exercise the real writer.
    public static func defaultDirectory() -> URL {
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppDatabase.appGroupIdentifier
        ) {
            return group
        }
        return (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    public init(directory: URL = CoverageSnapshotWriter.defaultDirectory(), log: RuntimeLog = .silent) {
        self.directory = directory
        self.log = log
    }

    public var url: URL { directory.appendingPathComponent(CoverageSnapshot.fileName) }

    /// Writes the snapshot, reporting whether it landed. A failure NEVER propagates — it only
    /// costs the widget freshness — but it must never be invisible either: a widget stuck on its
    /// "no data yet" state with nothing in the log is indistinguishable from a widget nobody
    /// wired up, and that ambiguity has already cost a debugging session.
    @discardableResult
    public func write(_ snapshot: CoverageSnapshot) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            let tmp = directory.appendingPathComponent(CoverageSnapshot.fileName + ".tmp")
            try data.write(to: tmp)
            // The atomic half. `rename` reports through errno, not by throwing, so ignoring its
            // result is how a snapshot silently stops updating while every write "succeeds".
            guard rename(tmp.path, url.path) == 0 else {
                let code = errno
                log.failure(
                    "coverage snapshot rename to \(url.path)",
                    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                )
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
            return true
        } catch {
            log.failure("coverage snapshot write to \(url.path)", error)
            return false
        }
    }

    public func read() -> CoverageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CoverageSnapshot.self, from: data)
    }
}
