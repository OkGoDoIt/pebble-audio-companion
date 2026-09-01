import Foundation

// The widget's ONLY data source (plan 6.8): `coverage_snapshot.json` in the App Group. The
// extension never opens the database, never reads the segment directory, and never runs the
// coverage computation itself — it decodes this file and draws it.
//
// This is a dependency-free MIRROR of `CompanionRuntime.CoverageSnapshot` (the writer). Field
// names, JSON keys, and `kind` spellings are identical; only the span type is nested here so
// the app target's own UI `CoverageSpan` keeps its name. The app compiles the kit's version,
// not this one (see `ios/project.yml`) — this file ships to the widget and the tests.

/// Decoded `coverage_snapshot.json` — the live capture state, the current conversation, the
/// recent-activity profile, open follow-ups, and today's coverage spans.
///
/// Compatibility rule (shared with the writer): **`version` is the only layout selector.**
/// Unknown fields are ignored and every field decodes with a default, so a snapshot written by
/// a newer app never crashes an older widget — and a v1 file written by an older app decodes
/// into a v2 struct whose new fields are simply absent, which every view treats as "unknown"
/// rather than as "nothing is happening".
struct CoverageSnapshot: Codable, Equatable, Sendable {
    static let fileName = "coverage_snapshot.json"
    /// v2 (2026-08-31): added `state`, `currentStartedAtMs`, `liveTitle`, `liveLine`,
    /// `activity`, `activityWindowMs`, `followUps`, `openFollowUpCount`.
    static let currentVersion = 2

    /// One contiguous span of the logical day, in wall-clock milliseconds.
    struct Span: Codable, Equatable, Sendable {
        /// The four-state taxonomy plus `paused` (a stripe pattern, not a fifth color) and
        /// `off` (nothing drawn). Unknown future kinds decode to `off` rather than failing.
        enum Kind: String, Codable, Sendable {
            case recorded, quiet, missing, paused, off

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw) ?? .off
            }
        }

        var kind: Kind
        var startMs: Int64
        var endMs: Int64

        init(kind: Kind, startMs: Int64, endMs: Int64) {
            self.kind = kind
            self.startMs = startMs
            self.endMs = endMs
        }

        var durationMs: Int64 { max(0, endMs - startMs) }
    }

    /// One bucket of the recent-activity profile (v2).
    ///
    /// Deliberately NOT an audio waveform: the snapshot is written by a process that must not
    /// Speex-decode audio on a Bluetooth wake, and a real waveform would freeze the moment the
    /// app was suspended — a frozen waveform on a "recording" widget is a lie. `level` is the
    /// share of the bucket that carried voice-detected audio, so the bars still read as speech
    /// activity, and `kind` keeps the four-state taxonomy honest inside the window.
    struct ActivityBar: Codable, Equatable, Sendable {
        var kind: Span.Kind
        /// 0…1 — the fraction of this bucket that was recorded audio.
        var level: Double

        init(kind: Span.Kind, level: Double) {
            self.kind = kind
            self.level = min(max(level, 0), 1)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(Span.Kind.self, forKey: .kind) ?? .off
            level = min(max(try c.decodeIfPresent(Double.self, forKey: .level) ?? 0, 0), 1)
        }
    }

    /// An open follow-up, trimmed to what a widget row can show (v2).
    struct FollowUp: Codable, Equatable, Sendable {
        var id: String
        var text: String
        /// Deep-link target, so a tapped row opens the conversation it came from.
        var conversationId: String?

        init(id: String, text: String, conversationId: String? = nil) {
            self.id = id
            self.text = text
            self.conversationId = conversationId
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        }
    }

    /// `StatusFamily` as a lowercase string — the machine-readable half of the status, so the
    /// widget picks a layout and a color without parsing the prose headline (which is written
    /// for people, may be localized, and must never be pattern-matched).
    ///
    /// `recording` · `paused` · `reconnecting` · `connecting` · `bluetoothOff` ·
    /// `notRecording` · `confirmOnWatch` · `transcriptsOff` · `transcriptsFailing` ·
    /// `needsAttention`.
    /// Empty means a v1 snapshot that predates the field.
    enum State: String, Codable, Sendable {
        case recording, paused, reconnecting, connecting, bluetoothOff
        case notRecording, confirmOnWatch, transcriptsOff, transcriptsFailing, needsAttention
        /// A v1 snapshot, or a family this widget build does not know.
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .unknown
        }
    }

    var version: Int
    var generatedAtMs: Int64
    /// Logical-day key (5 AM boundary) in `timeZoneID`.
    var dateKey: String
    var timeZoneID: String
    var dayStartMs: Int64
    /// The strip's right edge — "now", clamped into the logical day.
    var nowMs: Int64
    var spans: [Span]
    var totalRecordedMs: Int64
    var totalMissingMs: Int64
    /// Already-approved plain language from the status engine; rendered verbatim.
    var headline: String
    var detail: String?
    /// `neutral` · `info` · `active` · `attention` · `problem` · `consent`.
    var dot: String
    var isRecording: Bool

    // --- v2 -------------------------------------------------------------------------------

    var state: State
    /// When the stretch of capture that is still running began, or nil when nothing is
    /// running. The widget renders elapsed time from this with a self-ticking timer, so the
    /// number stays live without a single extra timeline reload.
    var currentStartedAtMs: Int64?
    /// Title of the conversation being recorded right now (nil until enrichment names it).
    var liveTitle: String?
    /// The most recent line of transcript in that conversation.
    var liveLine: String?
    /// Recent-activity buckets, oldest → newest, covering `activityWindowMs` ending at `nowMs`.
    var activity: [ActivityBar]
    var activityWindowMs: Int64
    /// The first few open follow-ups, newest first.
    var followUps: [FollowUp]
    /// How many are open in total (`followUps` is only the head of the list).
    var openFollowUpCount: Int

    init(
        version: Int = CoverageSnapshot.currentVersion,
        generatedAtMs: Int64,
        dateKey: String,
        timeZoneID: String = TimeZone.current.identifier,
        dayStartMs: Int64,
        nowMs: Int64,
        spans: [Span],
        totalRecordedMs: Int64,
        totalMissingMs: Int64,
        headline: String,
        detail: String? = nil,
        dot: String = "neutral",
        isRecording: Bool = false,
        state: State = .unknown,
        currentStartedAtMs: Int64? = nil,
        liveTitle: String? = nil,
        liveLine: String? = nil,
        activity: [ActivityBar] = [],
        activityWindowMs: Int64 = 0,
        followUps: [FollowUp] = [],
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        generatedAtMs = try c.decodeIfPresent(Int64.self, forKey: .generatedAtMs) ?? 0
        dateKey = try c.decodeIfPresent(String.self, forKey: .dateKey) ?? ""
        timeZoneID =
            try c.decodeIfPresent(String.self, forKey: .timeZoneID) ?? TimeZone.current.identifier
        dayStartMs = try c.decodeIfPresent(Int64.self, forKey: .dayStartMs) ?? 0
        nowMs = try c.decodeIfPresent(Int64.self, forKey: .nowMs) ?? 0
        spans = try c.decodeIfPresent([Span].self, forKey: .spans) ?? []
        totalRecordedMs = try c.decodeIfPresent(Int64.self, forKey: .totalRecordedMs) ?? 0
        totalMissingMs = try c.decodeIfPresent(Int64.self, forKey: .totalMissingMs) ?? 0
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        dot = try c.decodeIfPresent(String.self, forKey: .dot) ?? "neutral"
        isRecording = try c.decodeIfPresent(Bool.self, forKey: .isRecording) ?? false
        // v2 — every field optional, so a v1 file still decodes. `state` falls back to the v1
        // `isRecording` flag: it is less precise, but it is true, and inventing `.notRecording`
        // for an older snapshot would claim knowledge the file does not carry.
        state =
            try c.decodeIfPresent(State.self, forKey: .state)
            ?? (isRecording ? .recording : .unknown)
        currentStartedAtMs = try c.decodeIfPresent(Int64.self, forKey: .currentStartedAtMs)
        liveTitle = try c.decodeIfPresent(String.self, forKey: .liveTitle)
        liveLine = try c.decodeIfPresent(String.self, forKey: .liveLine)
        activity = try c.decodeIfPresent([ActivityBar].self, forKey: .activity) ?? []
        activityWindowMs = try c.decodeIfPresent(Int64.self, forKey: .activityWindowMs) ?? 0
        followUps = try c.decodeIfPresent([FollowUp].self, forKey: .followUps) ?? []
        openFollowUpCount = try c.decodeIfPresent(Int.self, forKey: .openFollowUpCount) ?? 0
    }

    // MARK: - Loading (pure; the timeline provider does no other I/O)

    /// Decodes a snapshot from raw JSON. Returns nil for malformed data — a widget that cannot
    /// read the file shows its honest "no data yet" state instead of stale or invented numbers.
    static func load(from data: Data) -> CoverageSnapshot? {
        try? JSONDecoder().decode(CoverageSnapshot.self, from: data)
    }

    /// Decodes the snapshot stored at `url` (the file itself, not its directory).
    static func load(from url: URL) -> CoverageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return load(from: data)
    }

    /// The App Group location the runtime writes to.
    static var appGroupURL: URL? {
        SharedAppGroup.containerURL?.appendingPathComponent(fileName)
    }

    /// Reads the live snapshot out of the App Group, or nil when nothing has been written yet.
    static func loadFromAppGroup() -> CoverageSnapshot? {
        appGroupURL.flatMap { load(from: $0) }
    }

    // MARK: - Rendering helpers (pure)

    /// Milliseconds in a logical day — the strip's domain is always the full 5 AM → 5 AM day,
    /// with everything past `nowMs` left as track.
    static let dayDurationMs: Int64 = 24 * 60 * 60 * 1000

    /// `span` as a 0…1 fraction range of the strip, clamped into the day.
    func fractionRange(of span: Span) -> ClosedRange<Double>? {
        let dayMs = Double(Self.dayDurationMs)
        guard dayMs > 0 else { return nil }
        let lower = min(max(Double(span.startMs - dayStartMs) / dayMs, 0), 1)
        let upper = min(max(Double(span.endMs - dayStartMs) / dayMs, 0), 1)
        guard upper > lower else { return nil }
        return lower...upper
    }

    /// True when there is genuinely nothing to draw (fresh install, or a day with no capture).
    var isEmptyDay: Bool {
        spans.allSatisfy { $0.kind == .off } || spans.isEmpty
    }

    // MARK: - v2 derived (pure)

    /// How stale this snapshot is at `now`. Never negative — a clock that moved backwards is
    /// not evidence of freshness.
    func ageMs(at now: Date = Date()) -> Int64 {
        ageMs(atMs: Int64(now.timeIntervalSince1970 * 1000))
    }

    func ageMs(atMs nowMs: Int64) -> Int64 { max(0, nowMs - generatedAtMs) }

    /// A snapshot this old must not be presented as the live state. The app rewrites on every
    /// capture change and on backgrounding, so anything beyond half an hour means the app has
    /// not run since — the widget says "as of <time>" instead of asserting the state.
    static let staleAfterMs: Int64 = 30 * 60 * 1000

    func isStale(at now: Date = Date()) -> Bool { ageMs(at: now) > Self.staleAfterMs }

    func isStale(atMs nowMs: Int64) -> Bool { ageMs(atMs: nowMs) > Self.staleAfterMs }

    /// The moment the running stretch began, when the snapshot knows one.
    var currentStartedAt: Date? {
        currentStartedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// True when this file predates the v2 fields, so views can choose "unknown" over a
    /// confident-looking zero.
    var hasLiveDetail: Bool { version >= 2 }
}
