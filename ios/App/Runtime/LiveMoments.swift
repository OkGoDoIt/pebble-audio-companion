import AppDB
import Foundation
import CryptoKit
import SegmentStore

@MainActor
final class LiveMoments: MomentsDataSource {
    private let composition: AppComposition
    private let world: LiveWorld
    private let store: MomentStore

    init(composition: AppComposition) {
        self.composition = composition
        world = LiveWorld(composition: composition)
        store = MomentStore(db: composition.database)
    }

    func moments() -> AsyncThrowingStream<[Moment], Error> {
        let store = store
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await rows in store.observe() {
                        guard !Task.isCancelled else { break }
                        continuation.yield(rows)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func context(for moment: Moment) async throws -> MarkedMomentContext {
        if moment.wasRecording == false {
            return MarkedMomentContext(status: "Recording was off when you marked this.")
        }
        // A saved mark may outlive the audio. History's nearest-recording fallback would turn
        // this into a convincing but unrelated conversation, so require an enclosing one.
        let hidden = await composition.runtime.library.pendingDeleteConversationIds()
        let rows = try await composition.runtime.library.conversationRows(
            overlappingMs: moment.wallMs..<(moment.wallMs + 1))
        guard let row = rows.first(where: { !hidden.contains($0.id) }),
              let target = await world.momentTarget(atWallMs: moment.wallMs, inConversation: row.id),
              let display = try await world.display(id: target.conversationId)
        else {
            return MarkedMomentContext(status: "No recording is available at this time. Your mark is saved.")
        }
        let quote = MarkedMomentContext.quote(in: display.transcript, at: moment.wallMs)
        let hasTurns = display.transcript.contains { if case .turn = $0 { return true }; return false }
        // Opening starts with context just before the press, while the transcript keeps the
        // saved pin at the exact mark. The resolver clamps within this conversation's pieces.
        let contextStart = max(row.startMs, moment.wallMs - 30_000)
        let opening = await world.momentTarget(atWallMs: contextStart, inConversation: row.id) ?? target
        return MarkedMomentContext(
            title: row.title, quote: quote,
            status: !quote.isEmpty ? "Words around your mark"
                : hasTurns ? "No speech was transcribed near this mark."
                : "No transcript is available yet. You can open the recording.",
            target: target, playbackTarget: opening)
    }

    func saveNote(id: String, note: String) async throws { try await store.setNote(id: id, note: note) }
    func remove(id: String) async throws { try await store.delete(id: id) }

    func makeReminder(for moment: Moment, text: String, context: MarkedMomentContext?) async throws -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let id = "moment-\(moment.id)-\(digest.prefix(16))"
        if try await composition.followUps.load(id: id) != nil { return id }
        let item = FollowUp(
            id: id, text: text, done: false,
            sourceConversationId: context?.target?.conversationId,
            sourceSegmentId: context?.target?.focus.segmentId, createdAtMs: now,
            quote: context?.quote.isEmpty == false ? context?.quote : nil,
            origin: .user,
            sourceWall: SegmentWallRange(startMs: moment.wallMs, endMs: moment.wallMs, isApproximate: !moment.onAudioClock),
            stage: .reminder, decidedAtMs: now)
        // Keep this a user-created reminder and use the existing reminders sync and donation path.
        try await composition.followUps.upsertExtracted(item)
        try? await composition.donator.donateFollowUp(id: item.id, text: text, createdAtMs: now)
        return item.id
    }
}
