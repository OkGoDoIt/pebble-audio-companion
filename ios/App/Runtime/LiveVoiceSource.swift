import AppDB
import CompanionRuntime
import Foundation
import GRDB
import SpeakerRecognition

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
    func watchSampleAudio(fromWallMs: Int64, toWallMs: Int64) async -> WatchVoiceSampleAudio? {
        await service.watchSampleAudio(fromWallMs: fromWallMs, toWallMs: toWallMs)
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
    func enrollPassage(personId: String, turn: TranscriptTurn) async throws -> Int {
        guard turn.canRememberVoice, let start = turn.sourceStartMs, let end = turn.sourceEndMs else {
            throw SpeakerEditorError.timingUnavailable
        }
        let result = try await service.enroll(personId: personId, segmentId: turn.segmentId,
                                              startMediaMs: start, endMediaMs: end)
        // Remembering a passage explicitly promises to update older retained recordings.
        // The durable fixed-scope plan resumes a bounded queue in the foreground.
        if try await service.status().configuration.mode == .local,
           try await service.examples().filter({ $0.personId == personId && $0.recipeID == LocalSpeakerDiarizer.recipeID }).count >= 2 {
            _ = try await service.recognizeHistory(fromMs: 0, toMs: Int64(Date().timeIntervalSince1970 * 1_000))
        }
        composition.runtime.notifyVoiceConfigurationChanged()
        return result.examplesAdded
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
