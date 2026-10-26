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
    /// Groups every crop this one confirmation produced; nil when nothing new was saved.
    public var confirmationID: String? = nil
    /// Speech in the passage that sounded like someone else and was left out of learning.
    public var otherVoiceSeconds: Double = 0
    public init(personId: String, examplesAdded: Int, usableSpeechSeconds: Double,
                confirmationID: String? = nil, otherVoiceSeconds: Double = 0) {
        self.personId = personId; self.examplesAdded = examplesAdded
        self.usableSpeechSeconds = usableSpeechSeconds; self.confirmationID = confirmationID
        self.otherVoiceSeconds = otherVoiceSeconds
    }
}

public struct VoiceRecognitionStatus: Equatable, Sendable {
    public let configuration: VoiceRecognitionConfiguration
    public let models: SpeakerModelInstallState
    public let isProcessing: Bool
    public let lastMessage: String?
    /// Recordings with audio still to check.
    public var pendingRecordings = 0
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

/// Opt-in local identity, independent of every ASR provider. No timers are owned here: the
/// pipeline pass asks for a bounded slice, and `BackgroundWorkPolicy.decideVoiceRecognition`
/// decides whether the models may run (on a charger, on screen or not).
public actor VoiceRecognitionService {
    public nonisolated let updates = StateSubject<Int>(0)
    public static let initialPolicy = SpeakerMatchPolicy(
        minimumSimilarity: 0.55, minimumMargin: 0.10, minimumExamples: 2,
        calibrationID: "public-read-speech-cactus-f145212-codec-variants-v2")
    private let store: VoiceIdentityStore
    private let history: VoiceHistoryPlanStore
    private let files: SegmentFileReader
    private let models: any VoiceModelManaging
    private let analyzer: any SpeakerSpeechAnalyzing
    private let policy: SpeakerMatchPolicy
    private let recipeID: String
    private let protector: any VoiceProfileProtecting
    private var validatedCorpus: Int64?
    private var groupCache: (key: String, groups: [UnknownVoiceGroup])?
    private var processing = false
    private var enrolling = false
    private var resumed = false
    private var lastMessage: String?
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
        var status = VoiceRecognitionStatus(configuration: try await store.configuration(),
            models: await models.state(), isProcessing: processing || enrolling, lastMessage: lastMessage)
        status.pendingRecordings = try await store.pendingRecordingCount()
        return status
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

    /// The pipeline pass calls this; no timer or scan loop of its own. New recordings are found
    /// and queued on every call; the models run only while `mayAnalyze` holds, which is
    /// re-read between windows so unplugging stops at the next one.
    public func pass(segmentStore: SegmentStore,
                     mayAnalyze: @escaping @Sendable () -> Bool) async -> (didWork: Bool, windows: Int) {
        do { try await reconcileProfileProtection() }
        catch { lastMessage = error.localizedDescription; return (false, 0) }
        guard let config = try? await store.configuration(), config.mode == .local,
              await models.isInstalled(), let examples = try? await store.examples(), !examples.isEmpty,
              let enabledAt = config.enabledAtMs else { return (false, 0) }
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
        guard mayAnalyze() else { return (queued, 0) }
        let slice = await analyzePending(mayRun: mayAnalyze)
        return (slice.didWork || queued, slice.windows)
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
        let pcm = try await Task.detached(priority: .utility) {
            try source.pcm(startMediaMs: startMediaMs, endMediaMs: endMediaMs)
        }.value
        // A recording still being written changes revision when it grows, and a new revision
        // erases every artifact tied to the old one, this sample included. Copy it out instead.
        if source.meta.isOpen {
            return try await enrollDetached(personId: personId, pcm16LE: pcm, sessionID: segmentId,
                                            microphone: .watch, generation: generation)
        }
        _ = try await store.prepareSource(segmentId: segmentId, revision: source.revision)
        guard let context = try await store.workContext(segmentId: segmentId) else {
            throw VoiceEnrollmentError.changedDuringProcessing
        }
        return try await enroll(personId: personId, audio: SpeakerAnalysisAudio(
            pcm16LE: pcm, sourceID: segmentId, sourceRevision: source.revision,
            sessionID: segmentId, sourceStartSample: Int(startMediaMs) * 16),
            context: context, generation: generation)
    }

    /// Raw phone enrollment exists only in this call's memory. The database retains derived
    /// embeddings and a digest/provenance, never a second recording or a WAV file.
    public func enrollPCM(personId: String, pcm16LE: Data, sessionID: String,
                          microphone: VoiceSampleMicrophone = .phone) async throws -> VoiceEnrollmentOutcome {
        try await enrollDetached(personId: personId, pcm16LE: pcm16LE, sessionID: sessionID,
                                 microphone: microphone, generation: beginEnrollment())
    }

    /// A sample the person recorded through the watch just now: its audio between two instants
    /// on the watch's sample clock (`watchSampleAudio`'s `watchFromMs`/`watchToMs`), copied out of
    /// the recording it landed in. The most recent 30 s
    /// are used when the window is longer.
    public func enrollWatch(personId: String, fromWallMs: Int64, toWallMs: Int64,
                            sessionID: String) async throws -> VoiceEnrollmentOutcome {
        let generation = beginEnrollment()
        let reader = WatchVoiceSampleReader(files: files)
        guard let audio = try await Task.detached(priority: .utility, operation: {
            try reader.audio(fromWallMs: fromWallMs, toWallMs: toWallMs)
        }).value else { throw VoiceEnrollmentError.audioUnavailable }
        guard audio.pcm16LE.count >= 64_000 else { throw VoiceEnrollmentError.notEnoughSpeech }
        let pcm = audio.pcm16LE.suffix(960_000)
        return try await enrollDetached(personId: personId, pcm16LE: Data(pcm), sessionID: sessionID,
                                        microphone: .watch, generation: generation)
    }

    /// The watch's audio for a sample the person is recording now, asked for on this phone's
    /// clock: translated onto the watch's sample clock by its measured lag, padded at the end for
    /// delivery delay. `receivedThroughWallMs` comes back on the phone's clock; `watchFromMs`/
    /// `watchToMs` are what `enrollWatch` takes. Nil when no watch audio has arrived recently.
    public nonisolated func watchSampleAudio(phoneStartMs: Int64, phoneEndMs: Int64,
                                             now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) async -> WatchVoiceSampleAudio? {
        let reader = WatchVoiceSampleReader(files: files)
        return await Task.detached(priority: .utility) {
            guard let lag = reader.clockLagMs(now: now),
                  let audio = try? reader.audio(fromWallMs: phoneStartMs - lag, toWallMs: phoneEndMs - lag + 1_500)
            else { return nil }
            return WatchVoiceSampleAudio(pcm16LE: audio.pcm16LE, receivedThroughWallMs: audio.receivedThroughWallMs + lag,
                                         watchFromMs: audio.watchFromMs, watchToMs: audio.watchToMs)
        }.value
    }

    private func enrollDetached(personId: String, pcm16LE: Data, sessionID: String,
                                microphone: VoiceSampleMicrophone,
                                generation: UInt64) async throws -> VoiceEnrollmentOutcome {
        try await reconcileProfileProtection()
        try checkEnrollment(generation)
        guard await models.isInstalled() else { throw VoiceEnrollmentError.modelsNotInstalled }
        try checkEnrollment(generation)
        await analyzer.setEnabled(true)
        guard pcm16LE.count.isMultiple(of: 2), (64_000...960_000).contains(pcm16LE.count),
              !sessionID.isEmpty else { throw VoiceEnrollmentError.invalidRange }
        let id = microphone.sourcePrefix + UUID().uuidString.lowercased()
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
        let (clean, otherVoiceSamples) = try Self.enrollmentTurns(analysis, audio: audio,
                                                                  sameVoiceSimilarity: policy.minimumSimilarity)
        let prior = context.examples.filter { $0.personId == personId && $0.recipeID == analysis.recipeID }
        let fresh = Self.diverse(clean.filter { turn in
            !prior.contains { ($0.segmentId == audio.sourceID || $0.sourceRevision == audio.sourceRevision)
                && $0.startMediaMs < Int64(turn.endSample / 16)
                && $0.endMediaMs > Int64(turn.startSample / 16) }
        }, limit: Self.cropsPerPassage)
        // Every name teaches now, so a profile fills; the most redundant crops make room.
        let retiring = try Self.retirements(prior: prior.map { example in
            (id: example.id, confirmationID: example.confirmationID,
             guided: VoiceSampleMicrophone.isGuided(segmentId: example.segmentId),
             embedding: try StoredEnrollmentEmbedding.decode(protector.open(example.embeddingJSON)).primary)
        }, incoming: fresh.compactMap(\.embedding), capacity: Self.profileCapacity)
        let encoder = JSONEncoder()
        let confirmation = UUID().uuidString.lowercased()
        // The watch's codec changes the embedding distribution. Keep one alternate acoustic
        // view of each real phone crop, never count it as another independent voice sample.
        let codecAudio: Data?
        if VoiceSampleMicrophone.of(segmentId: audio.sourceID) == .phone, !fresh.isEmpty {
            codecAudio = try await Task.detached(priority: .utility) {
                try VoiceEnrollmentAudioCodec.watchVariant(audio.pcm16LE)
            }.value
        } else { codecAudio = nil }
        var examples: [VoiceConfirmedExample] = []
        for turn in fresh {
            try checkEnrollment(generation)
            let embedding = turn.embedding!
            var variants: [SpeakerEmbedding] = []
            if let codecAudio {
                let start = (turn.startSample - audio.sourceStartSample) * 2
                let end = (turn.endSample - audio.sourceStartSample) * 2
                let evidence = SpeakerAudioEvidence(sourceID: audio.sourceID,
                    sourceRevision: audio.sourceRevision, sessionID: audio.sessionID,
                    startSample: turn.startSample, endSample: turn.endSample,
                    speechOnly: true, singleSpeaker: true, containsDiscontinuity: false)
                // Acoustic segmentation and explicit human confirmation already established
                // these exact crop bounds; encoding does not change the speaker or the range.
                if let variant = try await analyzer.confirmedEmbedding(for: SpeakerAudioSample(
                    pcm16LE: codecAudio.subdata(in: start..<end), evidence: evidence)) {
                    guard variant.recipe == embedding.recipe else {
                        throw SpeakerRecognitionError.invalidCorpus("Enrollment variants must use the same embedding model")
                    }
                    variants = [variant]
                }
            }
            let payload = StoredEnrollmentEmbedding(primary: embedding, variants: variants)
            examples.append(VoiceConfirmedExample(personId: personId, confirmationID: confirmation,
                sessionID: audio.sessionID, segmentId: audio.sourceID,
                startMediaMs: Int64(turn.startSample / 16), endMediaMs: Int64(turn.endSample / 16),
                sourceRevision: audio.sourceRevision, recipeID: analysis.recipeID,
                recipeJSON: try encoder.encode(embedding.recipe),
                embeddingJSON: try protector.seal(encoder.encode(payload)),
                qualityJSON: try encoder.encode(EnrollmentQuality(
                    speechConfidence: turn.speechConfidence,
                    durationSeconds: Double(turn.endSample - turn.startSample) / 16_000,
                    augmentation: variants.isEmpty ? nil : VoiceEnrollmentAudioCodec.recipe))))
        }
        try checkEnrollment(generation)
        if !examples.isEmpty {
            guard try await store.commitExamples(examples, retiring: retiring, token: context.token, authorize: { [self] in
                enrollmentGeneration.withLock { $0 == generation }
            }) else { throw VoiceEnrollmentError.changedDuringProcessing }
        }
        lastMessage = nil; changed()
        return VoiceEnrollmentOutcome(personId: personId, examplesAdded: examples.count,
            usableSpeechSeconds: clean.reduce(0) { $0 + Double($1.endSample - $1.startSample) / 16_000 },
            confirmationID: examples.isEmpty ? nil : confirmation,
            otherVoiceSeconds: Double(otherVoiceSamples) / 16_000)
    }

    private struct EnrollmentQuality: Codable {
        let speechConfidence: Double
        let durationSeconds: Double
        let augmentation: String?
    }

    private struct StoredEnrollmentEmbedding: Codable {
        var version = 1
        let primary: SpeakerEmbedding
        let variants: [SpeakerEmbedding]

        static func decode(_ plaintext: Data) throws -> StoredEnrollmentEmbedding {
            let decoder = JSONDecoder()
            if let stored = try? decoder.decode(Self.self, from: plaintext) {
                guard stored.version == 1, stored.variants.count <= 1,
                      stored.variants.allSatisfy({ $0.recipe == stored.primary.recipe }) else {
                    throw VoiceProfileProtectionError.invalidEnvelope
                }
                return stored
            }
            // The initial single-vector payload remains readable after this additive upgrade.
            return try StoredEnrollmentEmbedding(primary: decoder.decode(SpeakerEmbedding.self,
                from: plaintext), variants: [])
        }
    }

    /// A human selection is necessary but cannot prove purity. Reject overlap and multiple
    /// acoustic clusters even when a transcriber calls the whole selection one speaker.
    /// The matcher compares against at most this many crops per person.
    static let profileCapacity = 32
    /// One passage is one situation; a few crops cover how it sounded without crowding the rest.
    static let cropsPerPassage = 4

    /// Up to `limit` crops that sound least alike, starting from the most confident: the watch
    /// makes one voice sound several ways, and those differences are what the profile needs.
    static func diverse(_ turns: [SpeakerTurn], limit: Int) -> [SpeakerTurn] {
        guard turns.count > limit else { return turns }
        var pool = turns.sorted { $0.speechConfidence > $1.speechConfidence }
        var chosen = [pool.removeFirst()]
        while chosen.count < limit, !pool.isEmpty {
            let next = pool.indices.min { a, b in
                closest(pool[a], to: chosen) < closest(pool[b], to: chosen)
            }!
            chosen.append(pool.remove(at: next))
        }
        return chosen.sorted { $0.startSample < $1.startSample }
    }
    private static func closest(_ turn: SpeakerTurn, to chosen: [SpeakerTurn]) -> Double {
        guard let embedding = turn.embedding else { return 1 }
        return chosen.compactMap { other in other.embedding.flatMap { try? embedding.cosineSimilarity(to: $0) } }.max() ?? -1
    }

    /// Which of a person's crops to retire so `incoming` fits in `capacity`: each time, the crop
    /// most like another one that stays. A sample's last crop, and the guided samples, go only
    /// when nothing else can.
    static func retirements(prior: [(id: String, confirmationID: String, guided: Bool, embedding: SpeakerEmbedding)],
                            incoming: [SpeakerEmbedding], capacity: Int) -> [String] {
        var excess = prior.count + incoming.count - capacity
        guard excess > 0 else { return [] }
        var kept = prior
        var retired: [String] = []
        while excess > 0, !kept.isEmpty {
            func redundancy(_ index: Int) -> Double {
                let others = kept.indices.filter { $0 != index }.map { kept[$0].embedding } + incoming
                return others.compactMap { try? kept[index].embedding.cosineSimilarity(to: $0) }.max() ?? -1
            }
            func spareable(_ index: Int, sparingGuided: Bool) -> Bool {
                let sole = !kept.indices.contains { $0 != index && kept[$0].confirmationID == kept[index].confirmationID }
                return !sole && !(sparingGuided && kept[index].guided)
            }
            let candidates = [kept.indices.filter { spareable($0, sparingGuided: true) },
                              kept.indices.filter { spareable($0, sparingGuided: false) },
                              Array(kept.indices)].first { !$0.isEmpty }!
            let victim = candidates.max { redundancy($0) < redundancy($1) }!
            retired.append(kept.remove(at: victim).id)
            excess -= 1
        }
        return retired
    }

    /// The person has confirmed this audio is one voice. The model can still hear one voice as
    /// two (a turned head, a raised voice, a room's echo) or flag a stretch as overlapping, and
    /// neither is a reason to throw the sample away: on 2026-10-26 a 20-second sample of one
    /// person turning their head was refused as "more than one voice". So stretches flagged as
    /// overlapping are left out, the voice with the most speech is the sample, and stretches the
    /// model put in another cluster join it only when they sound like it. A TV or a passer-by is
    /// left out rather than learned. Only too little usable speech refuses the sample.
    static func enrollmentTurns(_ analysis: SpeakerAnalysis, audio: SpeakerAnalysisAudio,
                                sameVoiceSimilarity: Double) throws -> (turns: [SpeakerTurn], otherVoiceSamples: Int) {
        let lower = audio.sourceStartSample
        let upper = lower + audio.pcm16LE.count / 2
        let usable = analysis.turns.filter {
            !$0.overlap && $0.embedding != nil && $0.clusterID != nil && $0.speechConfidence >= 0.7
                && $0.startSample >= lower && $0.endSample <= upper
                && $0.endSample - $0.startSample >= 32_000
        }
        var speech: [String: Int] = [:]
        for turn in usable { speech[turn.clusterID!, default: 0] += turn.endSample - turn.startSample }
        guard let dominant = speech.max(by: { a, b in a.value == b.value ? a.key > b.key : a.value < b.value })?.key
        else { throw VoiceEnrollmentError.notEnoughSpeech }
        let anchors = usable.filter { $0.clusterID == dominant }.compactMap(\.embedding)
        let kept = usable.filter { turn in
            guard turn.clusterID != dominant else { return true }
            let closest = anchors.compactMap { try? turn.embedding!.cosineSimilarity(to: $0) }.max() ?? -1
            return closest >= sameVoiceSimilarity
        }.sorted { $0.startSample < $1.startSample }
        // Turns never overlap in one voice; if the model's do, the earlier one stands.
        var clean: [SpeakerTurn] = []
        for turn in kept where clean.last.map({ $0.endSample <= turn.startSample }) ?? true {
            clean.append(turn)
        }
        let other = usable.filter { turn in !kept.contains { $0.startSample == turn.startSample } }
            .reduce(0) { $0 + $1.endSample - $1.startSample }
        return (clean, other)
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
        changedSegments.insert(segmentId)
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
                guard capacity > 0, inspected < 2 else { if advanced { changed() }; return advanced }
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
                        changedSegments.insert(meta.segmentId)
                        queued = true; capacity -= 1
                    }
                } catch VoiceEnrollmentError.audioUnavailable { /* unavailable audio remains unavailable, no download */ }
                catch VoiceIdentityError.sourceDeleted { /* source deleted after scope was chosen */ }
                catch VoiceIdentityError.sourceInvalidated { /* source changed or was redacted; do not revive stale evidence */ }
                catch VoiceEnrollmentError.unsupportedAudio {
                    lastMessage = "Some recordings use an unsupported audio format and were skipped."
                }
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
    @discardableResult public func processPending(maxWindows: Int = 2,
                                                  mayRun: @escaping @Sendable () -> Bool = { true }) async -> Bool {
        await analyzePending(maxWindows: maxWindows, mayRun: mayRun).didWork
    }

    private func analyzePending(maxWindows: Int = 2,
                                mayRun: @escaping @Sendable () -> Bool) async -> (didWork: Bool, windows: Int) {
        do { try await reconcileProfileProtection() }
        catch { lastMessage = error.localizedDescription; return (false, 0) }
        guard mayRun(), !processing, !enrolling, maxWindows > 0,
              (try? await store.configuration().mode) == .local,
              await models.isInstalled() else { return (false, 0) }
        processing = true; changed()
        var didWork = false
        var windows = 0
        var cached: VoiceAudioSource?
        do {
            if !resumed { try await store.resumeInterruptedJobs(); resumed = true }
            await analyzer.setEnabled(true)
            for _ in 0..<min(maxWindows, 2) {
                try Task.checkCancellation()
                guard mayRun() else { break }
                guard let job = try await store.claimNextJob() else { break }
                do {
                    let source: VoiceAudioSource
                    if let cached, cached.meta.segmentId == job.segmentId { source = cached }
                    else { source = try await load(job.segmentId); cached = source }
                    guard source.revision == job.token.sourceRevision,
                          let context = try await store.workContext(segmentId: job.segmentId),
                          context.token == job.token else { throw VoiceEnrollmentError.changedDuringProcessing }
                    var attributions: [VoiceAutomaticAttribution] = []
                    var unmatched: [VoiceUnmatchedCrop] = []
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
                        unmatched = try Self.unmatched(analysis, job: job, named: attributions,
                                                       window: range, protector: protector)
                        next = range.upperBound
                        windows += 1
                    } else { next = job.endMediaMs }
                    try Task.checkCancellation()
                    let committed = try await store.advanceJob(id: job.id, expectedCursorMediaMs: job.cursorMediaMs,
                        nextCursorMediaMs: next, attributions: attributions, unmatched: unmatched)
                    if committed && !attributions.isEmpty { changedSegments.insert(job.segmentId) }
                    didWork = true; changed()
                } catch {
                    if !mayRun() || error is CancellationError || (error as? SpeakerRecognitionError) == .disabled {
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
        return (didWork, windows)
    }

    static func match(_ analysis: SpeakerAnalysis, job: VoiceRecognitionJob,
                      examples: [VoiceConfirmedExample], policy: SpeakerMatchPolicy,
                      window: Range<Int64>, protector: any VoiceProfileProtecting) throws -> [VoiceAutomaticAttribution] {
        let corpus = try examples.compactMap { example -> ConfirmedSpeakerExample? in
            guard example.recipeID == analysis.recipeID,
                  let person = UUID(uuidString: example.personId) else { return nil }
            let embedding = try StoredEnrollmentEmbedding.decode(protector.open(example.embeddingJSON))
            return ConfirmedSpeakerExample(id: example.id, personID: person,
                confirmationID: example.confirmationID, sessionID: example.sessionID,
                embedding: embedding.primary, embeddingVariants: embedding.variants)
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

    /// Clear, single-voice crops long enough to be voice evidence that no one was named for:
    /// kept, sealed, so recurring unnamed voices can be grouped and offered for naming.
    static func unmatched(_ analysis: SpeakerAnalysis, job: VoiceRecognitionJob, named: [VoiceAutomaticAttribution],
                          window: Range<Int64>, protector: any VoiceProfileProtecting) throws -> [VoiceUnmatchedCrop] {
        let encoder = JSONEncoder()
        return try analysis.turns.compactMap { turn in
            let start = Int64(turn.startSample / 16), end = Int64(turn.endSample / 16)
            guard !turn.overlap, turn.speechConfidence >= 0.7, let embedding = turn.embedding,
                  turn.endSample - turn.startSample >= 32_000,
                  turn.startSample >= Int(window.lowerBound) * 16, turn.endSample <= Int(window.upperBound) * 16,
                  !named.contains(where: { $0.startMediaMs < end && $0.endMediaMs > start }) else { return nil }
            return VoiceUnmatchedCrop(segmentId: job.segmentId, startMediaMs: start, endMediaMs: end,
                sourceRevision: job.token.sourceRevision, recipeID: analysis.recipeID,
                embeddingJSON: try protector.seal(encoder.encode(embedding)), speechConfidence: turn.speechConfidence)
        }
    }

    /// A voice heard in several recordings that recognition couldn't name, with its clearest crops.
    public struct UnknownVoiceGroup: Equatable, Sendable {
        public let crops: [VoiceUnmatchedCrop]
        public var recordingCount: Int { Set(crops.map(\.segmentId)).count }
        public init(crops: [VoiceUnmatchedCrop]) { self.crops = crops }
        /// Only the crops from these recordings: the person said the rest are someone else.
        public func limited(to recordings: Set<String>) -> UnknownVoiceGroup {
            UnknownVoiceGroup(crops: crops.filter { recordings.contains($0.segmentId) })
        }
        /// Its oldest crop: the same while the group's membership is.
        public var id: String { crops.min { ($0.createdAtMs, $0.id) < ($1.createdAtMs, $1.id) }?.id ?? "" }
    }

    /// Recurring unnamed voices, largest first. Reads at most the 400 most recent unnamed crops;
    /// grouping runs again only when those change, so screens can ask freely.
    public func unknownVoiceGroups(limit: Int = 6) async throws -> [UnknownVoiceGroup] {
        let unmatched = VoiceUnmatchedStore(db: store.db)
        let key = try await unmatched.fingerprint()
        if let groupCache, groupCache.key == key { return Array(groupCache.groups.prefix(limit)) }
        let crops = try await unmatched.recent(limit: 400).filter { $0.recipeID == recipeID }
        let groups = try await groupUnknown(crops)
        groupCache = (key, groups)
        return Array(groups.prefix(limit))
    }

    /// A stored crop's audio, for listening to before naming it.
    public func clipPCM(segmentId: String, startMediaMs: Int64, endMediaMs: Int64) async throws -> Data {
        let source = try await load(segmentId)
        return try await Task.detached(priority: .userInitiated) {
            try source.pcm(startMediaMs: startMediaMs, endMediaMs: min(endMediaMs, startMediaMs + 30_000))
        }.value
    }

    /// When a moment of a recording happened, on the wall clock.
    public nonisolated func wallMs(segmentId: String, mediaMs: Int64) -> Int64? {
        guard let meta = files.readMeta(segmentId) else { return nil }
        return meta.startWallMs + SegmentMediaClock(meta).wall(fromMedia: mediaMs)
    }

    private func groupUnknown(_ crops: [VoiceUnmatchedCrop]) async throws -> [UnknownVoiceGroup] {
        let protector = protector
        let items: [SpeakerGrouping.Item] = crops.compactMap { crop in
            guard let data = try? protector.open(crop.embeddingJSON),
                  let embedding = try? JSONDecoder().decode(SpeakerEmbedding.self, from: data) else { return nil }
            return SpeakerGrouping.Item(id: crop.id, sourceID: crop.segmentId, embedding: embedding)
        }
        let byID = Dictionary(uniqueKeysWithValues: crops.map { ($0.id, $0) })
        return await Task.detached(priority: .utility) { SpeakerGrouping.group(items) }.value
            .map { ids in UnknownVoiceGroup(crops: ids.compactMap { byID[$0] }
                .sorted { $0.speechConfidence > $1.speechConfidence }) }
    }

    /// The person said who an unnamed voice is: every crop carries their name, the clearest few
    /// teach the voice, and the group is no longer asked about. `naming` widens a crop to the
    /// range that should carry the name (the transcript paragraph it sits in): a name over part
    /// of a paragraph leaves the paragraph unnamed.
    public func nameUnknownVoice(_ group: UnknownVoiceGroup, personId: String,
                                 naming: @Sendable (VoiceUnmatchedCrop) -> Range<Int64>? = { _ in nil }) async throws -> Int {
        let corrections = SpeakerCorrectionStore(db: store.db)
        for crop in group.crops {
            let range = naming(crop) ?? crop.startMediaMs..<crop.endMediaMs
            try await corrections.set(segmentId: crop.segmentId, startMediaMs: min(range.lowerBound, crop.startMediaMs),
                                      endMediaMs: max(range.upperBound, crop.endMediaMs), personId: personId)
        }
        var learned = 0
        // One crop per recording first: different recordings are the independent evidence.
        var seen = Set<String>()
        let firsts = group.crops.filter { seen.insert($0.segmentId).inserted }
        let firstIDs = Set(firsts.map(\.id))
        let teaching = firsts + group.crops.filter { !firstIDs.contains($0.id) }
        for crop in teaching.prefix(5) {
            if let outcome = try? await enroll(personId: personId, segmentId: crop.segmentId,
                                               startMediaMs: crop.startMediaMs, endMediaMs: min(crop.endMediaMs, crop.startMediaMs + 30_000)) {
                learned += outcome.examplesAdded
            }
        }
        try await VoiceUnmatchedStore(db: store.db).remove(ids: group.crops.map(\.id))
        changed()
        return learned
    }

    /// "Not now" or "not one person": the group stops being asked about. New crops of the voice
    /// may form a new group later.
    public func dismissUnknownVoice(_ group: UnknownVoiceGroup) async throws {
        try await VoiceUnmatchedStore(db: store.db).remove(ids: group.crops.map(\.id))
        changed()
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
    public func removeExample(id: String) async throws { try await removeExamples(ids: [id]) }
    public func removeExamples(ids: [String]) async throws {
        cancelEnrollment()
        let ids = Set(ids)
        let people = Set(try await store.examples().filter { ids.contains($0.id) }.map(\.personId))
        for person in people {
            changedSegments.formUnion(try await store.automaticSegmentIds(personId: person))
        }
        try await store.removeExamples(ids: Array(ids)); changed()
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
