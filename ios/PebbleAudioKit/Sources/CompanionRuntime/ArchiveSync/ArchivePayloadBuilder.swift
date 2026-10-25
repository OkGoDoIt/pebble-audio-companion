import AppDB
import CryptoKit
import Foundation
import GRDB
import SegmentStore
import Transcription

/// What building one outbox row's payload came to.
public enum ArchiveBuilt: Sendable {
    /// Send this. `hash` is what the outbox records when the server accepts it; `pieceKey` is
    /// the conversation's piece list for a conversation or transcript.
    case payload(Data, hash: String, pieceKey: String?)
    /// Nothing to send: the server already has exactly this, or what changed is only the edge
    /// of a conversation that retention is ageing out (see `isRetentionTail`).
    case unchanged(hash: String?, pieceKey: String?)
    /// The entity no longer exists here, though its row asked for an upsert.
    case gone
}

/// Builds the `§2` payloads from the database, the segment sidecars and the transcript files.
///
/// Every read is about the one entity being built — a conversation's own rows and its pieces'
/// sidecars and transcripts — so building a batch costs what the batch holds, never the library.
/// The transcript, the one expensive payload, is skipped before it is built when nothing it is
/// made from has changed (`sourceHash`).
public struct ArchivePayloadBuilder: Sendable {
    public struct Sources: Sendable {
        public var database: AppDatabase
        public var readMeta: @Sendable (String) async -> SegmentMeta?
        public var listSegments: @Sendable () async -> [SegmentMeta]
        /// The transcript without its word timings (`FileTranscriptStore.loadWithoutWords`).
        public var transcript: @Sendable (String) -> SegmentTranscript?
        /// One `stat` (`FileTranscriptStore.version`).
        public var transcriptVersion: @Sendable (String) -> String
        public var mask: AudioContentMask?
        public var audioContent: AudioContentStore?
        /// Conversations whose boundaries may still move (the latest grouping's).
        public var provisionalIds: @Sendable () async -> Set<String>
        public var nowMs: @Sendable () -> Int64
        public var currentZoneID: @Sendable () -> String

        public init(
            database: AppDatabase,
            readMeta: @escaping @Sendable (String) async -> SegmentMeta?,
            listSegments: @escaping @Sendable () async -> [SegmentMeta],
            transcript: @escaping @Sendable (String) -> SegmentTranscript?,
            transcriptVersion: @escaping @Sendable (String) -> String,
            mask: AudioContentMask? = nil,
            audioContent: AudioContentStore? = nil,
            provisionalIds: @escaping @Sendable () async -> Set<String> = { [] },
            nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
            currentZoneID: @escaping @Sendable () -> String = { TimeZone.current.identifier }
        ) {
            self.database = database
            self.readMeta = readMeta
            self.listSegments = listSegments
            self.transcript = transcript
            self.transcriptVersion = transcriptVersion
            self.mask = mask
            self.audioContent = audioContent
            self.provisionalIds = provisionalIds
            self.nowMs = nowMs
            self.currentZoneID = currentZoneID
        }
    }

    public let sources: Sources

    public init(sources: Sources) { self.sources = sources }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try ArchiveJSON.encoder().encode(value)
    }

    /// Builds `row`'s payload, or says why there is nothing to send.
    public func build(_ row: ArchiveOutboxRow) async throws -> ArchiveBuilt {
        switch row.kind {
        case .conversation: return try await conversation(row)
        case .transcript: return try await transcript(row)
        case .recap: return try await simple(row) { try await recap(row.entityId) }
        case .brief: return try await simple(row) { try await brief(row.entityId) }
        case .followUp: return try await simple(row) { try await followUp(row.entityId) }
        case .note: return try await simple(row) { try await note(row.entityId) }
        case .person: return try await simple(row) { try await person(row.entityId) }
        case .coverage: return try await simple(row) { try await coverage(row.entityId) }
        }
    }

    private func simple(
        _ row: ArchiveOutboxRow, _ make: () async throws -> Data?
    ) async throws -> ArchiveBuilt {
        guard let data = try await make() else { return .gone }
        let hash = Self.hash(data)
        if hash == row.sentHash { return .unchanged(hash: hash, pieceKey: nil) }
        return .payload(data, hash: hash, pieceKey: nil)
    }

    /// A conversation whose pieces are what is left of the ones last sent after whole leading
    /// pieces went away. Only retention removes whole leading pieces of a conversation and
    /// keeps its id, and what the server holds — the whole of it — is what should be kept.
    static func isRetentionTail(current: String, sent: String?) -> Bool {
        guard let sent, sent != current else { return false }
        return ConversationSourceKey.describes(stored: sent, current: current)
    }

    /// The conversation's `people` for the wire: one entry per person, under the plain label
    /// they first speak as.
    ///
    /// Names are filed per recording (`SpeakerKey`), so one person can hold a different label
    /// in each recording of a conversation, and one label can be a different person in each.
    /// The stored keys (`seg-…#1`) are not labels the transcript uses, and one entry per
    /// (recording, label) would list a person once per recording. Who said what is in the
    /// transcript's turns, which carry their own names; this list says who took part.
    static func people(
        _ speakers: [ArchiveConversationPayload.Speaker]
    ) -> [ArchiveConversationPayload.Speaker] {
        var seen = Set<String>()
        var out: [ArchiveConversationPayload.Speaker] = []
        // Stored keys sort by recording (its id starts with when it arrived), and rows written
        // before scoping sort ahead of them.
        for speaker in speakers {
            let person = speaker.personId.map { "id:\($0)" } ?? "name:\(speaker.name ?? speaker.label)"
            guard seen.insert(person).inserted else { continue }
            var plain = speaker
            plain.label = SpeakerKey(stored: speaker.label)?.label ?? speaker.label
            out.append(plain)
        }
        return out
    }

    // MARK: - Conversations

    struct ConversationRecord {
        var id: String
        var startMs: Int64
        var endMs: Int64
        var timeZoneID: String
        var isLive: Bool
        var startReason: String?
        var members: [ConversationMember]
        var title: String?
        var summary: String?
        var isFinal: Bool
        var titleEdited: Bool
        var provider: String?
        var model: String?
        var tags: [String]
        var speakers: [ArchiveConversationPayload.Speaker]

        var pieceKey: String { ConversationSourceKey.key(of: members) }
        var window: Range<Int64> { startMs..<max(endMs, startMs + 1) }
        var legacyAssignments: [SpeakerAssignment] {
            speakers.compactMap { speaker in
                guard let personId = speaker.personId, let name = speaker.name else { return nil }
                return SpeakerAssignment(conversationId: id, label: speaker.label,
                                         personId: personId, personName: name)
            }
        }
    }

    func conversationRecord(_ id: String) async throws -> ConversationRecord? {
        try await sources.database.reader.read { d in
            guard
                let row = try Row.fetchOne(
                    d,
                    sql: """
                        SELECT id, startMs, endMs, timezone, state, startReason FROM conversations
                        WHERE id = ?
                        """,
                    arguments: [id])
            else { return nil }
            let members = try Row.fetchAll(
                d,
                sql: """
                    SELECT segmentId, startMediaMs, endMediaMs FROM conversation_segments
                    WHERE conversationId = ? ORDER BY ordinal
                    """,
                arguments: [id]
            ).map {
                ConversationMember(
                    segmentId: $0["segmentId"], startMediaMs: $0["startMediaMs"],
                    endMediaMs: $0["endMediaMs"])
            }
            let annotation = try Row.fetchOne(
                d, sql: "SELECT * FROM annotations WHERE conversationId = ?", arguments: [id])
            let tags = try String.fetchAll(
                d,
                sql: """
                    SELECT t.name FROM conversation_tags ct JOIN tags t ON t.id = ct.tagId
                    WHERE ct.conversationId = ? AND ct.source <> ?
                    ORDER BY t.name COLLATE NOCASE
                    """,
                arguments: [id, TagSource.removed])
            let speakers = try Row.fetchAll(
                d,
                sql: """
                    SELECT sa.label AS label, sa.personId AS personId, p.name AS name
                    FROM speaker_assignments sa JOIN people p ON p.id = sa.personId
                    WHERE sa.conversationId = ? ORDER BY sa.label
                    """,
                arguments: [id]
            ).map {
                ArchiveConversationPayload.Speaker(
                    label: $0["label"], personId: $0["personId"], name: $0["name"])
            }
            let start: Int64 = row["startMs"]
            func column<T: DatabaseValueConvertible>(_ name: String) -> T? {
                guard let annotation, annotation.hasColumn(name) else { return nil }
                return annotation[name]
            }
            return ConversationRecord(
                id: id, startMs: start, endMs: row["endMs"] ?? start,
                timeZoneID: row["timezone"], isLive: (row["state"] as String) == "live",
                startReason: row["startReason"], members: members,
                title: column("title"), summary: column("summary"),
                isFinal: (column("isFinal") as Bool?) ?? false,
                titleEdited: (column("titleEditedAtMs") as Int64?) != nil,
                provider: column("providerId"), model: column("modelUsed"), tags: tags,
                speakers: speakers)
        }
    }

    /// `masks: false` skips the model-input mask, which only the transcript's turns read; the
    /// conversation's rows need the words (quiet is the time between them) but not the mask.
    func pieces(of record: ConversationRecord, withTranscripts: Bool, masks: Bool = true)
        async throws -> [ArchiveExport.Piece]
    {
        var out: [ArchiveExport.Piece] = []
        for member in record.members {
            guard let meta = await sources.readMeta(member.segmentId) else { continue }
            out.append(
                ArchiveExport.Piece(
                    member: member, meta: meta,
                    transcript: withTranscripts ? sources.transcript(member.segmentId) : nil,
                    masked: withTranscripts && masks ? try await masked(meta.segmentId) : []))
        }
        return out
    }

    /// The model-input mask of a segment (`AudioContentMask.aiRanges`), each range named by the
    /// stored span that set it when that span names what it heard.
    func masked(_ segmentId: String) async throws -> [ArchiveExport.MaskedRange] {
        guard let mask = sources.mask else { return [] }
        let ranges = mask.aiRanges(segmentId)
        guard !ranges.isEmpty else { return [] }
        let spans = try await sources.audioContent?.spans(segmentId: segmentId) ?? []
        return ranges.map { range in
            let descriptor = spans.first {
                $0.kind == .noConversation && $0.mediaStartMs < range.upperBound
                    && $0.mediaEndMs > range.lowerBound && $0.descriptor != nil
            }?.descriptor
            return ArchiveExport.MaskedRange(range: range, descriptor: descriptor)
        }
    }

    func conversation(_ row: ArchiveOutboxRow) async throws -> ArchiveBuilt {
        guard let record = try await conversationRecord(row.entityId) else { return .gone }
        let key = record.pieceKey
        if Self.isRetentionTail(current: key, sent: row.sentKey) {
            return .unchanged(hash: nil, pieceKey: row.sentKey)
        }
        // The words are read (without their timings) because the rows are the screen's: a quiet
        // row is the time between two turns, not only what the watch skipped.
        let pieces = try await pieces(of: record, withTranscripts: true, masks: false)
        let identity = try await SpeakerCorrectionStore(db: sources.database)
            .snapshot(segmentIds: record.members.map(\.segmentId))
        let participants = pieces.flatMap { piece in
            SpeakerAttribution.people(in: piece.member, transcript: piece.transcript,
                                      identity: identity, legacyAssignments: record.legacyAssignments)
        }.map { person in
            // The transcript's turns carry raw provider labels; this list identifies people,
            // including local-ASR speech which has no provider label at all.
            ArchiveConversationPayload.Speaker(
                label: record.speakers.first(where: { $0.personId == person.id })?.label
                    ?? "person:\(person.id)",
                personId: person.id, name: person.name)
        }
        let gaps = ArchiveExport.gaps(pieces, window: record.window)
        let missingMs = ArchiveExport.missingMs(pieces, window: record.window)
        let quietMs = gaps.filter { $0.kind == .quiet && $0.reason == nil }
            .reduce(0) { $0 + $1.durationMs }
        let span = max(record.endMs - record.startMs, 0)
        let (contentKind, descriptor) = try await content(record)
        let provisional = await sources.provisionalIds().contains(record.id)
        let payload = ArchiveConversationPayload(
            startedAt: record.startMs, endedAt: record.endMs, timeZone: record.timeZoneID,
            dayKey: LogicalDay.dateKey(forMs: record.startMs, timeZoneID: record.timeZoneID),
            state: record.isLive ? "live" : "closed", startReason: record.startReason,
            provisional: provisional || record.isLive,
            title: record.title, summary: record.summary, tags: record.tags,
            titleEditedByUser: record.titleEdited, isFinal: record.isFinal,
            annotationProvider: record.provider, annotationModel: record.model,
            contentKind: contentKind, contentDescriptor: descriptor,
            mostlyQuiet: span > 0 && quietMs * 10 > span * 6,
            hasMissingAudio: missingMs > 0,
            recordedMs: ArchiveExport.recordedMs(pieces, window: record.window),
            missingMs: missingMs,
            pieces: pieces.enumerated().map { index, piece in
                let extent = ArchiveExport.wallExtent(piece)
                return ArchiveConversationPayload.Piece(
                    ordinal: index, segmentId: piece.member.segmentId,
                    startMediaMs: piece.member.startMediaMs ?? 0,
                    endMediaMs: piece.member.endMediaMs, startedAt: extent.lowerBound,
                    endedAt: extent.upperBound)
            },
            people: Self.people(participants), gaps: gaps)
        let data = try Self.encode(payload)
        let hash = Self.hash(data)
        if hash == row.sentHash { return .unchanged(hash: hash, pieceKey: key) }
        return .payload(data, hash: hash, pieceKey: key)
    }

    /// What a conversation holds: `noConversation` only when every piece was classified and
    /// none of it is conversation — the rule the AI layer titles by
    /// (`EnrichmentService.holdsNoConversation`) — and then named when every stretch with words
    /// in it says the same thing.
    func content(_ record: ConversationRecord) async throws -> (String, String?) {
        guard let mask = sources.mask, !record.members.isEmpty,
            record.members.allSatisfy({ mask.holdsConversation(in: $0) == false })
        else { return ("conversation", nil) }
        var worded: [SegmentAudioContentSpan] = []
        for member in record.members {
            let spans = try await sources.audioContent?.spans(segmentId: member.segmentId) ?? []
            let lower = member.startMediaMs ?? 0
            let upper = member.endMediaMs ?? Int64.max
            worded += spans.filter {
                $0.wordCount > 0 && $0.mediaStartMs < upper && $0.mediaEndMs > lower
            }
        }
        if !worded.isEmpty, worded.allSatisfy({ $0.descriptor == AudioContentDescriptor.music }) {
            return ("noConversation", AudioContentDescriptor.music)
        }
        if !worded.isEmpty, worded.allSatisfy({ $0.descriptor == AudioContentDescriptor.fewWords })
        {
            return ("noConversation", AudioContentDescriptor.fewWords)
        }
        return ("noConversation", nil)
    }

    // MARK: - Transcripts

    func transcript(_ row: ArchiveOutboxRow) async throws -> ArchiveBuilt {
        guard let record = try await conversationRecord(row.entityId) else { return .gone }
        let key = record.pieceKey
        if Self.isRetentionTail(current: key, sent: row.sentKey) {
            return .unchanged(hash: nil, pieceKey: row.sentKey)
        }
        let names = Dictionary(
            record.speakers.compactMap { speaker in speaker.name.map { (speaker.label, $0) } },
            uniquingKeysWith: { first, _ in first })
        let identity = try await SpeakerCorrectionStore(db: sources.database)
            .snapshot(segmentIds: record.members.map(\.segmentId))
        let sourceHash = try await transcriptSourceHash(record, names: names, identity: identity)
        if sourceHash == row.sentHash { return .unchanged(hash: sourceHash, pieceKey: key) }
        let pieces = try await pieces(of: record, withTranscripts: true)
        let payload = ArchiveExport.transcript(
            conversationId: record.id, pieces: pieces,
            gaps: ArchiveExport.gaps(pieces, window: record.window), speakerNames: names,
            sourceHash: sourceHash, identity: identity)
        return .payload(try Self.encode(payload), hash: sourceHash, pieceKey: key)
    }

    /// Everything the transcript is made from, without reading a transcript: the export's
    /// version, the conversation's window and pieces, each piece's transcript file identity
    /// (one `stat`), sidecar extent and gap records, and mask, and the speaker names.
    func transcriptSourceHash(
        _ record: ConversationRecord, names: [String: String],
        identity: SpeakerIdentitySnapshot = .init()
    ) async throws
        -> String
    {
        var parts = [
            ArchiveExport.transcriptExportVersion, "\(record.startMs)-\(record.endMs)",
            record.pieceKey,
            "identity:\(identity.revision)",
        ]
        for member in record.members {
            parts.append(sources.transcriptVersion(member.segmentId))
            if let meta = await sources.readMeta(member.segmentId) {
                parts.append(
                    "\(meta.frameCount)|\(meta.firstSampleIndex ?? 0)|\(meta.lastSampleIndexExclusive ?? 0)|\(meta.gaps.count)|\(meta.startWallMs)")
            }
            for mask in try await masked(member.segmentId) {
                parts.append("m\(mask.range.lowerBound)-\(mask.range.upperBound):\(mask.descriptor ?? "")")
            }
        }
        for (label, name) in names.sorted(by: { $0.key < $1.key }) { parts.append("\(label)=\(name)") }
        return Self.hash(Data(parts.joined(separator: "\n").utf8))
    }

    // MARK: - Everything else

    func recap(_ dayKey: String) async throws -> Data? {
        let found: ArchiveRecapPayload? = try await sources.database.reader.read { d in
            guard
                let row = try Row.fetchOne(
                    d, sql: "SELECT * FROM recaps WHERE dateKey = ?", arguments: [dayKey])
            else { return nil }
            let json: String = row["segmentIds"]
            let segmentIds = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            var ids: [String] = []
            var zone: String?
            if !segmentIds.isEmpty {
                for convo in try Row.fetchAll(
                    d,
                    sql: """
                        SELECT DISTINCT c.id AS id, c.timezone AS timezone, c.startMs AS startMs
                        FROM conversation_segments cs JOIN conversations c ON c.id = cs.conversationId
                        WHERE cs.segmentId IN (\(databaseQuestionMarks(count: segmentIds.count)))
                        ORDER BY c.startMs
                        """,
                    arguments: StatementArguments(segmentIds))
                {
                    ids.append(convo["id"])
                    if zone == nil { zone = convo["timezone"] }
                }
            }
            return ArchiveRecapPayload(
                dayKey: dayKey, timeZone: zone ?? "", headline: row["headline"],
                lineSummary: row["lineSummary"], shortText: row["shortText"], text: row["text"],
                conversationIds: ids, provider: row["provider"], model: row["model"])
        }
        guard var payload = found else { return nil }
        if payload.timeZone.isEmpty { payload.timeZone = sources.currentZoneID() }
        return try Self.encode(payload)
    }

    func brief(_ periodKey: String) async throws -> Data? {
        guard let (startDay, endDay) = Self.days(ofPeriod: periodKey) else { return nil }
        let payload: ArchiveBriefPayload? = try await sources.database.reader.read { d in
            guard
                let row = try Row.fetchOne(
                    d, sql: "SELECT * FROM period_briefs WHERE periodKey = ?", arguments: [periodKey]),
                let text: String = row["text"]
            else { return nil }
            return ArchiveBriefPayload(
                kind: row["kind"], periodKey: periodKey, startDay: startDay, endDay: endDay,
                headline: row["headline"], lineSummary: row["lineSummary"], text: text,
                provider: row["provider"], model: row["model"])
        }
        return try payload.map(Self.encode)
    }

    /// `week:2026-10-11` is seven days from its first; `month:2026-10` is the month.
    static func days(ofPeriod key: String) -> (String, String)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func string(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        if key.hasPrefix("week:") {
            let parts = key.dropFirst("week:".count).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                let end = calendar.date(byAdding: .day, value: 6, to: start)
            else { return nil }
            return (string(start), string(end))
        }
        if key.hasPrefix("month:") {
            let parts = key.dropFirst("month:".count).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2,
                let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
                let next = calendar.date(byAdding: .month, value: 1, to: start),
                let end = calendar.date(byAdding: .day, value: -1, to: next)
            else { return nil }
            return (string(start), string(end))
        }
        return nil
    }

    func followUp(_ id: String) async throws -> Data? {
        guard
            let item = try await FollowUpStore(db: sources.database).load(id: id)
        else { return nil }
        return try Self.encode(
            ArchiveFollowUpPayload(
                text: item.text, quote: item.quote, why: item.why, dueAtMs: item.dueAtMs,
                priority: item.priority.rawValue, done: item.done,
                completedAtMs: item.completedAtMs, archivedAtMs: item.archivedAtMs,
                snoozedUntilMs: item.snoozedUntilMs, origin: item.origin.rawValue,
                stage: item.stage.rawValue,
                sourceConversationId: item.sourceConversationId,
                sourceAtMs: item.sourceWall?.startMs, sourceEndAtMs: item.sourceWall?.endMs,
                sourceApproximate: item.sourceWall?.isApproximate ?? false,
                createdAtMs: item.createdAtMs, editedAtMs: item.editedAtMs))
    }

    func note(_ id: String) async throws -> Data? {
        guard let note = try await NotesStore(db: sources.database).get(id: id) else { return nil }
        let citations =
            (try? JSONDecoder().decode([AskCitation].self, from: Data(note.citationsJson.utf8))) ?? []
        return try Self.encode(
            ArchiveNotePayload(
                conversationId: note.conversationId, templateId: note.templateId,
                title: note.title, body: note.body,
                citations: citations.compactMap { citation in
                    citation.startMs.map {
                        ArchiveNotePayload.Citation(
                            conversationId: note.conversationId, atMs: $0, endAtMs: citation.endMs)
                    }
                },
                origin: note.origin ?? (note.provider == nil ? "user" : "ai"),
                provider: note.provider, model: note.model, createdAtMs: note.createdAtMs,
                editedAtMs: note.editedAtMs))
    }

    func person(_ id: String) async throws -> Data? {
        guard
            let name = try await sources.database.reader.read({ d in
                try String.fetchOne(d, sql: "SELECT name FROM people WHERE id = ?", arguments: [id])
            })
        else { return nil }
        return try Self.encode(ArchivePersonPayload(name: name))
    }

    /// A day's coverage as History draws it: `CoverageComputer` over the recordings that touch
    /// the day and the pause journal, with the watch-reported silence cut out as quiet.
    func coverage(_ dayKey: String) async throws -> Data? {
        let zone = try await sources.database.reader.read { d in
            try String.fetchOne(
                d,
                sql: """
                    SELECT timezone FROM conversations WHERE startMs >= ? AND startMs < ?
                    ORDER BY startMs LIMIT 1
                    """,
                arguments: Self.roughBounds(dayKey))
        } ?? sources.currentZoneID()
        guard let bounds = LogicalDay.bounds(ofDateKey: dayKey, timeZoneID: zone) else { return nil }
        let metas = await sources.listSegments().filter {
            $0.startWallMs < bounds.endMs && ConversationGrouper.segmentEndMs($0) > bounds.startMs
        }
        let pauses = try await PauseJournal(db: sources.database).intervals(
            overlappingMs: bounds.startMs, bounds.endMs)
        let now = sources.nowMs()
        let isToday = now >= bounds.startMs && now < bounds.endMs
        let attributed = CoverageComputer.computeAttributed(
            dateKey: dayKey, timeZoneID: zone, segments: metas.map { SegmentCoverageInput(meta: $0) },
            pauses: pauses, nowMs: isToday ? now : nil)
        let spans = attributed.spansWithWatchQuiet
        func total(_ kind: CoverageKind) -> Int64 {
            spans.filter { $0.kind == kind }.reduce(0) { $0 + $1.durationMs }
        }
        return try Self.encode(
            ArchiveCoveragePayload(
                dayKey: dayKey, timeZone: zone,
                spans: spans.map {
                    ArchiveCoveragePayload.Span(startMs: $0.startMs, endMs: $0.endMs, kind: $0.kind.rawValue)
                },
                recordedMs: total(.recorded), quietMs: total(.quiet), missingMs: total(.missing)))
    }

    /// The day's 5 AM-to-5 AM window in any zone lies inside this one.
    static func roughBounds(_ dayKey: String) -> StatementArguments {
        guard let utc = LogicalDay.bounds(ofDateKey: dayKey, timeZoneID: "UTC") else { return [0, 0] }
        return [utc.startMs - 14 * 3_600_000, utc.endMs + 14 * 3_600_000]
    }
}
