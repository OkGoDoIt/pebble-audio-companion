import Foundation

// The widget's ONLY data source (plan 6.8): `coverage_snapshot.json` in the App Group. The
// extension never opens the database, never reads the segment directory, and never runs the
// coverage computation itself — it decodes this file and draws it.
//
// This is a dependency-free MIRROR of `CompanionRuntime.CoverageSnapshot` (the writer). Field
// names, JSON keys, and `kind` spellings are identical; only the span type is nested here so
// the app target's own UI `CoverageSpan` keeps its name. The app compiles the kit's version,
// not this one (see `ios/project.yml`) — this file ships to the widget and the tests.

/// Decoded `coverage_snapshot.json` — today's coverage spans plus the status headline.
///
/// Compatibility rule (shared with the writer): **`version` is the only layout selector.**
/// Unknown fields are ignored and every field decodes with a default, so a snapshot written by
/// a newer app never crashes an older widget — it just renders what it understands.
struct CoverageSnapshot: Codable, Equatable, Sendable {
    static let fileName = "coverage_snapshot.json"
    static let currentVersion = 1

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
        isRecording: Bool = false
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
}
