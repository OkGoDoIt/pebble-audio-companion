import AppDB
import CompanionRuntime
import Foundation
import GRDB
import SpeakerRecognition
import Transcription

@MainActor
final class LiveVoiceSource: VoiceRecognitionDataSource {
    private let composition: AppComposition
    init(composition: AppComposition) { self.composition = composition }
    private var service: VoiceRecognitionService { composition.voiceRecognition }

    func snapshot() async throws -> VoiceSettingsDisplay {
        let status = try await service.status()
        let profiles = try await service.profiles()
        let examples = try await service.examples()
        let kinds = try await VoiceSampleSituationStore(db: composition.database).all()
        let runs = try await service.runs()
        let plans = try await service.historyPlans()
        let plan = plans.first
        let run = runs.first { $0.runID == plan?.runID }
        var display = VoiceSettingsDisplay(
            enabled: status.configuration.mode == .local,
            modelsReady: status.models == .installed,
            currentUser: try await composition.people.listPeople().first(where: { $0.person.isCurrentUser })?.person,
            people: profiles.map { profile in
                VoicePersonDisplay(person: profile.person,
                    examples: VoiceExampleDisplay.grouped(examples.filter { $0.personId == profile.person.id },
                                                          kinds: kinds),
                    compatibleExampleCount: examples.filter {
                        $0.personId == profile.person.id && $0.recipeID == LocalSpeakerDiarizer.recipeID
                    }.count)
            }, notice: status.lastMessage)
        if let run {
            let runID = run.runID
            let matches = try await composition.database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM voice_auto_attributions WHERE runID = ? AND disposition = 'recognized'",
                                 arguments: [runID]) ?? 0
            }
            let discovering = plan?.state == "active" && plan?.discoveryComplete == false
            display.run = VoiceRunDisplay(id: run.runID,
                completed: run.done + run.failed + run.cancelled,
                total: run.pending + run.running + run.done + run.failed + run.cancelled,
                matched: matches, isRunning: discovering || run.pending + run.running > 0, canUndo: matches > 0,
                discovering: discovering, stopped: plan?.state != "active", failed: run.failed)
        }
        if display.run == nil, let plan {
            display.run = VoiceRunDisplay(id: plan.runID, completed: 0, total: 0, matched: 0,
                isRunning: plan.state == "active" && !plan.discoveryComplete, canUndo: false,
                discovering: plan.state == "active" && !plan.discoveryComplete, stopped: plan.state != "active")
        }
        return display
    }

    func updates() -> AsyncStream<Void> {
        let updates = service.updates
        return AsyncStream { continuation in
            let task = Task {
                for await _ in updates.stream() {
                    guard !Task.isCancelled else { break }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func prepareModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await service.ensureModels(progress: progress)
    }
    func setEnabled(_ enabled: Bool) async throws {
        try await service.setEnabled(enabled)
        composition.runtime.notifyVoiceConfigurationChanged()
    }
    func currentUser(name: String) async throws -> Person {
        try await composition.people.ensureCurrentUser(displayName: name)
    }
    func enrollPCM(personId: String, pcm16LE: Data, sessionID: String, kind: VoiceSampleKind?) async throws -> Int {
        let result = try await service.enrollPCM(personId: personId, pcm16LE: pcm16LE, sessionID: sessionID)
        try await record(kind, of: result)
        composition.runtime.notifyVoiceConfigurationChanged()
        return result.examplesAdded
    }
    func watchIsStreaming() async -> Bool {
        if case .streaming = composition.runtime.receiverState.value { return true }
        return false
    }
    func watchSampleAudio(phoneStartMs: Int64, phoneEndMs: Int64) async -> WatchVoiceSampleAudio? {
        await service.watchSampleAudio(phoneStartMs: phoneStartMs, phoneEndMs: phoneEndMs)
    }
    func enrollWatch(personId: String, fromWallMs: Int64, toWallMs: Int64, sessionID: String,
                     kind: VoiceSampleKind?) async throws -> Int {
        let result = try await service.enrollWatch(personId: personId, fromWallMs: fromWallMs,
                                                   toWallMs: toWallMs, sessionID: sessionID)
        try await record(kind, of: result)
        composition.runtime.notifyVoiceConfigurationChanged()
        return result.examplesAdded
    }
    private func record(_ kind: VoiceSampleKind?, of result: VoiceEnrollmentOutcome) async throws {
        guard let kind, let confirmation = result.confirmationID else { return }
        try await VoiceSampleSituationStore(db: composition.database).set(kind.rawValue, confirmationID: confirmation)
    }
    func enrollPassage(personId: String, turn: TranscriptTurn) async throws -> VoiceEnrollmentOutcome {
        guard turn.canIdentifyPassage, let start = turn.sourceStartMs, let full = turn.sourceEndMs,
              full - start >= 2_000 else {
            throw SpeakerEditorError.timingUnavailable
        }
        // A long passage still teaches the voice: its first 30 seconds are plenty.
        let result = try await service.enroll(personId: personId, segmentId: turn.segmentId,
                                              startMediaMs: start, endMediaMs: min(full, start + 30_000))
        composition.runtime.notifyVoiceConfigurationChanged()
        return result
    }
    private var unknownGroups: [String: VoiceRecognitionService.UnknownVoiceGroup] = [:]

    func unknownVoices() async -> [UnknownVoiceDisplay] {
        guard (try? await service.status().configuration.mode) == .local,
              let groups = try? await service.unknownVoiceGroups(limit: 12) else { return [] }
        unknownGroups = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let service = service, transcripts = composition.transcripts
        return await Task.detached(priority: .userInitiated) {
            groups.map { UnknownVoiceDisplay.build($0, wallMs: service.wallMs(segmentId:mediaMs:),
                                                   transcript: { transcripts.load($0) }) }
        }.value
    }
    func nameUnknownVoice(id: String, personId: String, recordings: Set<String>?) async throws -> Int {
        guard let whole = unknownGroups[id] else { throw SpeakerEditorError.voiceUnavailable }
        let group = recordings.map { whole.limited(to: $0) } ?? whole
        guard !group.crops.isEmpty else { return 0 }
        _ = try await service.nameUnknownVoice(group, personId: personId)
        unknownGroups[id] = nil
        let earliest = group.crops.compactMap { service.wallMs(segmentId: $0.segmentId, mediaMs: $0.startMediaMs) }.min()
        await recognizeAfterLearning(personId: personId, since: earliest)
        composition.runtime.notifyVoiceConfigurationChanged()
        return group.recordingCount
    }
    func dismissUnknownVoice(id: String) async throws {
        guard let group = unknownGroups[id] else { return }
        try await service.dismissUnknownVoice(group)
        unknownGroups[id] = nil
    }
    func clipAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data? {
        try? await service.clipPCM(segmentId: segmentId, startMediaMs: startMs, endMediaMs: endMs)
    }

    func recognizeAfterLearning(personId: String, since earliestMs: Int64?) async {
        // Every name teaches now, so a whole-archive pass per save would be O(library) work
        // for each label. The past week, reaching back to the labelled conversation, is where
        // the new evidence matters most; "Find voices in all recordings" still covers the rest.
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let from = min(now - 7 * 86_400_000, earliestMs.map { $0 - 3_600_000 } ?? now)
        guard (try? await service.status().configuration.mode) == .local,
              let examples = try? await service.examples(),
              examples.filter({ $0.personId == personId && $0.recipeID == LocalSpeakerDiarizer.recipeID }).count >= 2
        else { return }
        // Starting a run cancels the active one. A run already covering this stretch (say, "Find
        // voices in all recordings") re-queues its work when the voices change, so leave it be.
        if let plans = try? await service.historyPlans(),
           plans.contains(where: { $0.state == "active" && $0.fromMs <= from }) { return }
        _ = try? await service.recognizeHistory(fromMs: from, toMs: now)
        composition.runtime.notifyVoiceConfigurationChanged()
    }
    func cancelEnrollment() async {
        service.cancelEnrollment()
        await composition.voiceModels.cancel()
    }
    func recognizeHistory(days: Int?) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let from = days.map { now - Int64(max(1, $0)) * 86_400_000 } ?? 0
        _ = try await service.recognizeHistory(fromMs: from, toMs: now)
        composition.runtime.notifyVoiceConfigurationChanged()
    }
    func cancelRun(id: String) async throws {
        try await service.cancel(runId: id)
        composition.runtime.notifyVoiceConfigurationChanged()
    }
    func undoRun(id: String) async throws {
        try await service.undo(runId: id)
        composition.runtime.notifyVoiceConfigurationChanged()
    }
    func clearAutomaticNames() async throws {
        try await service.clearAutomaticNames()
        composition.runtime.notifyVoiceConfigurationChanged()
    }
    func forgetVoice(personId: String) async throws {
        try await service.forgetProfile(personId: personId)
        composition.runtime.notifyVoiceConfigurationChanged()
    }
    func removeExamples(ids: [String]) async throws {
        try await service.removeExamples(ids: ids)
        composition.runtime.notifyVoiceConfigurationChanged()
    }
}

extension UnknownVoiceDisplay {
    /// One clip per recording, newest first, with what was said; and when the voice tends to be heard.
    nonisolated static func build(_ group: VoiceRecognitionService.UnknownVoiceGroup,
                                  wallMs: (String, Int64) -> Int64?,
                                  transcript: (String) -> SegmentTranscript?,
                                  now: Date = Date(), calendar: Calendar = .current) -> UnknownVoiceDisplay {
        let timed = group.crops.map { crop in
            (crop, wallMs(crop.segmentId, crop.startMediaMs).map { Date(timeIntervalSince1970: Double($0) / 1_000) })
        }
        var seen = Set<String>()
        var clips: [UnknownVoiceClip] = []
        for (crop, heardAt) in timed.sorted(by: { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) })
        where seen.insert(crop.segmentId).inserted {
            clips.append(UnknownVoiceClip(id: crop.id, segmentId: crop.segmentId, startMs: crop.startMediaMs,
                endMs: crop.endMediaMs, heardAt: heardAt,
                quote: quote(transcript(crop.segmentId), from: crop.startMediaMs, to: crop.endMediaMs)))
        }
        let dates = timed.compactMap(\.1)
        let parts = [timeOfDay(dates, calendar: calendar), dates.max().map { lastHeard($0, now: now, calendar: calendar) }]
            .compactMap { $0 }
        let detail = parts.joined(separator: " · ")
        return UnknownVoiceDisplay(id: group.id, recordingCount: group.recordingCount,
                                   detail: detail.prefix(1).uppercased() + detail.dropFirst(), clips: clips)
    }

    nonisolated static func quote(_ transcript: SegmentTranscript?, from start: Int64, to end: Int64) -> String? {
        guard let transcript else { return nil }
        let words = transcript.words.filter { $0.startMs < end && $0.endMs > start }.map(\.text)
        let raw = words.isEmpty
            ? transcript.segments.filter { $0.startMs < end && $0.endMs > start }.map(\.text)
            : words
        let text = raw.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        guard text.count > 64 else { return "“\(text)”" }
        let cut = text.prefix(64)
        return "“\(cut.prefix(upTo: cut.lastIndex(of: " ") ?? cut.endIndex))…”"
    }

    /// "mostly mornings" when most sightings share a part of the day; nil when they don't.
    nonisolated static func timeOfDay(_ dates: [Date], calendar: Calendar) -> String? {
        guard dates.count >= 3 else { return nil }
        let names = dates.map { date -> String in
            switch calendar.component(.hour, from: date) {
            case 5..<12: "mostly mornings"
            case 12..<17: "mostly afternoons"
            case 17..<22: "mostly evenings"
            default: "mostly at night"
            }
        }
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        guard let top = counts.max(by: { $0.value < $1.value }), Double(top.value) / Double(dates.count) >= 0.6
        else { return nil }
        return top.key
    }

    nonisolated static func lastHeard(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "last heard today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "last heard yesterday"
        }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 99
        let style = days < 7 ? Date.FormatStyle().weekday(.wide) : Date.FormatStyle().month(.abbreviated).day()
        return "last heard \(date.formatted(style))"
    }
}
