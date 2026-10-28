import AppDB
import CompanionRuntime
import Foundation

/// The samples setup asks for. Recognition listens through the watch, so three are the watch
/// in different surroundings; the phone microphone adds a differently shaped view of the voice.
enum VoiceSampleKind: String, CaseIterable, Identifiable, Sendable {
    case quiet, noisy, outdoors, phone
    var id: String { rawValue }
    var microphone: VoiceSampleMicrophone { self == .phone ? .phone : .watch }
    var title: String {
        switch self {
        case .quiet: "Quiet room"
        case .noisy: "Background noise"
        case .outdoors: "Outdoors or on the move"
        case .phone: "Phone microphone"
        }
    }
    var detail: String {
        switch self {
        case .quiet: "Through your watch, with no TV or music on."
        case .noisy: "Through your watch, with a TV, music, or people nearby."
        case .outdoors: "Through your watch, outside, walking, or in a car."
        case .phone: "Hold your phone and speak into it."
        }
    }
    /// What to do, shown above the prompt while recording this sample.
    var instruction: String {
        switch self {
        case .quiet: "Find a spot with no TV or music on, then speak naturally for about 20 seconds. Your watch does the listening."
        case .noisy: "With a TV, music, or people nearby, speak naturally for about 20 seconds. Your watch does the listening."
        case .outdoors: "Outside, walking, or in a car, speak naturally for about 20 seconds. Your watch does the listening."
        case .phone: "Hold your phone and speak into it naturally for about 20 seconds."
        }
    }
}

/// A voice heard in several recordings that recognition couldn't name.
struct UnknownVoiceDisplay: Equatable, Identifiable {
    var id: String
    var recordingCount: Int
    /// "Mostly mornings · last heard today"
    var detail: String
    /// One moment per recording, newest first. The question shows the first few; "More than one
    /// person" shows them all to pick from.
    var clips: [UnknownVoiceClip]
}

struct UnknownVoiceClip: Equatable, Identifiable {
    var id: String
    var segmentId: String
    var startMs: Int64
    var endMs: Int64
    var heardAt: Date?
    /// What was said then, when the transcript has it.
    var quote: String?
}

struct VoiceExampleDisplay: Equatable, Identifiable {
    var id: String
    var durationSeconds: Double
    var createdAt: Date
    var source: String
    var exampleIDs: [String] = []
    var kind: VoiceSampleKind? = nil
    var microphone: VoiceSampleMicrophone = .watch
    /// Where a sample taken from a conversation was heard, to play it and open it there. Nil for
    /// setup samples, whose audio isn't kept.
    var clip: UnknownVoiceClip? = nil

    /// One explicit confirmation is one visible sample, even when the model extracts
    /// several embeddings or channel variants. Count overlapping evidence only once.
    static func grouped(_ examples: [VoiceConfirmedExample], kinds: [String: String] = [:]) -> [Self] {
        Dictionary(grouping: examples, by: \.confirmationID).map { confirmation, group in
            let kind = kinds[confirmation].flatMap(VoiceSampleKind.init(rawValue:))
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
                source: Self.label(kind: kind, segmentId: group.first?.segmentId ?? ""),
                exampleIDs: group.map(\.id).sorted(), kind: kind,
                microphone: VoiceSampleMicrophone.of(segmentId: group.first?.segmentId ?? ""),
                clip: ordered.first.flatMap { first in
                    VoiceSampleMicrophone.isGuided(segmentId: first.segmentId) ? nil
                        : UnknownVoiceClip(id: confirmation, segmentId: first.segmentId, startMs: first.startMediaMs,
                                           endMs: ordered.filter { $0.segmentId == first.segmentId }.map(\.endMediaMs).max()
                                               ?? first.endMediaMs)
                })
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }

    private static func label(kind: VoiceSampleKind?, segmentId: String) -> String {
        if let kind { return kind.title }
        if VoiceSampleMicrophone.of(segmentId: segmentId) == .phone { return "Phone microphone" }
        return segmentId.hasPrefix("watch-enrollment:") ? "Watch sample" : "From a conversation"
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
    /// Recordings with audio still to check for voices.
    var pendingRecordings = 0
    /// Why checking is not happening now (on battery, Low Power Mode, too hot); nil while it can.
    var waiting: BackgroundWorkDecision.HoldReason?

    /// The line under "Recognize voices": what recognition is doing, in one line.
    var statusLine: String {
        guard enabled else { return Copy.Voices.offDetail }
        guard pendingRecordings > 0 else { return Copy.Voices.onDetail }
        let count = Copy.Voices.recordingsToCheck(pendingRecordings)
        switch waiting {
        case nil: return Copy.Voices.checking(pendingRecordings)
        case .onBattery, .userTurnedItOff: return "\(Copy.Voices.waitingForCharging) · \(count)"
        case .lowPowerMode: return "\(Copy.Voices.waitingLowPower) · \(count)"
        case .tooHot: return "\(Copy.Voices.waitingTooHot) · \(count)"
        }
    }

    /// The heading of the earlier-recordings card while it has work left.
    var runHeading: String {
        switch waiting {
        case nil: return Copy.Voices.findingVoices
        case .onBattery, .userTurnedItOff: return Copy.Voices.waitingForCharging
        case .lowPowerMode: return Copy.Voices.waitingLowPower
        case .tooHot: return Copy.Voices.waitingTooHot
        }
    }
}

@MainActor
protocol VoiceRecognitionDataSource: AnyObject, Sendable {
    func snapshot() async throws -> VoiceSettingsDisplay
    func updates() -> AsyncStream<Void>
    func prepareModels(progress: @escaping @Sendable (Double) -> Void) async throws
    func setEnabled(_ enabled: Bool) async throws
    func currentUser(name: String) async throws -> Person
    func enrollPCM(personId: String, pcm16LE: Data, sessionID: String, kind: VoiceSampleKind?) async throws -> Int
    /// Whether the watch is streaming to this phone now, so a sample can come through it.
    func watchIsStreaming() async -> Bool
    /// The watch's audio for a sample window on this phone's clock, so far; nil while none of it
    /// has arrived. Its `watchFromMs`/`watchToMs` are what `enrollWatch` takes.
    func watchSampleAudio(phoneStartMs: Int64, phoneEndMs: Int64) async -> WatchVoiceSampleAudio?
    func enrollWatch(personId: String, fromWallMs: Int64, toWallMs: Int64, sessionID: String,
                     kind: VoiceSampleKind?) async throws -> Int
    func enrollPassage(personId: String, turn: TranscriptTurn) async throws -> VoiceEnrollmentOutcome
    /// After a save taught a voice: look for it again in recent recordings, once per save.
    func recognizeAfterLearning(personId: String, since earliestMs: Int64?) async
    /// Recurring unnamed voices, most-heard first; empty while recognition is off.
    func unknownVoices() async -> [UnknownVoiceDisplay]
    /// Names the voice in every recording it was heard in, or only in `recordings` when the
    /// group turned out to mix people; the rest stay unnamed. Returns how many recordings.
    func nameUnknownVoice(id: String, personId: String, recordings: Set<String>?) async throws -> Int
    /// Stop asking about these particular clips, without learning from their voices.
    func dismissUnknownVoice(id: String) async throws
    func ignoreUnknownClip(_ clip: UnknownVoiceClip) async throws
    /// A clip's audio (16 kHz mono PCM) for listening before naming.
    func clipAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data?
    /// The clip with several seconds of audio either side.
    func clipContextAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data?
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
