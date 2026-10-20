import AppDB
import Foundation

// The JSON of `server/docs/sync-protocol.md`, version 1, exactly. Every payload encodes its
// optional fields as an explicit `null` (the contract's own examples do), times as RFC 3339 in
// UTC with milliseconds, and media offsets and durations as integer milliseconds. Keys are
// sorted when encoded, so the same payload is always the same bytes and its hash means
// "unchanged" and nothing else.

public enum ArchiveSyncProtocol {
    /// `X-Sync-Protocol` on every request (§7).
    public static let version = "1"
    public static let defaultOrigin = "https://pebbleaudio.okgodoit.com"
    /// §3: whichever comes first.
    public static let maxItemsPerBatch = 200
    public static let maxBatchBytes = 8 * 1024 * 1024
}

// MARK: - Time

/// RFC 3339 in UTC with milliseconds (`2026-10-14T13:05:09.754Z`).
public enum ArchiveTime {
    public static func string(_ ms: Int64) -> String {
        var seconds = time_t(ms >= 0 ? ms / 1000 : (ms - 999) / 1000)
        let millis = Int(ms - Int64(seconds) * 1000)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int(parts.tm_year) + 1900,
            Int(parts.tm_mon) + 1, Int(parts.tm_mday), Int(parts.tm_hour), Int(parts.tm_min),
            Int(parts.tm_sec), millis)
    }

    /// `null` for an absent time.
    public static func nullable(_ ms: Int64?) -> String? { ms.map { string($0) } }

    /// Accepts the server's instants with or without fractional seconds, and any offset.
    public static func ms(_ text: String?) -> Int64? {
        guard let text, !text.isEmpty else { return nil }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? withFraction.parse(text) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        if let date = try? Date.ISO8601FormatStyle().parse(text) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        return nil
    }
}

enum ArchiveJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - §2.1 conversation

public struct ArchiveConversationPayload: Encodable, Equatable, Sendable {
    public struct Piece: Encodable, Equatable, Sendable {
        public var ordinal: Int
        public var segmentId: String
        public var startMediaMs: Int64
        public var endMediaMs: Int64?
        public var startedAt: Int64
        public var endedAt: Int64

        enum CodingKeys: String, CodingKey {
            case ordinal, segmentId, startMediaMs, endMediaMs, startedAt, endedAt
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ordinal, forKey: .ordinal)
            try c.encode(segmentId, forKey: .segmentId)
            try c.encode(startMediaMs, forKey: .startMediaMs)
            try c.encode(endMediaMs, forKey: .endMediaMs)
            try c.encode(ArchiveTime.string(startedAt), forKey: .startedAt)
            try c.encode(ArchiveTime.string(endedAt), forKey: .endedAt)
        }
    }

    public struct Speaker: Encodable, Equatable, Sendable {
        public var label: String
        public var personId: String?
        public var name: String?

        enum CodingKeys: String, CodingKey { case label, personId, name }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(label, forKey: .label)
            try c.encode(personId, forKey: .personId)
            try c.encode(name, forKey: .name)
        }
    }

    public var startedAt: Int64
    public var endedAt: Int64
    public var timeZone: String
    public var dayKey: String
    public var state: String
    public var startReason: String?
    public var provisional: Bool
    public var title: String?
    public var summary: String?
    public var tags: [String]
    public var titleEditedByUser: Bool
    public var isFinal: Bool
    public var annotationProvider: String?
    public var annotationModel: String?
    public var contentKind: String
    public var contentDescriptor: String?
    public var mostlyQuiet: Bool
    public var hasMissingAudio: Bool
    public var recordedMs: Int64
    public var pieces: [Piece]
    public var people: [Speaker]
    public var gaps: [ArchiveGap]

    enum CodingKeys: String, CodingKey {
        case startedAt, endedAt, timeZone, dayKey, state, startReason, provisional, title
        case summary, tags, titleEditedByUser, isFinal, annotationProvider, annotationModel
        case contentKind, contentDescriptor, mostlyQuiet, hasMissingAudio, recordedMs, pieces
        case people, gaps
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ArchiveTime.string(startedAt), forKey: .startedAt)
        try c.encode(ArchiveTime.string(endedAt), forKey: .endedAt)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(dayKey, forKey: .dayKey)
        try c.encode(state, forKey: .state)
        try c.encode(startReason, forKey: .startReason)
        try c.encode(provisional, forKey: .provisional)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(tags, forKey: .tags)
        try c.encode(titleEditedByUser, forKey: .titleEditedByUser)
        try c.encode(isFinal, forKey: .isFinal)
        try c.encode(annotationProvider, forKey: .annotationProvider)
        try c.encode(annotationModel, forKey: .annotationModel)
        try c.encode(contentKind, forKey: .contentKind)
        try c.encode(contentDescriptor, forKey: .contentDescriptor)
        try c.encode(mostlyQuiet, forKey: .mostlyQuiet)
        try c.encode(hasMissingAudio, forKey: .hasMissingAudio)
        try c.encode(recordedMs, forKey: .recordedMs)
        try c.encode(pieces, forKey: .pieces)
        try c.encode(people, forKey: .people)
        try c.encode(gaps, forKey: .gaps)
    }
}

/// A stretch inside a conversation with no stored audio: `quiet` (skipped on purpose — the
/// watch's silence suppression, or its own power-save pause, named in `reason`) or `lost`
/// (genuinely missing; `origin` says where: `watch`, `link` for audio that never reached the
/// phone, or `unknown` for a hole no record explains).
public struct ArchiveGap: Encodable, Equatable, Sendable {
    public enum Kind: String, Sendable { case quiet, lost }

    public var startMs: Int64
    public var endMs: Int64
    public var kind: Kind
    public var origin: String?
    /// Additive (§7): set to `watchPause` for the watch's own power-save pause.
    public var reason: String?

    public init(startMs: Int64, endMs: Int64, kind: Kind, origin: String? = nil, reason: String? = nil) {
        self.startMs = startMs
        self.endMs = endMs
        self.kind = kind
        self.origin = origin
        self.reason = reason
    }

    public var durationMs: Int64 { max(0, endMs - startMs) }

    enum CodingKeys: String, CodingKey { case startedAt, endedAt, kind, origin, reason }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ArchiveTime.string(startMs), forKey: .startedAt)
        try c.encode(ArchiveTime.string(endMs), forKey: .endedAt)
        try c.encode(kind.rawValue, forKey: .kind)
        if kind == .lost { try c.encode(origin ?? "unknown", forKey: .origin) }
        if let reason { try c.encode(reason, forKey: .reason) }
    }
}

// MARK: - §2.2 transcript

public struct ArchiveTranscriptPayload: Encodable, Equatable, Sendable {
    public enum Item: Encodable, Equatable, Sendable {
        case turn(atMs: Int64, endMs: Int64, speaker: String?, name: String?, text: String, confidence: Double?)
        case quiet(atMs: Int64, endMs: Int64)
        case lost(atMs: Int64, endMs: Int64, origin: String)
        case masked(atMs: Int64, endMs: Int64, descriptor: String?)

        public var atMs: Int64 {
            switch self {
            case .turn(let at, _, _, _, _, _), .quiet(let at, _), .lost(let at, _, _),
                .masked(let at, _, _):
                return at
            }
        }

        public var endMs: Int64 {
            switch self {
            case .turn(_, let end, _, _, _, _), .quiet(_, let end), .lost(_, let end, _),
                .masked(_, let end, _):
                return end
            }
        }

        public var kindName: String {
            switch self {
            case .turn: return "turn"
            case .quiet: return "quiet"
            case .lost: return "lost"
            case .masked: return "masked"
            }
        }

        enum CodingKeys: String, CodingKey {
            case kind, at, endAt, speaker, name, text, confidence, origin, descriptor
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kindName, forKey: .kind)
            try c.encode(ArchiveTime.string(atMs), forKey: .at)
            try c.encode(ArchiveTime.string(endMs), forKey: .endAt)
            switch self {
            case .turn(_, _, let speaker, let name, let text, let confidence):
                try c.encode(speaker, forKey: .speaker)
                try c.encode(name, forKey: .name)
                try c.encode(text, forKey: .text)
                try c.encode(confidence, forKey: .confidence)
            case .quiet:
                break
            case .lost(_, _, let origin):
                try c.encode(origin, forKey: .origin)
            case .masked(_, _, let descriptor):
                try c.encode(descriptor, forKey: .descriptor)
            }
        }
    }

    public var conversationId: String
    public var sourceHash: String
    public var provider: String?
    public var model: String?
    public var language: String?
    public var charCount: Int
    public var text: String
    public var items: [Item]

    enum CodingKeys: String, CodingKey {
        case conversationId, sourceHash, provider, model, language, charCount, text, items
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conversationId, forKey: .conversationId)
        try c.encode(sourceHash, forKey: .sourceHash)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(language, forKey: .language)
        try c.encode(charCount, forKey: .charCount)
        try c.encode(text, forKey: .text)
        try c.encode(items, forKey: .items)
    }
}

// MARK: - §2.3–2.7

public struct ArchiveRecapPayload: Encodable, Equatable, Sendable {
    public var dayKey: String
    public var timeZone: String
    public var headline: String?
    public var lineSummary: String?
    public var shortText: String?
    public var text: String
    public var conversationIds: [String]
    public var provider: String?
    public var model: String?

    enum CodingKeys: String, CodingKey {
        case dayKey, timeZone, headline, lineSummary, shortText, text, conversationIds, provider, model
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dayKey, forKey: .dayKey)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(headline, forKey: .headline)
        try c.encode(lineSummary, forKey: .lineSummary)
        try c.encode(shortText, forKey: .shortText)
        try c.encode(text, forKey: .text)
        try c.encode(conversationIds, forKey: .conversationIds)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
    }
}

public struct ArchiveBriefPayload: Encodable, Equatable, Sendable {
    public var kind: String
    public var periodKey: String
    public var startDay: String
    public var endDay: String
    public var headline: String?
    public var lineSummary: String?
    public var text: String
    public var provider: String?
    public var model: String?

    enum CodingKeys: String, CodingKey {
        case kind, periodKey, startDay, endDay, headline, lineSummary, text, provider, model
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(periodKey, forKey: .periodKey)
        try c.encode(startDay, forKey: .startDay)
        try c.encode(endDay, forKey: .endDay)
        try c.encode(headline, forKey: .headline)
        try c.encode(lineSummary, forKey: .lineSummary)
        try c.encode(text, forKey: .text)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
    }
}

public struct ArchiveFollowUpPayload: Encodable, Equatable, Sendable {
    public var text: String
    public var quote: String?
    public var why: String?
    public var dueAtMs: Int64?
    public var priority: Int
    public var done: Bool
    public var completedAtMs: Int64?
    public var archivedAtMs: Int64?
    public var snoozedUntilMs: Int64?
    public var origin: String
    public var sourceConversationId: String?
    public var sourceAtMs: Int64?
    public var sourceEndAtMs: Int64?
    public var sourceApproximate: Bool
    public var createdAtMs: Int64
    public var editedAtMs: Int64?

    enum CodingKeys: String, CodingKey {
        case text, quote, why, dueAt, priority, done, completedAt, archivedAt, snoozedUntil
        case origin, sourceConversationId, sourceAt, sourceEndAt, sourceApproximate, createdAt
        case editedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(quote, forKey: .quote)
        try c.encode(why, forKey: .why)
        try c.encode(ArchiveTime.nullable(dueAtMs), forKey: .dueAt)
        try c.encode(priority, forKey: .priority)
        try c.encode(done, forKey: .done)
        try c.encode(ArchiveTime.nullable(completedAtMs), forKey: .completedAt)
        try c.encode(ArchiveTime.nullable(archivedAtMs), forKey: .archivedAt)
        try c.encode(ArchiveTime.nullable(snoozedUntilMs), forKey: .snoozedUntil)
        try c.encode(origin, forKey: .origin)
        try c.encode(sourceConversationId, forKey: .sourceConversationId)
        try c.encode(ArchiveTime.nullable(sourceAtMs), forKey: .sourceAt)
        try c.encode(ArchiveTime.nullable(sourceEndAtMs), forKey: .sourceEndAt)
        try c.encode(sourceApproximate, forKey: .sourceApproximate)
        try c.encode(ArchiveTime.string(createdAtMs), forKey: .createdAt)
        try c.encode(ArchiveTime.nullable(editedAtMs), forKey: .editedAt)
    }
}

public struct ArchiveNotePayload: Encodable, Equatable, Sendable {
    public struct Citation: Encodable, Equatable, Sendable {
        public var conversationId: String
        public var atMs: Int64
        public var endAtMs: Int64?

        enum CodingKeys: String, CodingKey { case conversationId, at, endAt }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(conversationId, forKey: .conversationId)
            try c.encode(ArchiveTime.string(atMs), forKey: .at)
            try c.encode(ArchiveTime.nullable(endAtMs), forKey: .endAt)
        }
    }

    public var conversationId: String
    public var templateId: String
    public var title: String
    public var body: String
    public var citations: [Citation]
    public var origin: String
    public var provider: String?
    public var model: String?
    public var createdAtMs: Int64
    public var editedAtMs: Int64?

    enum CodingKeys: String, CodingKey {
        case conversationId, templateId, title, body, citations, origin, provider, model
        case createdAt, editedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conversationId, forKey: .conversationId)
        try c.encode(templateId, forKey: .templateId)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        try c.encode(citations, forKey: .citations)
        try c.encode(origin, forKey: .origin)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(ArchiveTime.string(createdAtMs), forKey: .createdAt)
        try c.encode(ArchiveTime.nullable(editedAtMs), forKey: .editedAt)
    }
}

public struct ArchivePersonPayload: Encodable, Equatable, Sendable {
    public var name: String
}

public struct ArchiveCoveragePayload: Encodable, Equatable, Sendable {
    public struct Span: Encodable, Equatable, Sendable {
        public var startMs: Int64
        public var endMs: Int64
        public var kind: String

        enum CodingKeys: String, CodingKey { case startedAt, endedAt, kind }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ArchiveTime.string(startMs), forKey: .startedAt)
            try c.encode(ArchiveTime.string(endMs), forKey: .endedAt)
            try c.encode(kind, forKey: .kind)
        }
    }

    public var dayKey: String
    public var timeZone: String
    public var spans: [Span]
    public var recordedMs: Int64
    public var quietMs: Int64
    public var missingMs: Int64
}

// MARK: - §3 batches

/// One item as it goes into the batch body, already encoded.
public struct ArchiveBatchItem: Sendable {
    public var key: ArchiveItemKey
    public var op: ArchiveOp
    public var changedAtMs: Int64
    /// The payload's JSON (upserts only).
    public var payload: Data?
    /// What the outbox records on acceptance.
    public var hash: String?
    public var pieceKey: String?

    public init(
        key: ArchiveItemKey, op: ArchiveOp, changedAtMs: Int64, payload: Data?, hash: String?,
        pieceKey: String?
    ) {
        self.key = key
        self.op = op
        self.changedAtMs = changedAtMs
        self.payload = payload
        self.hash = hash
        self.pieceKey = pieceKey
    }

    /// `{ "kind", "id", "version", "op", "changedAt", "payload" }` — keys in sorted order, the
    /// payload spliced in as it was encoded.
    public func encoded() throws -> Data {
        var out = Data("{".utf8)
        out.append(Data("\"changedAt\":\"\(ArchiveTime.string(changedAtMs))\",".utf8))
        out.append(Data("\"id\":".utf8))
        out.append(try JSONEncoder().encode(key.entityId))
        out.append(Data(",\"kind\":\"\(key.kind.rawValue)\",\"op\":\"\(op.rawValue)\"".utf8))
        if let payload {
            out.append(Data(",\"payload\":".utf8))
            out.append(payload)
        }
        out.append(Data(",\"version\":\(key.version)}".utf8))
        return out
    }
}

public enum ArchiveBatchBody {
    /// The `PUT /sync/batch` body around already-encoded items.
    public static func encode(deviceId: String, sentAtMs: Int64, items: [Data]) throws -> Data {
        var out = Data("{\"deviceId\":".utf8)
        out.append(try JSONEncoder().encode(deviceId))
        out.append(Data(",\"items\":[".utf8))
        for (index, item) in items.enumerated() {
            if index > 0 { out.append(Data(",".utf8)) }
            out.append(item)
        }
        out.append(Data("],\"sentAt\":\"\(ArchiveTime.string(sentAtMs))\"}".utf8))
        return out
    }
}

public struct ArchiveBatchResponse: Decodable, Equatable, Sendable {
    public struct Accepted: Decodable, Equatable, Sendable {
        public var kind: String
        public var id: String
        public var version: Int64
    }

    public struct Ignored: Decodable, Equatable, Sendable {
        public var kind: String
        public var id: String
        public var version: Int64
        public var reason: String?
    }

    public struct Rejected: Decodable, Equatable, Sendable {
        public var kind: String
        public var id: String
        public var reason: String?
    }

    public var serverTime: String?
    public var accepted: [Accepted]
    public var ignored: [Ignored]
    public var rejected: [Rejected]
    public var pendingRequests: Int

    enum CodingKeys: String, CodingKey { case serverTime, accepted, ignored, rejected, pendingRequests }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverTime = try c.decodeIfPresent(String.self, forKey: .serverTime)
        accepted = try c.decodeIfPresent([Accepted].self, forKey: .accepted) ?? []
        ignored = try c.decodeIfPresent([Ignored].self, forKey: .ignored) ?? []
        rejected = try c.decodeIfPresent([Rejected].self, forKey: .rejected) ?? []
        pendingRequests = try c.decodeIfPresent(Int.self, forKey: .pendingRequests) ?? 0
    }

    /// Everything the server now holds: accepted, and ignored as no newer than what it had.
    public var held: [ArchiveItemKey] {
        accepted.compactMap { item in
            ArchiveEntityKind(rawValue: item.kind).map {
                ArchiveItemKey(kind: $0, entityId: item.id, version: item.version)
            }
        }
            + ignored.compactMap { item in
                ArchiveEntityKind(rawValue: item.kind).map {
                    ArchiveItemKey(kind: $0, entityId: item.id, version: item.version)
                }
            }
    }

    /// What the server now STORES: accepted, and ignored as `stale` or `duplicate`. An item
    /// ignored as `outsideScope` is not stored and its version not recorded, so it must not be
    /// remembered as sent (`outsideScope`).
    public var stored: [ArchiveItemKey] {
        accepted.compactMap { item in
            ArchiveEntityKind(rawValue: item.kind).map {
                ArchiveItemKey(kind: $0, entityId: item.id, version: item.version)
            }
        }
            + ignored.filter { $0.reason != Self.outsideScopeReason }.compactMap { item in
                ArchiveEntityKind(rawValue: item.kind).map {
                    ArchiveItemKey(kind: $0, entityId: item.id, version: item.version)
                }
            }
    }

    /// Items the server ignored because they are dated before the sharing scope (§5).
    public var outsideScope: [ArchiveItemKey] {
        ignored.filter { $0.reason == Self.outsideScopeReason }.compactMap { item in
            ArchiveEntityKind(rawValue: item.kind).map {
                ArchiveItemKey(kind: $0, entityId: item.id, version: item.version)
            }
        }
    }

    public static let outsideScopeReason = "outsideScope"
}

// MARK: - §1 linking, §4 requests, §5 status

public struct ArchiveLinkRequest: Encodable, Sendable {
    public var code: String
    public var deviceName: String
    public var appVersion: String
    public var appBuild: String
}

public struct ArchiveLinkResponse: Decodable, Equatable, Sendable {
    public var deviceId: String
    public var deviceToken: String
    public var userId: String?
    public var serverTime: String?
}

/// A loosely typed JSON value, for request payloads whose shape depends on their kind.
public enum ArchiveJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ArchiveJSONValue])
    case object([String: ArchiveJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([ArchiveJSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: ArchiveJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> ArchiveJSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var int64: Int64? { if case .number(let n) = self { return Int64(n) } else { return nil } }
    public var isNull: Bool { self == .null }
    public var array: [ArchiveJSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var object: [String: ArchiveJSONValue]? {
        if case .object(let o) = self { return o } else { return nil }
    }
}

public struct ArchiveServerRequest: Decodable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var createdAt: String?
    public var expiresAt: String?
    public var payload: ArchiveJSONValue
}

public struct ArchiveRequestsResponse: Decodable, Equatable, Sendable {
    public var requests: [ArchiveServerRequest]
}

/// `POST /sync/requests/{id}/result`.
public struct ArchiveRequestResult: Encodable, Equatable, Sendable {
    public enum Status: String, Encodable, Sendable { case done, failed, unavailable }
    public var status: Status
    public var detail: String?

    public init(status: Status, detail: String? = nil) {
        self.status = status
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey { case status, detail }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(detail, forKey: .detail)
    }
}

/// `GET /sync/status`, read leniently: what the AI Assistants and Privacy screens show is read,
/// and a field the server adds later is ignored. Encoded back in the same wire shape, so the
/// last answer can be kept on the phone and shown (with its time) while the server is away.
public struct ArchiveServerStatus: Codable, Equatable, Sendable {
    public struct AiRead: Codable, Equatable, Sendable {
        public var atMs: Int64?
        public var client: String
        public var tool: String
        public var ids: [String]

        enum CodingKeys: String, CodingKey { case at, when, client, tool, ids, entityIds }

        public init(atMs: Int64?, client: String, tool: String, ids: [String]) {
            self.atMs = atMs
            self.client = client
            self.tool = tool
            self.ids = ids
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let at = try c.decodeIfPresent(String.self, forKey: .at)
                ?? c.decodeIfPresent(String.self, forKey: .when)
            atMs = ArchiveTime.ms(at)
            client = try c.decodeIfPresent(String.self, forKey: .client) ?? ""
            tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
            ids = try c.decodeIfPresent([String].self, forKey: .ids)
                ?? c.decodeIfPresent([String].self, forKey: .entityIds) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ArchiveTime.nullable(atMs), forKey: .at)
            try c.encode(client, forKey: .client)
            try c.encode(tool, forKey: .tool)
            try c.encode(ids, forKey: .ids)
        }
    }

    /// One assistant that can read the archive right now (§5 `access`): an OAuth client with a
    /// live grant, or an unrevoked personal token.
    public struct Access: Codable, Equatable, Sendable, Identifiable {
        public var kind: String
        public var id: String
        public var name: String
        public var scopes: [String]
        public var connectedAtMs: Int64?
        public var lastUsedAtMs: Int64?

        public static let writeScope = "archive:write"

        /// The server lets it create follow-ups and notes (the phone still checks edits).
        public var canWrite: Bool { scopes.contains(Self.writeScope) }

        enum CodingKeys: String, CodingKey { case kind, id, name, scopes, connectedAt, lastUsedAt }

        public init(
            kind: String, id: String, name: String, scopes: [String], connectedAtMs: Int64?,
            lastUsedAtMs: Int64?
        ) {
            self.kind = kind
            self.id = id
            self.name = name
            self.scopes = scopes
            self.connectedAtMs = connectedAtMs
            self.lastUsedAtMs = lastUsedAtMs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "oauth"
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
            connectedAtMs = ArchiveTime.ms(try c.decodeIfPresent(String.self, forKey: .connectedAt))
            lastUsedAtMs = ArchiveTime.ms(try c.decodeIfPresent(String.self, forKey: .lastUsedAt))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(scopes, forKey: .scopes)
            try c.encode(ArchiveTime.nullable(connectedAtMs), forKey: .connectedAt)
            try c.encode(ArchiveTime.nullable(lastUsedAtMs), forKey: .lastUsedAt)
        }
    }

    public var lastBatchAtMs: Int64?
    public var pendingRequests: Int
    public var aiReads: [AiRead]
    public var access: [Access]
    /// What the server holds, per kind (`conversation`, `transcript`, …).
    public var counts: [String: Int]

    enum CodingKeys: String, CodingKey { case lastBatchAt, pendingRequests, aiReads, access, counts }

    public init(
        lastBatchAtMs: Int64?, pendingRequests: Int, aiReads: [AiRead], access: [Access] = [],
        counts: [String: Int] = [:]
    ) {
        self.lastBatchAtMs = lastBatchAtMs
        self.pendingRequests = pendingRequests
        self.aiReads = aiReads
        self.access = access
        self.counts = counts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastBatchAtMs = ArchiveTime.ms(try c.decodeIfPresent(String.self, forKey: .lastBatchAt))
        pendingRequests = try c.decodeIfPresent(Int.self, forKey: .pendingRequests) ?? 0
        aiReads = try c.decodeIfPresent([AiRead].self, forKey: .aiReads) ?? []
        // One unreadable entry must not hide every other assistant.
        access = (try? c.decodeIfPresent([Access].self, forKey: .access)) ?? []
        counts = (try? c.decodeIfPresent([String: Int].self, forKey: .counts)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ArchiveTime.nullable(lastBatchAtMs), forKey: .lastBatchAt)
        try c.encode(pendingRequests, forKey: .pendingRequests)
        try c.encode(aiReads, forKey: .aiReads)
        try c.encode(access, forKey: .access)
        try c.encode(counts, forKey: .counts)
    }
}
