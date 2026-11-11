#if DEBUG
import AppDB
import CompanionRuntime
import Foundation

/// `-demo-data`'s voices: recognition on, three remembered people and two recurring unnamed
/// voices, so People & voices and "Who is this?" can be reviewed without a watch. Answers change
/// nothing but the in-memory list.
@MainActor
final class DemoVoiceSource: VoiceRecognitionDataSource {
    private static let dana = Person(id: "person-dana", name: "Dana")
    private static let everyone = [Person(id: "person-you", name: "Alex", isCurrentUser: true), dana,
                                   Person(id: "person-sam", name: "Sam"), Person(id: "person-oliver", name: "Oliver")]
    private static func color(_ person: Person) -> Int { PersonPalette.indices(of: everyone)[person.id] ?? 1 }
    private var people: [Person] { Self.everyone }
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
            ], speechMs: 80 * 60_000),
            UnknownVoiceDisplay(id: "demo-voice-3", recordingCount: 4, detail: "Mostly afternoons · last heard today", clips: [
                clip("k", at(0, 16, 40), "“I said we’d bring the dessert, so that’s on us”"),
                clip("l", at(2, 11, 15), "“she’s been asking about the garden again”"),
                clip("m", at(3, 20, 2), "“no, that was the other restaurant, the loud one”"),
                clip("n", at(5, 9, 30), "“let me call you back after the school run”"),
            ], speechMs: 18 * 60_000, suggestion: VoiceSuggestionDisplay(person: Self.dana, colorIndex: Self.color(Self.dana), score: 0.52)),
            UnknownVoiceDisplay(id: "demo-voice-2", recordingCount: 4, detail: "Mostly evenings · last heard Saturday", clips: [
                clip("g", at(2, 19, 10), "“the second half was so much better”"),
                clip("h", at(3, 20, 2), "“I’ll send you the link tonight”"),
                clip("i", at(5, 18, 40), "“let’s do Thursday instead”"),
                clip("j", at(7, 21, 15), "“that’s what I told him too”"),
            ], speechMs: 34 * 60_000),
        ]
    }

    func snapshot() async throws -> VoiceSettingsDisplay {
        func profile(_ person: Person, _ count: Int, _ speechMinutes: Int64, _ conversations: Int) -> VoicePersonDisplay {
            VoicePersonDisplay(person: person, examples: (0..<count).map { index in
                // Half from conversations (playable, with what was said), half from setup.
                VoiceExampleDisplay(id: "\(person.id)-\(index)", durationSeconds: index.isMultiple(of: 2) ? 4 : 20,
                    createdAt: Date(), source: index.isMultiple(of: 2) ? "From a conversation" : "Watch sample",
                    clip: index.isMultiple(of: 2) ? UnknownVoiceClip(id: "\(person.id)-clip-\(index)", segmentId: "demo",
                        startMs: 0, endMs: 4_000, heardAt: Date().addingTimeInterval(-Double(index + 1) * 26_000),
                        quote: ["“Can you send me the slides before the call?”", "“We’ll take the ferry if it’s not windy.”",
                                "“I think the second option is cheaper.”", "“Let’s meet at the café at ten.”"][index / 2 % 4]) : nil)
            }, colorIndex: Self.color(person), speechMs: speechMinutes * 60_000, conversations: conversations, lastHeard: Date())
        }
        var display = VoiceSettingsDisplay(enabled: true, modelsReady: true, currentUser: people[0],
                                           people: [profile(people[0], 5, 760, 118), profile(people[1], 14, 380, 42),
                                                    profile(people[2], 3, 70, 9), profile(people[3], 2, 45, 6)])
        let total: Int64 = 1_450 * 60_000
        display.coverage = VoiceCoverageDisplay(speechMs: total, namedMs: display.people.reduce(0) { $0 + $1.speechMs },
            shares: display.people.map { .init(id: $0.id, name: $0.name, fraction: Double($0.speechMs) / Double(total), colorIndex: $0.colorIndex) })
        // On battery with work left, as most of a day is.
        display.pendingRecordings = 4
        display.waiting = .onBattery
        display.run = VoiceRunDisplay(id: "demo-week", completed: 12, total: 40, matched: 3,
                                      isRunning: true, canUndo: false, progress: 12.4)
        return display
    }
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    func updates() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[id] = nil }
            }
        }
    }
    private func changed() { for listener in listeners.values { listener.yield(()) } }
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
    private var splitOrigins: [String: String] = [:]
    private var splitUndo: [String: [UnknownVoiceDisplay]] = [:]
    func prepareVoiceSplit(id: String) async throws -> VoiceSplitDraft {
        guard let voice = unknown.first(where: { $0.id == id }) else { throw VoiceSplitError.unavailable }
        let token = UUID().uuidString
        splitOrigins[token] = id
        let groups = stride(from: 0, to: voice.clips.count, by: 2).map { Array(voice.clips[$0..<min($0 + 2,voice.clips.count)]) }
        return VoiceSplitDraft(id: token, groups: groups)
    }
    func refineVoiceSplit(_ draft: VoiceSplitDraft, group: Int, individual: Bool) async throws -> VoiceSplitDraft {
        guard draft.groups.indices.contains(group) else { throw VoiceSplitError.changed }
        var result = draft
        result.groups.replaceSubrange(group...group,with: draft.groups[group].map { [$0] })
        return result
    }
    func saveVoiceSplit(_ draft: VoiceSplitDraft) async throws -> VoiceSplitResult {
        guard let original = splitOrigins[draft.id] else { throw VoiceSplitError.changed }
        splitUndo[draft.id] = unknown
        unknown.removeAll { $0.id == original }
        for (index,clips) in draft.groups.enumerated() {
            var voice = UnknownVoiceDisplay(id: "split-\(draft.id)-\(index)",recordingCount: Set(clips.map(\.segmentId)).count,
                detail: "Split for review",clips: clips,speechMs: Int64(clips.count) * 4_000)
            voice.repaired = true
            unknown.insert(voice,at: 0)
        }
        changed()
        return VoiceSplitResult(undoToken: draft.id, groupIDs: draft.groups.indices.map { "split-\(draft.id)-\($0)" })
    }
    func undoVoiceSplit(id: String) async throws {
        guard let prior = splitUndo.removeValue(forKey: id) else { throw VoiceSplitError.changed }
        unknown = prior
        changed()
    }
    func nameUnknownVoice(id: String, personId: String, clips: Set<String>?) async throws -> Int {
        let count = clips?.count ?? unknown.first { $0.id == id }?.recordingCount ?? 0
        unknown.removeAll { $0.id == id }
        changed()
        return count
    }
    func voiceDetail(id: String) async -> UnknownVoiceDisplay? { unknown.first { $0.id == id } }
    func rejectSuggestion(id: String, personId: String) async throws {
        for index in unknown.indices where unknown[index].id == id { unknown[index].suggestion = nil }
    }
    func undoNaming(id: String, personId: String) async throws {}
    func appearances(personId: String) async -> [VoiceAppearanceDisplay] {
        ["Lunch plans for Friday", "Moving the book club", "Getting the car looked at", "Saturday’s dinner"].enumerated().map { index, title in
            let heardAt = Date().addingTimeInterval(-Double(index) * 86_400)
            return VoiceAppearanceDisplay(conversationId: "demo-\(index)", title: title, heardAt: heardAt, speechMs: Int64(12 - index * 2) * 60_000,
                speakerIds: [], clip: UnknownVoiceClip(id: "appearance-\(index)", segmentId: "demo", startMs: 0, endMs: 4_000, heardAt: heardAt))
        }
    }
    func notThisPerson(_ appearance: VoiceAppearanceDisplay, personId: String) async throws {}
    func dismissUnknownVoice(id: String) async throws { unknown.removeAll { $0.id == id } }
    func ignoreUnknownClip(_ clip: UnknownVoiceClip) async throws {
        for index in unknown.indices {
            unknown[index].clips.removeAll { $0.id == clip.id }
            unknown[index].recordingCount = Set(unknown[index].clips.map(\.segmentId)).count
        }
        unknown.removeAll { $0.clips.isEmpty }
    }
    func clipAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data? { nil }
    func clipContextAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data? { nil }
    func cancelEnrollment() async {}
    func recognizeHistory(days: Int?) async throws {}
    func cancelRun(id: String) async throws {}
    func undoRun(id: String) async throws {}
    func clearAutomaticNames() async throws {}
    func forgetVoice(personId: String) async throws {}
    func removeExamples(ids: [String]) async throws {}
}
#endif
