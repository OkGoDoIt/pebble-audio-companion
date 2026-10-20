import AppDB
import CompanionRuntime
import Foundation

/// Checks one encoded batch item against `sync-protocol.md` without a server: the envelope the
/// server reads first (`BatchApplier.TryReadEnvelope`), then the payload, field by field, by the
/// rules the server applies (`SyncPayloads.Read`) — what is required, which values are known, the
/// type each field must have — plus the contract's own rule that an optional field is sent as an
/// explicit `null`, never left out.
///
/// The reasons read like the server's (`payload: pieces missing`, `payload: gaps[2].kind 'x' is
/// not known`), so a dry-run finding and a live rejection can be compared directly.
public enum ContractCheck {
    public static let maxItemBytes = ArchiveSyncProtocol.maxBatchBytes - 512

    /// Nil when the item passes; otherwise why it would not.
    public static func check(item: Data) -> String? {
        if item.count > maxItemBytes { return "too large to send (\(item.count / 1024) KB)" }
        guard let envelope = (try? JSONSerialization.jsonObject(with: item)) as? [String: Any] else {
            return "item: not an object"
        }
        let kindText = envelope["kind"] as? String ?? ""
        guard let kind = ArchiveEntityKind(rawValue: kindText) else {
            return kindText.isEmpty ? "kind: missing" : "kind: '\(kindText)' is not known"
        }
        guard let id = envelope["id"] as? String, !id.isEmpty else { return "id: missing" }
        guard let version = envelope["version"] as? NSNumber, JSONType.isInteger(version) else {
            return "version: missing"
        }
        let opText = envelope["op"] as? String
        guard let op = opText.flatMap(ArchiveOp.init(rawValue:)) else {
            return opText == nil ? "op: missing" : "op: '\(opText!)' is not known"
        }
        guard JSONType.isInstant(envelope["changedAt"]) else {
            return "changedAt: missing or not an RFC 3339 time"
        }
        guard op == .upsert else { return nil }
        guard let payload = envelope["payload"], !(payload is NSNull) else { return "payload: missing" }
        guard let object = payload as? [String: Any] else { return "payload: not an object" }
        do {
            try checkPayload(kind, id: id, object)
            return nil
        } catch let violation as Violation {
            return violation.reason
        } catch {
            return "payload: \(error)"
        }
    }

    struct Violation: Error { var reason: String }

    /// The top-level keys each payload carries (§2), every one present even when null.
    static let keys: [ArchiveEntityKind: [String]] = [
        .conversation: [
            "startedAt", "endedAt", "timeZone", "dayKey", "state", "startReason", "provisional",
            "title", "summary", "tags", "titleEditedByUser", "isFinal", "annotationProvider",
            "annotationModel", "contentKind", "contentDescriptor", "mostlyQuiet", "hasMissingAudio",
            "recordedMs", "pieces", "people", "gaps",
        ],
        .transcript: [
            "conversationId", "sourceHash", "provider", "model", "language", "charCount", "text",
            "items",
        ],
        .recap: [
            "dayKey", "timeZone", "headline", "lineSummary", "shortText", "text", "conversationIds",
            "provider", "model",
        ],
        .brief: [
            "kind", "periodKey", "startDay", "endDay", "headline", "lineSummary", "text", "provider",
            "model",
        ],
        .followUp: [
            "text", "quote", "why", "dueAt", "priority", "done", "completedAt", "archivedAt",
            "snoozedUntil", "origin", "sourceConversationId", "sourceAt", "sourceEndAt",
            "sourceApproximate", "createdAt", "editedAt",
        ],
        .note: [
            "conversationId", "templateId", "title", "body", "citations", "origin", "provider",
            "model", "createdAt", "editedAt",
        ],
        .person: ["name"],
        .coverage: ["dayKey", "timeZone", "spans", "recordedMs", "quietMs", "missingMs"],
    ]

    static func checkPayload(_ kind: ArchiveEntityKind, id: String, _ object: [String: Any]) throws {
        for key in keys[kind] ?? [] where object[key] == nil {
            throw Violation(reason: "payload: \(key) left out (the contract sends null)")
        }
        let p = Fields(object, path: "")
        switch kind {
        case .conversation:
            try p.instant("startedAt", required: true)
            try p.instant("endedAt")
            guard let zone = try p.string("timeZone"), !zone.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw p.missing("timeZone") }
            try p.day("dayKey", required: true)
            try p.oneOf("state", ["live", "closed"])
            try p.string("startReason")
            try p.bool("provisional")
            try p.string("title")
            try p.string("summary")
            try p.strings("tags")
            try p.bool("titleEditedByUser")
            try p.bool("isFinal")
            try p.string("annotationProvider")
            try p.string("annotationModel")
            try p.oneOf("contentKind", ["conversation", "noConversation"])
            try p.string("contentDescriptor")
            try p.bool("mostlyQuiet")
            try p.bool("hasMissingAudio")
            try p.integer("recordedMs")
            guard let pieces = try p.objects("pieces") else { throw p.missing("pieces") }
            for (i, piece) in pieces.enumerated() {
                let f = Fields(piece, path: "pieces[\(i)].")
                try f.integer("ordinal", int32: true)
                guard let segment = try f.string("segmentId"), !segment.isEmpty else {
                    throw f.missing("segmentId")
                }
                guard try f.integer("startMediaMs") != nil else { throw f.missing("startMediaMs") }
                try f.integer("endMediaMs")
                try f.instant("startedAt", required: true)
                try f.instant("endedAt")
            }
            for (i, speaker) in (try p.objects("people") ?? []).enumerated() {
                let f = Fields(speaker, path: "people[\(i)].")
                guard let label = try f.string("label"), !label.isEmpty else {
                    throw Violation(reason: "payload: people[].label missing")
                }
                try f.string("personId")
                try f.string("name")
            }
            for (i, gap) in (try p.objects("gaps") ?? []).enumerated() {
                let f = Fields(gap, path: "gaps[\(i)].")
                guard try f.instant("startedAt") != nil, try f.instant("endedAt") != nil else {
                    throw Violation(reason: "payload: gaps[\(i)].startedAt or endedAt missing")
                }
                try f.oneOf("kind", ["quiet", "lost"])
                try f.string("origin")
                try f.string("reason")
            }
        case .transcript:
            if let conversation = try p.string("conversationId"), conversation != id {
                throw Violation(reason: "payload: conversationId is not the item's id")
            }
            try p.string("sourceHash")
            try p.string("provider")
            try p.string("model")
            try p.string("language")
            try p.integer("charCount", int32: true)
            guard try p.string("text") != nil else { throw p.missing("text") }
            for (i, item) in (try p.objects("items") ?? []).enumerated() {
                let f = Fields(item, path: "items[\(i)].")
                try f.oneOf("kind", ["turn", "quiet", "lost", "masked"])
                try f.instant("at", required: true)
                try f.instant("endAt")
                try f.string("speaker")
                try f.string("name")
                try f.string("text")
                try f.number("confidence")
                try f.string("origin")
                try f.string("descriptor")
            }
        case .recap:
            try dayId(id)
            if let day = try p.string("dayKey"), day != id {
                throw Violation(reason: "payload: dayKey is not the item's id")
            }
            for key in ["timeZone", "headline", "lineSummary", "shortText", "text", "provider", "model"] {
                try p.string(key)
            }
            try p.strings("conversationIds")
        case .brief:
            if let period = try p.string("periodKey"), period != id {
                throw Violation(reason: "payload: periodKey is not the item's id")
            }
            try p.oneOf("kind", ["week", "month"])
            guard try p.day("startDay") != nil, try p.day("endDay") != nil else {
                throw Violation(reason: "payload: startDay or endDay missing")
            }
            for key in ["headline", "lineSummary", "text", "provider", "model"] { try p.string(key) }
        case .followUp:
            guard try p.string("text") != nil else { throw p.missing("text") }
            try p.string("quote")
            try p.string("why")
            for key in ["dueAt", "completedAt", "archivedAt", "snoozedUntil", "sourceAt", "sourceEndAt", "editedAt"] {
                try p.instant(key)
            }
            try p.integer("priority", int32: true)
            try p.bool("done")
            try p.oneOf("origin", ["ai", "user", "assistant"])
            try p.string("sourceConversationId")
            try p.bool("sourceApproximate")
            try p.instant("createdAt", required: true)
        case .note:
            try p.string("conversationId")
            try p.string("templateId")
            try p.string("title")
            try p.string("body")
            try p.string("provider")
            try p.string("model")
            try p.oneOf("origin", ["ai", "user", "assistant"])
            try p.instant("createdAt", required: true)
            try p.instant("editedAt")
            for (i, citation) in (try p.objects("citations") ?? []).enumerated() {
                let f = Fields(citation, path: "citations[\(i)].")
                try f.string("conversationId")
                try f.instant("at", required: true)
                try f.instant("endAt")
            }
        case .person:
            guard try p.string("name") != nil else { throw p.missing("name") }
        case .coverage:
            try dayId(id)
            if let day = try p.string("dayKey"), day != id {
                throw Violation(reason: "payload: dayKey is not the item's id")
            }
            try p.string("timeZone")
            for key in ["recordedMs", "quietMs", "missingMs"] { try p.integer(key) }
            for (i, span) in (try p.objects("spans") ?? []).enumerated() {
                let f = Fields(span, path: "spans[\(i)].")
                guard try f.instant("startedAt") != nil, try f.instant("endedAt") != nil else {
                    throw Violation(reason: "payload: spans[\(i)].startedAt or endedAt missing")
                }
                try f.oneOf("kind", ["recorded", "quiet", "missing", "paused", "off"])
            }
        }
    }

    static func dayId(_ id: String) throws {
        guard JSONType.isDay(id) else { throw Violation(reason: "id: '\(id)' is not a day") }
    }

    /// One JSON object's fields, read with the server's types.
    struct Fields {
        let object: [String: Any]
        let path: String

        init(_ object: [String: Any], path: String) {
            self.object = object
            self.path = path
        }

        func missing(_ key: String) -> Violation { Violation(reason: "payload: \(path)\(key) missing") }
        func wrongType(_ key: String) -> Violation {
            Violation(reason: "payload: \(path)\(key) has the wrong type")
        }

        /// The value, nil for absent or null.
        func value(_ key: String) -> Any? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            return value
        }

        @discardableResult
        func string(_ key: String) throws -> String? {
            guard let value = value(key) else { return nil }
            guard let string = value as? String else { throw wrongType(key) }
            return string
        }

        @discardableResult
        func instant(_ key: String, required: Bool = false) throws -> String? {
            guard let value = value(key) else {
                if required { throw missing(key) }
                return nil
            }
            guard let text = value as? String, JSONType.isInstant(text) else { throw wrongType(key) }
            return text
        }

        @discardableResult
        func day(_ key: String, required: Bool = false) throws -> String? {
            guard let text = try string(key) else {
                if required { throw missing(key) }
                return nil
            }
            guard JSONType.isDay(text) else {
                throw Violation(reason: "payload: \(path)\(key) '\(text)' is not a day")
            }
            return text
        }

        @discardableResult
        func integer(_ key: String, int32: Bool = false) throws -> Int64? {
            guard let value = value(key) else { return nil }
            guard let number = value as? NSNumber, JSONType.isInteger(number) else { throw wrongType(key) }
            if int32, number.int64Value < Int64(Int32.min) || number.int64Value > Int64(Int32.max) {
                throw wrongType(key)
            }
            return number.int64Value
        }

        func number(_ key: String) throws {
            guard let value = value(key) else { return }
            guard let number = value as? NSNumber, !JSONType.isBool(number) else { throw wrongType(key) }
        }

        func bool(_ key: String) throws {
            guard let value = value(key) else { return }
            guard let number = value as? NSNumber, JSONType.isBool(number) else { throw wrongType(key) }
        }

        func oneOf(_ key: String, _ known: [String]) throws {
            guard let text = try string(key) else { throw missing(key) }
            guard known.contains(text) else {
                throw Violation(reason: "payload: \(path)\(key) '\(text)' is not known")
            }
        }

        func strings(_ key: String) throws {
            guard let value = value(key) else { return }
            guard let array = value as? [Any] else { throw wrongType(key) }
            for element in array where !(element is NSNull) && !(element is String) {
                throw wrongType(key)
            }
        }

        func objects(_ key: String) throws -> [[String: Any]]? {
            guard let value = value(key) else { return nil }
            guard let array = value as? [Any] else { throw wrongType(key) }
            return try array.enumerated().map { index, element in
                guard let object = element as? [String: Any] else {
                    throw Violation(reason: "payload: \(path)\(key)[\(index)] has the wrong type")
                }
                return object
            }
        }
    }
}

enum JSONType {
    static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func isInteger(_ number: NSNumber) -> Bool {
        !isBool(number) && !CFNumberIsFloatType(number)
    }

    /// The server's RFC 3339 pattern (`SyncJson.Rfc3339`).
    static func isInstant(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return text.wholeMatch(of: /\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d{1,7})?([Zz]|[+-]\d{2}:\d{2})/) != nil
            && ArchiveTime.ms(text) != nil
    }

    static func isDay(_ text: String) -> Bool {
        guard text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return false }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard parts.count == 3,
            let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return false }
        return calendar.component(.day, from: date) == parts[2]
            && calendar.component(.month, from: date) == parts[1]
    }
}
