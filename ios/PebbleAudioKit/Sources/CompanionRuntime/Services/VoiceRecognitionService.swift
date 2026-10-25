import AppDB
import CryptoKit
import Foundation
import Receiver
import SegmentStore
import SpeakerRecognition
import Synchronization

public struct VoiceEnrollmentOutcome: Equatable, Sendable {
    public let personId: String
    public let examplesAdded: Int
    public let usableSpeechSeconds: Double
}

public struct VoiceRecognitionStatus: Equatable, Sendable {
    public let configuration: VoiceRecognitionConfiguration
    public let models: SpeakerModelInstallState
    public let isProcessing: Bool
    public let lastMessage: String?
}

/// Model installation is explicit and separate from audio processing. The seam also permits
/// deterministic tests without downloading models or sending audio anywhere.
public protocol VoiceModelManaging: Sendable {
    func state() async -> SpeakerModelInstallState
    func isInstalled() async -> Bool
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
    func cancel() async
}
extension SpeakerModelStore: VoiceModelManaging {}

/// Opt-in local identity, independent of every ASR provider. No timers are owned here: the app
/// requests a bounded slice while foreground, or continues a history run the user requested.
public actor VoiceRecognitionService {
    public nonisolated let updates = StateSubject<Int>(0)
    public static let initialPolicy = SpeakerMatchPolicy(
        minimumSimilarity: 0.55, minimumMargin: 0.10, minimumExamples: 2,
        calibrationID: "public-read-speech-cactus-f145212-v1")
    private let store: VoiceIdentityStore
    private let history: VoiceHistoryPlanStore
    private let files: SegmentFileReader
    private let models: any VoiceModelManaging
    private let analyzer: any SpeakerSpeechAnalyzing
    private let policy: SpeakerMatchPolicy
    private let recipeID: String
    private let protector: any VoiceProfileProtecting
    private var validatedCorpus: Int64?
    private var processing = false
    private var enrolling = false
    private var resumed = false
    private var lastMessage: String?
    private var foreground = true
    private var discoveryAtMs: Int64 = 0
    private var discoveryCorpus: Int64 = -1
    private var discovered = Set<String>()
    private var changedSegments = Set<String>()
    private nonisolated let enrollmentGeneration = Mutex<UInt64>(0)

    public init(database: AppDatabase, files: SegmentFileReader, models: SpeakerModelStore,
                policy: SpeakerMatchPolicy = VoiceRecognitionService.initialPolicy,
                protector: any VoiceProfileProtecting = VoiceProfileCipher()) {
        store = VoiceIdentityStore(db: database)
        history = VoiceHistoryPlanStore(db: database)
        self.files = files; self.models = models; self.policy = policy
        analyzer = LocalSpeakerDiarizer(embeddingModelDirectory: models.embeddingDirectory,
                                       segmentationModelDirectory: models.segmentationDirectory)
        recipeID = LocalSpeakerDiarizer.recipeID
        self.protector = protector
    }

    public init(database: AppDatabase, files: SegmentFileReader, models: any VoiceModelManaging,
                analyzer: any SpeakerSpeechAnalyzing, policy: SpeakerMatchPolicy,
                recipeID: String, protector: any VoiceProfileProtecting = VoiceProfileCipher()) {
        store = VoiceIdentityStore(db: database)
        history = VoiceHistoryPlanStore(db: database)
        self.files = files; self.models = models; self.analyzer = analyzer
        self.policy = policy; self.recipeID = recipeID; self.protector = protector
    }

    public func status() async throws -> VoiceRecognitionStatus {
        try await reconcileProfileProtection()
        _ = await models.isInstalled()
        return VoiceRecognitionStatus(configuration: try await store.configuration(),
            models: await models.state(), isProcessing: processing || enrolling, lastMessage: lastMessage)
    }
    /// Missing device-bound keys after restore invalidate only derived voice state. A locked
    /// device is temporary and must never erase profiles. The original person/manual names stay.
    public func reconcileProfileProtection() async throws {
        let config = try await store.configuration()
        guard validatedCorpus != config.corpusRevision else { return }
        let examples = try await store.examples()
        guard !examples.isEmpty else { validatedCorpus = config.corpusRevision; return }
        do {
            guard try protector.hasKey() else { throw VoiceProfileProtectionError.keyMissing }
            for example in examples { _ = try protector.open(example.embeddingJSON) }
            validatedCorpus = config.corpusRevision
        } catch let error as VoiceProfileProtectionError {
            switch error {
            case .keyMissing, .invalidEnvelope:
                cancelEnrollment()
                changedSegments.formUnion(try await store.automaticSegmentIds())
                try await store.resetUnavailableProfiles()
                await analyzer.setEnabled(false); await analyzer.release()
                lastMessage = "Voice samples could not be restored on this phone. Set up the voices again."
                validatedCorpus = try await store.configuration().corpusRevision
                changed()
            case .deviceLocked, .keychain: throw error
            }
        }
    }

    public func profiles() async throws -> [VoiceProfileSummary] { try await store.profiles() }
    public func examples(personId: String? = nil) async throws -> [VoiceConfirmedExample] {
        try await store.examples(personId: personId)
    }
    public func runs() async throws -> [VoiceRunSummary] { try await store.runs() }
    public func historyPlans() async throws -> [VoiceHistoryPlan] { try await history.plans() }

    public func setEnabled(_ enabled: Bool) async throws {
        if !enabled { cancelEnrollment() }
        try await store.setMode(enabled ? .local : .off)
        await analyzer.setEnabled(enabled)
        if !enabled { await models.cancel(); await analyzer.release() }
        discoveryAtMs = 0
        if enabled { discovered.removeAll() }
        lastMessage = nil
        changed()
    }

    public func setForeground(_ value: Bool) async {
        foreground = value
        if !value {
            cancelEnrollment()
            await analyzer.setEnabled(false)
            await analyzer.release()
        }
    }

    public func release() async {
        cancelEnrollment()
        await analyzer.setEnabled(false)
        await analyzer.release()
    }

    /// The existing pipeline calls this; no new timer, scan loop, or background work is created.
    public func foregroundPass(segmentStore: SegmentStore) async -> Bool {
        do { try await reconcileProfileProtection() }
        catch { lastMessage = error.localizedDescription; return false }
        guard foreground, let config = try? await store.configuration(), config.mode == .local,
              await models.isInstalled(), let examples = try? await store.examples(), !examples.isEmpty,
              let enabledAt = config.enabledAtMs else { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var queued = false
        changedSegments.formUnion((try? await history.reconcileCorpus()) ?? [])
        let plans = (try? await history.plans()) ?? []
        var metas: [SegmentMeta]?
        if plans.contains(where: { $0.state == "active" && !$0.discoveryComplete }) {
            metas = await segmentStore.listSegments()
            do { queued = try await fillHistory(plans: plans, metas: metas!) }
            catch { lastMessage = error.localizedDescription; changed() }
        }
        if discoveryCorpus != config.corpusRevision {
            discoveryCorpus = config.corpusRevision; discovered.removeAll(); discoveryAtMs = 0
        }
        if now - discoveryAtMs >= 30_000 {
            let currentMetas: [SegmentMeta]
            if let metas { currentMetas = metas } else { currentMetas = await segmentStore.listSegments() }
            let candidates = currentMetas.filter { !$0.isOpen && ($0.closedAtMs ?? $0.receivedAtMs) >= enabledAt }
            var attempted = 0
            for meta in candidates {
                let key = "\(meta.segmentId):\(meta.logBytes):\(meta.frameCount)"
                guard !discovered.contains(key) else { continue }
                do { try await enqueueSegment(segmentId: meta.segmentId); queued = true }
                catch { lastMessage = error.localizedDescription }
                discovered.insert(key); attempted += 1
                if attempted >= 2 { break }
            }
            // A large catch-up is still bounded at two new segment jobs per pass.
            if attempted < 2 { discoveryAtMs = now }
        }
        return await processPending() || queued
    }

    public func takeChangedSegmentIds() -> [String] {
        let ids = Array(changedSegments); changedSegments.removeAll(); return ids
    }

    public func ensureModels(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        defer { changed() }
        try await models.install(progress: progress)
    }

    /// Immediate cancellation even while this actor is awaiting native inference or SQLite.
    public nonisolated func cancelEnrollment() {
        enrollmentGeneration.withLock { $0 &+= 1 }
    }

    public func enroll(personId: String, segmentId: String,
                       startMediaMs: Int64, endMediaMs: Int64) async throws -> VoiceEnrollmentOutcome {
        let generation = beginEnrollment()
        try await requireReady()
        try checkEnrollment(generation)
        let source = try await load(segmentId)
        _ = try await store.prepareSource(segmentId: segmentId, revision: source.revision)
        guard let context = try await store.workContext(segmentId: segmentId) else {
            throw VoiceEnrollmentError.changedDuringProcessing
        }
        let pcm = try await Task.detached(priority: .utility) {
            try source.pcm(startMediaMs: startMediaMs, endMediaMs: endMediaMs)
        }.value
        return try await enroll(personId: personId, audio: SpeakerAnalysisAudio(
            pcm16LE: pcm, sourceID: segmentId, sourceRevision: source.revision,
            sessionID: segmentId, sourceStartSample: Int(startMediaMs) * 16),
            context: context, generation: generation)
    }

    /// Raw phone enrollment exists only in this call's memory. The database retains derived
    /// embeddings and a digest/provenance, never a second recording or a WAV file.
    public func enrollPCM(personId: String, pcm16LE: Data,
                          sessionID: String) async throws -> VoiceEnrollmentOutcome {
        try await reconcileProfileProtection()
        let generation = beginEnrollment()
        guard await models.isInstalled() else { throw VoiceEnrollmentError.modelsNotInstalled }
        try checkEnrollment(generation)
        await analyzer.setEnabled(true)
        guard pcm16LE.count.isMultiple(of: 2), (64_000...960_000).contains(pcm16LE.count),
              !sessionID.isEmpty else { throw VoiceEnrollmentError.invalidRange }
        let id = "enrollment:" + UUID().uuidString.lowercased()
        let revision = SHA256.hash(data: pcm16LE).map { String(format: "%02x", $0) }.joined()
        _ = try await store.prepareSource(segmentId: id, revision: revision)
        guard let context = try await store.workContext(segmentId: id) else {
            throw VoiceEnrollmentError.changedDuringProcessing
        }
        return try await enroll(personId: personId, audio: SpeakerAnalysisAudio(
            pcm16LE: pcm16LE, sourceID: id, sourceRevision: revision,
            sessionID: sessionID, sourceStartSample: 0), context: context, generation: generation)
    }

    private func enroll(personId: String, audio: SpeakerAnalysisAudio, context: VoiceWorkContext,
                        generation: UInt64) async throws -> VoiceEnrollmentOutcome {
        while processing || enrolling {
            try checkEnrollment(generation)
            try await Task.sleep(for: .milliseconds(50))
        }
        enrolling = true; changed()
        do {
            let outcome = try await saveEnrollment(personId: personId, audio: audio,
                                                   context: context, generation: generation)
            await analyzer.release()
            enrolling = false; changed()
            return outcome
        } catch {
            await analyzer.release()
            enrolling = false; changed()
            throw error
        }
    }

    private func saveEnrollment(personId: String, audio: SpeakerAnalysisAudio,
                                context: VoiceWorkContext, generation: UInt64) async throws -> VoiceEnrollmentOutcome {
        try checkEnrollment(generation)
        let analysis = try await analyzer.analyze(audio)
        try checkEnrollment(generation)
        let clean = try Self.enrollmentTurns(analysis, audio: audio)
        let prior = context.examples.filter { $0.personId == personId && $0.recipeID == analysis.recipeID }
        let fresh = clean.filter { turn in
            !prior.contains { $0.sourceRevision == audio.sourceRevision
                && $0.startMediaMs < Int64(turn.endSample / 16)
                && $0.endMediaMs > Int64(turn.startSample / 16) }
        }
        guard prior.count + fresh.count <= 32 else { throw VoiceEnrollmentError.profileFull }
        let encoder = JSONEncoder()
        let confirmation = UUID().uuidString.lowercased()
        let examples = try fresh.map { turn -> VoiceConfirmedExample in
            let embedding = turn.embedding!
            return VoiceConfirmedExample(personId: personId, confirmationID: confirmation,
                sessionID: audio.sessionID, segmentId: audio.sourceID,
                startMediaMs: Int64(turn.startSample / 16), endMediaMs: Int64(turn.endSample / 16),
                sourceRevision: audio.sourceRevision, recipeID: analysis.recipeID,
                recipeJSON: try encoder.encode(embedding.recipe),
                embeddingJSON: try protector.seal(encoder.encode(embedding)),
                qualityJSON: try encoder.encode(EnrollmentQuality(
                    speechConfidence: turn.speechConfidence,
                    durationSeconds: Double(turn.endSample - turn.startSample) / 16_000)))
        }
        try checkEnrollment(generation)
        if !examples.isEmpty {
            guard try await store.commitExamples(examples, token: context.token, authorize: { [self] in
                enrollmentGeneration.withLock { $0 == generation }
            }) else { throw VoiceEnrollmentError.changedDuringProcessing }
        }
        lastMessage = nil; changed()
        return VoiceEnrollmentOutcome(personId: personId, examplesAdded: examples.count,
            usableSpeechSeconds: clean.reduce(0) { $0 + Double($1.endSample - $1.startSample) / 16_000 })
    }

    private struct EnrollmentQuality: Codable {
        let speechConfidence: Double
        let durationSeconds: Double
    }

    /// A human selection is necessary but cannot prove purity. Reject overlap and multiple
    /// acoustic clusters even when a transcriber calls the whole selection one speaker.
    static func enrollmentTurns(_ analysis: SpeakerAnalysis,
                                audio: SpeakerAnalysisAudio) throws -> [SpeakerTurn] {
        let lower = audio.sourceStartSample
        let upper = lower + audio.pcm16LE.count / 2
        guard !analysis.turns.contains(where: { $0.overlap }) else {
            throw VoiceEnrollmentError.multipleSpeakers
        }
        let clusters = Set(analysis.turns.compactMap(\.clusterID))
        guard clusters.count <= 1 else { throw VoiceEnrollmentError.multipleSpeakers }
        let clean = analysis.turns.filter {
            $0.embedding != nil && $0.clusterID != nil && $0.speechConfidence >= 0.7
                && $0.startSample >= lower && $0.endSample <= upper
                && $0.endSample - $0.startSample >= 32_000
        }.sorted { $0.startSample < $1.startSample }
        guard !clean.isEmpty else { throw VoiceEnrollmentError.notEnoughSpeech }
        for pair in zip(clean, clean.dropFirst()) where pair.0.endSample > pair.1.startSample {
            throw VoiceEnrollmentError.multipleSpeakers
        }
        return clean
    }

    /// The normal foreground/new-recording hook. Repeating it is idempotent in the DB.
    public func enqueueSegment(segmentId: String) async throws {
        let config = try await store.configuration()
        guard config.mode == .local,
              !(try await store.examples()).isEmpty, await models.isInstalled() else { return }
        let source = try await load(segmentId)
        guard !source.meta.isOpen, source.endMediaMs >= 2_000 else { return }
        _ = try await store.prepareSource(segmentId: segmentId, revision: source.revision)
        try await store.enqueueJob(runID: "recent:\(segmentId):\(config.generation):\(config.corpusRevision):\(source.revision)", segmentId: segmentId,
            startMediaMs: 0, endMediaMs: source.endMediaMs, recipeID: recipeID)
        changed()
    }

    /// A finite, user-requested history run. The caller drives processPending while visible or
    /// under its explicitly requested task. Existing local recordings only; no audio downloads.
    public func recognizeHistory(fromMs: Int64, toMs: Int64) async throws -> String {
        try await requireReady()
        guard fromMs < toMs else { throw VoiceEnrollmentError.invalidRange }
        let examples = try await store.examples()
        guard Dictionary(grouping: examples.filter { $0.recipeID == recipeID }, by: \.personId).values.contains(where: { $0.count >= policy.minimumExamples })
        else { throw VoiceEnrollmentError.notEnoughExamples }
        for plan in try await history.plans() where plan.state == "active" {
            let jobs = try await store.jobs(runID: plan.runID)
            if !plan.discoveryComplete || jobs.contains(where: { $0.state == .pending || $0.state == .running }) {
                try await store.cancelRun(plan.runID)
                try await history.cancel(runID: plan.runID)
            }
        }
        let run = UUID().uuidString.lowercased()
        try await history.create(runID: run, fromMs: fromMs, toMs: toMs)
        lastMessage = nil
        changed()
        return run
    }

    private func fillHistory(plans: [VoiceHistoryPlan], metas: [SegmentMeta]) async throws -> Bool {
        var capacity = try await history.pendingCapacity()
        guard capacity > 0 else { return false }
        var advanced = false
        var inspected = 0
        let ordered = metas.sorted { ($0.startWallMs, $0.segmentId) < ($1.startWallMs, $1.segmentId) }
        for plan in plans.reversed() where plan.state == "active" && !plan.discoveryComplete {
            let candidates = ordered.filter {
                !$0.isOpen && $0.startWallMs < plan.toMs
                    && $0.startWallMs + SegmentMediaClock($0).wallSpanMs > plan.fromMs
                    && ($0.startWallMs > plan.cursorStartMs
                        || ($0.startWallMs == plan.cursorStartMs && $0.segmentId > plan.cursorSegmentId))
            }
            if candidates.isEmpty { try await history.finishDiscovery(runID: plan.runID); advanced = true; continue }
            for meta in candidates {
                try Task.checkCancellation()
                guard foreground, capacity > 0, inspected < 2 else { if advanced { changed() }; return advanced }
                var queued = false
                do {
                    let source = try await load(meta.segmentId)
                    let clock = SegmentMediaClock(source.meta)
                    let start = plan.fromMs <= meta.startWallMs ? 0
                        : clock.media(fromWall: plan.fromMs - meta.startWallMs)
                    let end = plan.toMs >= meta.startWallMs + clock.wallSpanMs ? source.endMediaMs
                        : min(source.endMediaMs, clock.media(fromWall: plan.toMs - meta.startWallMs))
                    if end - start >= 2_000 {
                        _ = try await store.prepareSource(segmentId: meta.segmentId, revision: source.revision)
                        try await store.enqueueJob(runID: plan.runID, segmentId: meta.segmentId,
                            startMediaMs: start, endMediaMs: end, recipeID: recipeID, explicitRerun: true)
                        queued = true; capacity -= 1
                    }
                } catch VoiceEnrollmentError.audioUnavailable { /* unavailable audio remains unavailable, no download */ }
                catch VoiceIdentityError.sourceDeleted { /* source deleted after scope was chosen */ }
                catch VoiceIdentityError.capacityExceeded { if advanced { changed() }; return advanced }
                try await history.advance(runID: plan.runID, startMs: meta.startWallMs,
                    segmentId: meta.segmentId, queued: queued, complete: meta.segmentId == candidates.last?.segmentId)
                inspected += 1; advanced = true
            }
        }
        if advanced { changed() }
        return advanced
    }

    /// Each call performs at most two (or the caller's smaller bound) ten-second windows.
    /// False means no window was processed. Native handles are released at the slice boundary.
    @discardableResult public func processPending(maxWindows: Int = 2) async -> Bool {
        do { try await reconcileProfileProtection() }
        catch { lastMessage = error.localizedDescription; return false }
        guard foreground, !processing, !enrolling, maxWindows > 0,
              (try? await store.configuration().mode) == .local,
              await models.isInstalled() else { return false }
        processing = true; changed()
        var didWork = false
        var cached: VoiceAudioSource?
        do {
            if !resumed { try await store.resumeInterruptedJobs(); resumed = true }
            await analyzer.setEnabled(true)
            for _ in 0..<min(maxWindows, 2) {
                try Task.checkCancellation()
                guard foreground else { break }
                guard let job = try await store.claimNextJob() else { break }
                do {
                    let source: VoiceAudioSource
                    if let cached, cached.meta.segmentId == job.segmentId { source = cached }
                    else { source = try await load(job.segmentId); cached = source }
                    guard source.revision == job.token.sourceRevision,
                          let context = try await store.workContext(segmentId: job.segmentId),
                          context.token == job.token else { throw VoiceEnrollmentError.changedDuringProcessing }
                    var attributions: [VoiceAutomaticAttribution] = []
                    let next: Int64
                    if let range = source.nextRange(afterMediaMs: job.cursorMediaMs, throughMediaMs: job.endMediaMs) {
                        let pcm = try await Task.detached(priority: .utility) {
                            try source.pcm(startMediaMs: range.lowerBound, endMediaMs: range.upperBound)
                        }.value
                        let analysis = try await analyzer.analyze(SpeakerAnalysisAudio(
                            pcm16LE: pcm, sourceID: job.segmentId, sourceRevision: source.revision,
                            sessionID: job.segmentId, sourceStartSample: Int(range.lowerBound) * 16))
                        attributions = try Self.match(analysis, job: job, examples: context.examples,
                                                      policy: policy, window: range, protector: protector)
                        next = range.upperBound
                    } else { next = job.endMediaMs }
                    try Task.checkCancellation()
                    let committed = try await store.advanceJob(id: job.id, expectedCursorMediaMs: job.cursorMediaMs,
                        nextCursorMediaMs: next, attributions: attributions)
                    if committed && !attributions.isEmpty { changedSegments.insert(job.segmentId) }
                    didWork = true; changed()
                } catch {
                    if !foreground || error is CancellationError || (error as? SpeakerRecognitionError) == .disabled {
                        try? await store.releaseJob(id: job.id)
                        break
                    }
                    try? await store.failJob(id: job.id, error: error.localizedDescription, retryable: false)
                    lastMessage = error.localizedDescription; changed()
                }
            }
        } catch {
            if !(error is CancellationError) { lastMessage = error.localizedDescription }
        }
        await analyzer.release()
        processing = false; changed()
        return didWork
    }

    static func match(_ analysis: SpeakerAnalysis, job: VoiceRecognitionJob,
                      examples: [VoiceConfirmedExample], policy: SpeakerMatchPolicy,
                      window: Range<Int64>, protector: any VoiceProfileProtecting) throws -> [VoiceAutomaticAttribution] {
        let corpus = try examples.compactMap { example -> ConfirmedSpeakerExample? in
            guard example.recipeID == analysis.recipeID,
                  let person = UUID(uuidString: example.personId) else { return nil }
            let embedding = try JSONDecoder().decode(SpeakerEmbedding.self,
                from: protector.open(example.embeddingJSON))
            return ConfirmedSpeakerExample(id: example.id, personID: person,
                confirmationID: example.confirmationID, sessionID: example.sessionID, embedding: embedding)
        }
        return try analysis.turns.compactMap { turn in
            guard !turn.overlap, turn.speechConfidence >= 0.7, let embedding = turn.embedding,
                  turn.startSample >= Int(window.lowerBound) * 16,
                  turn.endSample <= Int(window.upperBound) * 16 else { return nil }
            let match = try SpeakerMatcher.match(embedding, examples: corpus, policy: policy)
            guard let person = match.personID, let score = match.score else { return nil }
            return VoiceAutomaticAttribution(personId: person.uuidString.lowercased(), segmentId: job.segmentId,
                startMediaMs: Int64(turn.startSample / 16), endMediaMs: Int64(turn.endSample / 16),
                sourceRevision: job.token.sourceRevision, recipeID: analysis.recipeID, score: score,
                margin: match.margin, calibrationID: match.calibrationID, runID: job.runID)
        }
    }

    public func cancel(runId: String) async throws {
        try await store.cancelRun(runId); try await history.cancel(runID: runId); changed()
    }
    public func undo(runId: String) async throws {
        changedSegments.formUnion(try await store.automaticSegmentIds(runID: runId))
        try await store.undoRun(runId); try await history.cancel(runID: runId, undo: true); changed()
    }
    public func forgetProfile(personId: String) async throws {
        cancelEnrollment()
        changedSegments.formUnion(try await store.automaticSegmentIds(personId: personId))
        try await store.forgetProfile(personId: personId); changed()
    }
    public func removeExample(id: String) async throws {
        cancelEnrollment()
        if let example = try await store.examples().first(where: { $0.id == id }) {
            changedSegments.formUnion(try await store.automaticSegmentIds(personId: example.personId))
        }
        try await store.removeExample(id: id); changed()
    }
    public func clearAutomaticNames() async throws {
        changedSegments.formUnion(try await store.automaticSegmentIds())
        try await store.clearAutomatic(); changed()
    }

    private func requireReady() async throws {
        try await reconcileProfileProtection()
        guard try await store.configuration().mode == .local else { throw VoiceEnrollmentError.disabled }
        guard await models.isInstalled() else { throw VoiceEnrollmentError.modelsNotInstalled }
        await analyzer.setEnabled(true)
    }
    private func load(_ segmentId: String) async throws -> VoiceAudioSource {
        let files = files
        return try await Task.detached(priority: .utility) {
            guard let meta = files.readMeta(segmentId) else { throw VoiceEnrollmentError.audioUnavailable }
            return try VoiceAudioSource(meta: meta, frames: files.readFrames(segmentId))
        }.value
    }
    private func beginEnrollment() -> UInt64 {
        enrollmentGeneration.withLock { $0 &+= 1; return $0 }
    }
    private func checkEnrollment(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard enrollmentGeneration.withLock({ $0 == generation }) else { throw CancellationError() }
    }
    private func changed() { updates.value += 1 }
}
