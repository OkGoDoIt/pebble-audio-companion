import AppDB
import AudioCodec
import Foundation
import SegmentStore

/// What the phone does with one request from the server (`sync-protocol.md` §4).
///
/// Writes go through the ordinary stores, so what an assistant created or changed syncs back as
/// an ordinary upsert and closes the loop. Every write is keyed by the id the server gave it and
/// is safe to receive twice: the server re-offers a request until it has a result.
public struct ArchiveRequestHandler: Sendable {
    public struct Sources: Sendable {
        public var builder: ArchivePayloadBuilder
        /// Frames in stream order (`SegmentStore.readFrames`).
        public var readFrames: @Sendable (String) async -> [FrameRecord]
        /// Brings audio in iCloud back to the phone before it is read (`ColdAudioTier.fetch`).
        public var fetchColdAudio: @Sendable ([String]) async throws -> Void
        public var temporaryDirectory: URL
        public var nowMs: @Sendable () -> Int64

        public init(
            builder: ArchivePayloadBuilder,
            readFrames: @escaping @Sendable (String) async -> [FrameRecord],
            fetchColdAudio: @escaping @Sendable ([String]) async throws -> Void = { _ in },
            temporaryDirectory: URL,
            nowMs: @escaping @Sendable () -> Int64
        ) {
            self.builder = builder
            self.readFrames = readFrames
            self.fetchColdAudio = fetchColdAudio
            self.temporaryDirectory = temporaryDirectory
            self.nowMs = nowMs
        }
    }

    /// A clip ready to upload: the Ogg file and the span it actually covers.
    public struct Clip: Equatable, Sendable {
        public var file: URL
        public var startMs: Int64
        public var endMs: Int64
        /// The lost stretches inside it.
        public var lost: [ArchiveGap]

        /// `X-Clip-Gaps`: `[{"startedAt": …, "endedAt": …}]`.
        public var gapsHeader: String {
            let entries = lost.map {
                "{\"endedAt\":\"\(ArchiveTime.string($0.endMs))\",\"startedAt\":\"\(ArchiveTime.string($0.startMs))\"}"
            }
            return "[" + entries.joined(separator: ",") + "]"
        }
    }

    public enum Outcome: Equatable, Sendable {
        case result(ArchiveRequestResult)
        case clip(Clip)
    }

    public let sources: Sources
    private var database: AppDatabase { sources.builder.sources.database }

    public init(sources: Sources) { self.sources = sources }

    public func handle(_ request: ArchiveServerRequest) async -> Outcome {
        do {
            switch request.kind {
            case "clip": return try await clip(request)
            case "followUp.create": return try await createFollowUp(request)
            case "followUp.update": return try await updateFollowUp(request)
            case "note.create": return try await createNote(request)
            default:
                return .result(.init(status: .failed, detail: "This app does not know \(request.kind) requests."))
            }
        } catch {
            return .result(.init(status: .failed, detail: "\(error)"))
        }
    }

    // MARK: - Clips

    func clip(_ request: ArchiveServerRequest) async throws -> Outcome {
        let payload = request.payload
        guard let conversationId = payload["conversationId"]?.string,
            let startMs = ArchiveTime.ms(payload["startAt"]?.string),
            let endMs = ArchiveTime.ms(payload["endAt"]?.string), endMs > startMs
        else { return .result(.init(status: .failed, detail: "The request has no span.")) }
        guard let record = try await sources.builder.conversationRecord(conversationId) else {
            return .result(.init(status: .unavailable, detail: "This phone no longer has that conversation."))
        }
        let pieces = try await sources.builder.pieces(of: record, withTranscripts: false)
        let ranges = ArchiveClipPlan.resolve(
            pieces: pieces, startMs: startMs, endMs: endMs, maxMs: payload["maxMs"]?.int64)
        guard !ranges.isEmpty else {
            return .result(.init(status: .unavailable, detail: "No audio is stored for that span."))
        }
        let metas = Dictionary(pieces.map { ($0.meta.segmentId, $0.meta) }, uniquingKeysWith: { a, _ in a })
        let cold = ranges.map(\.segmentId).filter { metas[$0]?.coldStorage != nil }
        if !cold.isEmpty {
            do { try await sources.fetchColdAudio(cold) } catch {
                return .result(.init(status: .unavailable, detail: "The audio is in iCloud and could not be fetched."))
            }
        }
        var frames: [Data] = []
        var covered: [ArchiveClipPlan.Range] = []
        var framesBySegment: [String: [FrameRecord]] = [:]
        for range in ranges {
            guard let meta = metas[range.segmentId] else { continue }
            if framesBySegment[range.segmentId] == nil {
                framesBySegment[range.segmentId] = await sources.readFrames(range.segmentId)
            }
            let slice = ArchiveClipPlan.frames(
                range, from: framesBySegment[range.segmentId] ?? [], frameDurationMs: meta.frameDurationMs)
            guard !slice.isEmpty else { continue }
            frames += slice
            covered.append(range)
        }
        guard let first = covered.first, let last = covered.last,
            let meta = metas[first.segmentId]
        else { return .result(.init(status: .unavailable, detail: "The audio for that span is gone.")) }
        let ogg = try OggSpeex.encode(
            frames: frames, sampleRateHz: Int(meta.sampleRateHz), frameSamples: meta.frameSamples,
            bitRateBps: Int(meta.bitRateBps))
        try FileManager.default.createDirectory(
            at: sources.temporaryDirectory, withIntermediateDirectories: true)
        let file = sources.temporaryDirectory.appendingPathComponent(
            "clip-\(Self.safe(request.id)).ogg", isDirectory: false)
        try ogg.write(to: file, options: .atomic)
        let span = first.wallRange.lowerBound..<max(last.wallRange.upperBound, first.wallRange.lowerBound + 1)
        let lost = ArchiveExport.gaps(pieces, window: span).filter { $0.kind == .lost }
        return .clip(Clip(file: file, startMs: span.lowerBound, endMs: span.upperBound, lost: lost))
    }

    static func safe(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(80))
    }

    // MARK: - Follow-ups

    /// Where on the clock a source moment falls among the conversation's pieces: the segment and
    /// its media offsets, so the follow-up opens its recording at the moment like one the app
    /// found itself.
    func locate(
        conversationId: String?, startMs: Int64?, endMs: Int64?
    ) async throws -> (segmentId: String, startMediaMs: Int64, endMediaMs: Int64)? {
        guard let conversationId, let startMs,
            let record = try await sources.builder.conversationRecord(conversationId)
        else { return nil }
        for piece in try await sources.builder.pieces(of: record, withTranscripts: false) {
            let extent = ArchiveExport.wallExtent(piece)
            guard extent.contains(startMs) else { continue }
            let clock = SegmentMediaClock(piece.meta)
            let lower = clock.media(fromWall: startMs - clock.startWallMs)
            let upper = clock.media(fromWall: min(endMs ?? startMs, extent.upperBound) - clock.startWallMs)
            return (piece.meta.segmentId, lower, max(upper, lower))
        }
        return nil
    }

    func createFollowUp(_ request: ArchiveServerRequest) async throws -> Outcome {
        let p = request.payload
        guard let text = p["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return .result(.init(status: .failed, detail: "The follow-up has no text.")) }
        let id = p["id"]?.string ?? request.id
        let conversationId = p["sourceConversationId"]?.string
        let sourceAt = ArchiveTime.ms(p["sourceAt"]?.string)
        let sourceEnd = ArchiveTime.ms(p["sourceEndAt"]?.string)
        let located = try await locate(
            conversationId: conversationId, startMs: sourceAt, endMs: sourceEnd)
        let done = p["done"]?.bool ?? false
        let item = FollowUp(
            id: id, text: text, done: done, sourceConversationId: conversationId,
            sourceSegmentId: located?.segmentId,
            createdAtMs: ArchiveTime.ms(p["createdAt"]?.string) ?? sources.nowMs(),
            quote: p["quote"]?.string, why: p["why"]?.string,
            dueAtMs: ArchiveTime.ms(p["dueAt"]?.string),
            priority: FollowUpPriority(rawValue: Int(p["priority"]?.int64 ?? 1)) ?? .normal,
            sourceStartMs: located?.startMediaMs, sourceEndMs: located?.endMediaMs,
            completedAtMs: done ? (ArchiveTime.ms(p["completedAt"]?.string) ?? sources.nowMs()) : nil,
            archivedAtMs: ArchiveTime.ms(p["archivedAt"]?.string),
            snoozedUntilMs: ArchiveTime.ms(p["snoozedUntil"]?.string),
            origin: .assistant,
            sourceWall: sourceAt.map {
                SegmentWallRange(
                    startMs: $0, endMs: sourceEnd ?? $0,
                    isApproximate: p["sourceApproximate"]?.bool ?? false)
            })
        let inserted = try await FollowUpStore(db: database).insertFromAssistant(item)
        return .result(.init(status: .done, detail: inserted ? nil : "It was already on this phone."))
    }

    func updateFollowUp(_ request: ArchiveServerRequest) async throws -> Outcome {
        let p = request.payload
        guard let id = p["id"]?.string else {
            return .result(.init(status: .failed, detail: "The change names no follow-up."))
        }
        /// Absent leaves the field alone; null clears it.
        func instant(_ key: String) -> Int64?? {
            guard let value = p[key] else { return nil }
            if value.isNull { return .some(nil) }
            return .some(ArchiveTime.ms(value.string))
        }
        let change = FollowUpStore.AssistantChange(
            done: p["done"]?.bool, completedAtMs: instant("completedAt"), text: p["text"]?.string,
            dueAtMs: instant("dueAt"), snoozedUntilMs: instant("snoozedUntil"),
            archivedAtMs: instant("archivedAt"))
        guard !change.isEmpty else { return .result(.init(status: .done, detail: "Nothing to change.")) }
        let found = try await FollowUpStore(db: database).applyAssistantChange(
            id: id, change, nowMs: sources.nowMs())
        return .result(
            found
                ? .init(status: .done)
                : .init(status: .failed, detail: "This phone has no such follow-up."))
    }

    // MARK: - Notes

    func createNote(_ request: ArchiveServerRequest) async throws -> Outcome {
        let p = request.payload
        guard let conversationId = p["conversationId"]?.string,
            let record = try await sources.builder.conversationRecord(conversationId)
        else {
            return .result(.init(status: .unavailable, detail: "This phone does not have that conversation."))
        }
        let body = p["body"]?.string ?? ""
        let title = p["title"]?.string ?? ""
        guard !body.isEmpty || !title.isEmpty else {
            return .result(.init(status: .failed, detail: "The note is empty."))
        }
        let pieces = try await sources.builder.pieces(of: record, withTranscripts: false)
        var citations: [AskCitation] = []
        for (index, entry) in (p["citations"]?.array ?? []).enumerated() {
            guard let at = ArchiveTime.ms(entry["at"]?.string) else { continue }
            let end = ArchiveTime.ms(entry["endAt"]?.string)
            let segment = pieces.first { ArchiveExport.wallExtent($0).contains(at) }?.meta.segmentId
                ?? record.members.first?.segmentId
            guard let segment else { continue }
            citations.append(AskCitation(segmentId: segment, number: index + 1, startMs: at, endMs: end))
        }
        let citationsJson = String(
            decoding: (try? JSONEncoder().encode(citations)) ?? Data("[]".utf8), as: UTF8.self)
        let note = Note(
            id: p["id"]?.string ?? request.id, conversationId: conversationId,
            templateId: p["templateId"]?.string ?? "assistant",
            title: title.isEmpty ? "Note" : title, body: body, citationsJson: citationsJson,
            provider: p["provider"]?.string, model: p["model"]?.string,
            createdAtMs: ArchiveTime.ms(p["createdAt"]?.string) ?? sources.nowMs(),
            editedAtMs: nil, origin: "assistant")
        let inserted = try await NotesStore(db: database).insertFromAssistant(note)
        return .result(.init(status: .done, detail: inserted ? nil : "It was already on this phone."))
    }
}
