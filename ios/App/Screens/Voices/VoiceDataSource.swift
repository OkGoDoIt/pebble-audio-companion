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

/// Who a voice with no name might be.
struct VoiceSuggestionDisplay: Equatable {
    var person: Person
    var colorIndex: Int
    var score: Double
    /// "you" or "Dana", in a sentence.
    var name: String { person.isCurrentUser ? "you" : person.name }
}

/// A voice heard across recordings that nobody has named.
struct UnknownVoiceDisplay: Equatable, Identifiable {
    var repaired = false
    var id: String
    var recordingCount: Int
    /// "Mostly mornings · last heard today"
    var detail: String
    /// One moment per saved speaker, newest first. Distinct speakers in a recording stay selectable.
    var clips: [UnknownVoiceClip]
    var speechMs: Int64 = 0
    var suggestion: VoiceSuggestionDisplay? = nil
    /// The clip that speaks clearest: the one to lead with.
    var leadClipID: String? = nil

    var lead: UnknownVoiceClip? { clips.first { $0.id == leadClipID } ?? clips.first }
    /// "18 min in 4 conversations"
    var heardFor: String {
        let duration = VoiceDuration.text(speechMs)
        return recordingCount == 1 ? "\(duration) in 1 conversation" : "\(duration) in \(recordingCount) conversations"
    }
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
    var colorIndex = 1
    /// All the speech found to be theirs, not only what's been confirmed.
    var speechMs: Int64 = 0
    var conversations = 0
    var lastHeard: Date? = nil
    var name: String { person.isCurrentUser ? Copy.Speaker.you : person.name }
}

/// How much of what's been said has a name, for the bar at the top of People & voices.
struct VoiceCoverageDisplay: Equatable {
    struct Share: Equatable, Identifiable {
        var id: String
        var name: String
        var fraction: Double
        var colorIndex: Int
    }
    var speechMs: Int64
    var namedMs: Int64
    /// Largest first; the bar's remainder has no name.
    var shares: [Share]
    var percent: Int { speechMs > 0 ? min(100, Int((Double(namedMs) / Double(speechMs) * 100).rounded())) : 0 }
}

/// A conversation someone was recognized in.
struct VoiceAppearanceDisplay: Equatable, Identifiable {
    var id: String { conversationId }
    var conversationId: String
    var title: String
    var heardAt: Date
    var speechMs: Int64
    var speakerIds: [Int64]
    var clip: UnknownVoiceClip
}

struct VoiceRunDisplay: Equatable, Identifiable {
    var id: String
    /// Recordings checked.
    var completed: Int
    /// Recordings the run covers; nil while it is still counting them.
    var total: Int?
    var matched: Int
    var isRunning: Bool
    var canUndo: Bool
    var stopped = false
    var failed = 0
    /// Recordings checked, with the one in progress counted by how far through it is.
    var progress: Double = 0

    /// How far through the run is, 0...1; nil while it is still counting.
    var fraction: Double? {
        total.map { $0 > 0 ? min(1, progress / Double($0)) : 1 }
    }

    /// The line under the heading: how many recordings, and how many voices it has named.
    var detail: String {
        var line = total.map { Copy.Voices.recordingsChecked(completed, of: $0) }
            ?? (completed == 0 ? Copy.Voices.counting : Copy.Voices.recordingsChecked(completed))
        if matched > 0 { line += " · \(Copy.Voices.matches(matched))" }
        return line
    }
}

struct VoiceSettingsDisplay: Equatable {
    var enabled = false
    var modelsReady = false
    var currentUser: Person?
    var people: [VoicePersonDisplay] = []
    var coverage: VoiceCoverageDisplay?
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
    func nameUnknownVoice(id: String, personId: String, clips: Set<String>?) async throws -> Int
    /// One voice with what was said in each of its clips, for listening through it.
    func prepareVoiceSplit(id: String) async throws -> VoiceSplitDraft
    func refineVoiceSplit(_ draft: VoiceSplitDraft, group: Int, individual: Bool) async throws -> VoiceSplitDraft
    /// Saves the groups as reviewed. Each one comes back with an id `nameUnknownVoice` and
    /// `undoNaming` take, so a group can be named in the same step.
    func saveVoiceSplit(_ draft: VoiceSplitDraft) async throws -> VoiceSplitResult
    func undoVoiceSplit(id: String) async throws
    func discardVoiceSplit(id: String)
    func voiceDetail(id: String) async -> UnknownVoiceDisplay?
    /// "It's someone else": the voice stays unnamed and isn't suggested as them again.
    func rejectSuggestion(id: String, personId: String) async throws
    /// Takes back naming a voice, while the offer to undo it is up.
    func undoNaming(id: String, personId: String) async throws
    /// The conversations someone was recognized in, newest first.
    func appearances(personId: String) async -> [VoiceAppearanceDisplay]
    /// "That wasn't them", about one conversation they were recognized in.
    func notThisPerson(_ appearance: VoiceAppearanceDisplay, personId: String) async throws
    /// Stop asking about this voice, wherever it's heard.
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

extension Notification.Name {
    /// A person took an answer back from the offer to undo it. The voice screens rest between
    /// the updates work in progress sends; this one they show at once.
    static let voiceAnswerTakenBack = Notification.Name("voiceAnswerTakenBack")
}

@MainActor
enum VoiceSources {
    static var current: (any VoiceRecognitionDataSource)?
}

// Sources without saved voice prints cannot offer splitting (e.g. optional test adapters).
extension VoiceRecognitionDataSource {
    func prepareVoiceSplit(id: String) async throws -> VoiceSplitDraft { throw VoiceSplitError.unavailable }
    func refineVoiceSplit(_ draft: VoiceSplitDraft, group: Int, individual: Bool) async throws -> VoiceSplitDraft { throw VoiceSplitError.unavailable }
    func saveVoiceSplit(_ draft: VoiceSplitDraft) async throws -> VoiceSplitResult { throw VoiceSplitError.unavailable }
    func undoVoiceSplit(id: String) async throws { throw VoiceSplitError.unavailable }
    func discardVoiceSplit(id: String) {}
}
