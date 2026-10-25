import AppDB
import Foundation

struct VoiceExampleDisplay: Equatable, Identifiable {
    var id: String
    var durationSeconds: Double
    var createdAt: Date
    var source: String
    var exampleIDs: [String] = []

    /// One explicit confirmation is one visible sample, even when the model extracts
    /// several embeddings or channel variants. Count overlapping evidence only once.
    static func grouped(_ examples: [VoiceConfirmedExample]) -> [Self] {
        Dictionary(grouping: examples, by: \.confirmationID).map { confirmation, group in
            let ordered = group.sorted { $0.startMediaMs < $1.startMediaMs }
            var duration: Int64 = 0
            var coveredUntil: Int64 = 0
            for example in ordered {
                let start = max(coveredUntil, example.startMediaMs)
                duration += max(0, example.endMediaMs - start)
                coveredUntil = max(coveredUntil, example.endMediaMs)
            }
            return Self(id: confirmation, durationSeconds: Double(duration) / 1_000,
                createdAt: Date(timeIntervalSince1970: Double(group.map(\.createdAtMs).min() ?? 0) / 1_000),
                source: group.first?.segmentId.hasPrefix("enrollment:") == true ? "Phone sample" : "Watch recording",
                exampleIDs: group.map(\.id).sorted())
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }
}

struct VoicePersonDisplay: Equatable, Identifiable {
    var person: Person
    var examples: [VoiceExampleDisplay]
    var id: String { person.id }
    var compatibleExampleCount: Int? = nil
    var ready: Bool { (compatibleExampleCount ?? examples.count) >= 2 }
}

struct VoiceRunDisplay: Equatable, Identifiable {
    var id: String
    var completed: Int
    var total: Int
    var matched: Int
    var isRunning: Bool
    var canUndo: Bool
    var discovering = false
    var stopped = false
    var failed = 0
}

struct VoiceSettingsDisplay: Equatable {
    var enabled = false
    var modelsReady = false
    var currentUser: Person?
    var people: [VoicePersonDisplay] = []
    var run: VoiceRunDisplay?
    var notice: String?
}

@MainActor
protocol VoiceRecognitionDataSource: AnyObject, Sendable {
    func snapshot() async throws -> VoiceSettingsDisplay
    func updates() -> AsyncStream<Void>
    func prepareModels(progress: @escaping @Sendable (Double) -> Void) async throws
    func setEnabled(_ enabled: Bool) async throws
    func currentUser(name: String) async throws -> Person
    func enrollPCM(personId: String, pcm16LE: Data, sessionID: String) async throws -> Int
    func enrollPassage(personId: String, turn: TranscriptTurn) async throws -> Int
    func cancelEnrollment() async
    func recognizeHistory(days: Int?) async throws
    func cancelRun(id: String) async throws
    func undoRun(id: String) async throws
    func clearAutomaticNames() async throws
    func forgetVoice(personId: String) async throws
    func removeExamples(ids: [String]) async throws
}

@MainActor
enum VoiceSources {
    static var current: (any VoiceRecognitionDataSource)?
}
