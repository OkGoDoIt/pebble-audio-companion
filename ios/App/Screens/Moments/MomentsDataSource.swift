import AppDB
import Foundation
import Observation

struct MarkedMomentContext: Equatable {
    var title: String?
    var quote: String = ""
    var status: String
    var target: CitationTarget?
    var playbackTarget: CitationTarget?

    /// Only nearby, timed speech from this conversation. Never substitute its entire transcript
    /// when the mark is in silence or a gap.
    static func quote(in items: [TranscriptItem], at wallMs: Int64) -> String {
        items.compactMap { item -> String? in
            guard case .turn(let turn) = item, let start = turn.startedAt else { return nil }
            let ms = Int64(start.timeIntervalSince1970 * 1000)
            let duration = max(0, (turn.mediaEndMs ?? 0) - (turn.mediaOffsetMs ?? 0))
            guard ms + duration > wallMs - 45_000, ms < wallMs + 15_000, !turn.isInProgress else { return nil }
            return turn.text
        }.joined(separator: "\n\n")
    }
}

@MainActor
protocol MomentsDataSource: AnyObject {
    func moments() -> AsyncThrowingStream<[Moment], Error>
    func context(for moment: Moment) async throws -> MarkedMomentContext
    func saveNote(id: String, note: String) async throws
    func remove(id: String) async throws
    func makeReminder(for moment: Moment, text: String, context: MarkedMomentContext?) async throws -> String
}

@MainActor
enum MomentsDataSources {
    static var current: any MomentsDataSource = PreviewMomentsSource()
}

@MainActor @Observable
final class MomentsModel {
    private(set) var moments: [Moment] = []
    private(set) var loaded = false
    private(set) var error: String?
    private let injectedSource: (any MomentsDataSource)?
    var source: any MomentsDataSource { injectedSource ?? MomentsDataSources.current }

    init(source: (any MomentsDataSource)? = nil) { injectedSource = source }

    func observe() async {
        do {
            for try await value in source.moments() {
                guard !Task.isCancelled else { return }
                if moments != value { moments = value }
                if !loaded { loaded = true }
                if error != nil { error = nil }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't load your moments. Try again."
        }
    }
}

/// No runtime writes from previews. Real data is installed with the other screen sources.
@MainActor
final class PreviewMomentsSource: MomentsDataSource {
    private var rows: [Moment] = [
        Moment(id: "preview-1", wallMs: Int64(Date().timeIntervalSince1970 * 1000) - 900_000,
               onAudioClock: true, createdAtMs: 0, note: "That idea for the weekend", wasRecording: true),
        Moment(id: "preview-2", wallMs: Int64(Date().timeIntervalSince1970 * 1000) - 7_200_000,
               onAudioClock: false, createdAtMs: 0, wasRecording: false)
    ]
    private var observers: [UUID: AsyncThrowingStream<[Moment], Error>.Continuation] = [:]
    func moments() -> AsyncThrowingStream<[Moment], Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(rows)
            continuation.onTermination = { @Sendable _ in Task { @MainActor in self.observers[id] = nil } }
        }
    }
    private func publish() { for observer in observers.values { observer.yield(rows) } }
    func context(for moment: Moment) async throws -> MarkedMomentContext {
        if moment.wasRecording == false {
            return MarkedMomentContext(status: "Recording was off when you marked this.")
        }
        return MarkedMomentContext(title: "Planning the weekend",
            quote: "We could take the early train and spend the afternoon by the water.",
            status: "Words around your mark")
    }
    func saveNote(id: String, note: String) async throws {
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].note = note; publish() }
    }
    func remove(id: String) async throws { rows.removeAll { $0.id == id }; publish() }
    func makeReminder(for moment: Moment, text: String, context: MarkedMomentContext?) async throws -> String {
        "preview-reminder"
    }
}
