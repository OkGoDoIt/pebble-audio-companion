#if DEBUG
import AppDB
import CompanionRuntime
import Foundation

/// `-demo-data`'s voices: recognition on, three remembered people and two recurring unnamed
/// voices, so People & voices and "Who is this?" can be reviewed without a watch. Answers change
/// nothing but the in-memory list.
@MainActor
final class DemoVoiceSource: VoiceRecognitionDataSource {
    private let people = [Person(id: "person-roger", name: "Roger", isCurrentUser: true),
                          Person(id: "person-dana", name: "Dana"), Person(id: "person-sam", name: "Sam")]
    private var unknown: [UnknownVoiceDisplay]

    init(now: Date = Date()) {
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func clip(_ id: String, _ when: Date, _ quote: String) -> UnknownVoiceClip {
            UnknownVoiceClip(id: id, segmentId: "demo-\(id)", startMs: 0, endMs: 4_000, heardAt: when, quote: quote)
        }
        unknown = [
            UnknownVoiceDisplay(id: "demo-voice-1", recordingCount: 6, detail: "Mostly mornings · last heard today", clips: [
                clip("a", at(0, 8, 12), "“we could take the ferry if it’s not too windy”"),
                clip("b", at(2, 7, 40), "“I’ll grab the bread on the way back”"),
                clip("c", at(4, 9, 5), "“did you see the message from the school?”"),
                clip("d", at(5, 8, 30), "“the car needs gas before Friday”"),
                clip("e", at(6, 18, 55), "“we’re out of coffee again”"),
                clip("f", at(8, 7, 50), "“can you take the recycling out?”"),
            ]),
            UnknownVoiceDisplay(id: "demo-voice-2", recordingCount: 4, detail: "Mostly evenings · last heard Saturday", clips: [
                clip("g", at(2, 19, 10), "“the second half was so much better”"),
                clip("h", at(3, 20, 2), "“I’ll send you the link tonight”"),
                clip("i", at(5, 18, 40), "“let’s do Thursday instead”"),
                clip("j", at(7, 21, 15), "“that’s what I told him too”"),
            ]),
        ]
    }

    func snapshot() async throws -> VoiceSettingsDisplay {
        func profile(_ person: Person, _ count: Int) -> VoicePersonDisplay {
            VoicePersonDisplay(person: person, examples: (0..<count).map {
                VoiceExampleDisplay(id: "\(person.id)-\($0)", durationSeconds: 20, createdAt: Date(), source: "Watch sample")
            })
        }
        return VoiceSettingsDisplay(enabled: true, modelsReady: true, currentUser: people[0],
                                    people: [profile(people[0], 5), profile(people[1], 8), profile(people[2], 3)])
    }
    func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func prepareModels(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }
    func setEnabled(_ enabled: Bool) async throws {}
    func currentUser(name: String) async throws -> Person { people[0] }
    func enrollPCM(personId: String, pcm16LE: Data, sessionID: String, kind: VoiceSampleKind?) async throws -> Int { 2 }
    func watchIsStreaming() async -> Bool { false }
    func watchSampleAudio(phoneStartMs: Int64, phoneEndMs: Int64) async -> WatchVoiceSampleAudio? { nil }
    func enrollWatch(personId: String, fromWallMs: Int64, toWallMs: Int64, sessionID: String,
                     kind: VoiceSampleKind?) async throws -> Int { 2 }
    func enrollPassage(personId: String, turn: TranscriptTurn) async throws -> VoiceEnrollmentOutcome {
        VoiceEnrollmentOutcome(personId: personId, examplesAdded: 2, usableSpeechSeconds: 8)
    }
    func recognizeAfterLearning(personId: String, since earliestMs: Int64?) async {}
    func unknownVoices() async -> [UnknownVoiceDisplay] { unknown }
    func nameUnknownVoice(id: String, personId: String, recordings: Set<String>?) async throws -> Int {
        let count = recordings?.count ?? unknown.first { $0.id == id }?.recordingCount ?? 0
        unknown.removeAll { $0.id == id }
        return count
    }
    func dismissUnknownVoice(id: String) async throws { unknown.removeAll { $0.id == id } }
    func clipAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data? { nil }
    func cancelEnrollment() async {}
    func recognizeHistory(days: Int?) async throws {}
    func cancelRun(id: String) async throws {}
    func undoRun(id: String) async throws {}
    func clearAutomaticNames() async throws {}
    func forgetVoice(personId: String) async throws {}
    func removeExamples(ids: [String]) async throws {}
}
#endif
