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
    /// When this launch last finished a stretch of audio, for Diagnostics: "checking" and
    /// "stuck" look the same from a count alone.
    public var lastWorkAtMs: Int64?
    /// Recordings whose check failed for good.
    public var failedRecordings = 0
    public init(configuration: VoiceRecognitionConfiguration, models: SpeakerModelInstallState,
                isProcessing: Bool, lastMessage: String?) {
        self.configuration = configuration; self.models = models
        self.isProcessing = isProcessing; self.lastMessage = lastMessage
    }
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
    /// Recognized through a group of voices (`VoiceClustering`), not a per-crop score.
    public static let clusterCalibrationID = "watch-voice-clusters-v1"
    private let store: VoiceIdentityStore
    private let history: VoiceHistoryPlanStore
    private let prints: VoicePrintStore
    private let speakers: VoiceSpeakerStore
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
    private var lastWorkAtMs: Int64?
    private var discoveryAtMs: Int64 = 0
    private var discovered = Set<String>()
    /// Recordings each history run has still to look at, as of its last discovery step; this
    /// launch's only, so a relaunch knows again after one pass.
    private var historyLeft: [String: Int] = [:]
    private var changedSegments = Set<String>()
    private nonisolated let enrollmentGeneration = Mutex<UInt64>(0)
    /// A recording's transcript turns on the media clock; nil when it has no transcript
    /// (not the same as no speech).
    private let transcriptTurns: @Sendable (String) -> [Range<Int64>]?
    /// The recording being worked through. Reading and hashing one is 45,000 frames, and it
    /// used to happen again for every slice.
    private var openRecording: (source: VoiceAudioSource, turns: [Range<Int64>]?)?
    private var seededDiscovery = false
    /// What the voice groups were last worked out from.
    private var clusterKey: String?
    private var settledThisLaunch = false
    private var lastAnalysisAtMs: Int64?

    public init(database: AppDatabase, files: SegmentFileReader, models: SpeakerModelStore,
                policy: SpeakerMatchPolicy = VoiceRecognitionService.initialPolicy,
                protector: any VoiceProfileProtecting = VoiceProfileCipher(),
                transcriptTurns: @escaping @Sendable (String) -> [Range<Int64>]? = { _ in nil }) {
        store = VoiceIdentityStore(db: database)
        history = VoiceHistoryPlanStore(db: database)
        prints = VoicePrintStore(db: database)
        speakers = VoiceSpeakerStore(db: database)
        self.files = files; self.models = models; self.policy = policy
        analyzer = LocalSpeakerDiarizer(embeddingModelDirectory: models.embeddingDirectory,
                                       segmentationModelDirectory: models.segmentationDirectory)
        recipeID = LocalSpeakerDiarizer.recipeID
        self.protector = protector
        self.transcriptTurns = transcriptTurns
    }

    public init(database: AppDatabase, files: SegmentFileReader, models: any VoiceModelManaging,
                analyzer: any SpeakerSpeechAnalyzing, policy: SpeakerMatchPolicy,
                recipeID: String, protector: any VoiceProfileProtecting = VoiceProfileCipher(),
                transcriptTurns: @escaping @Sendable (String) -> [Range<Int64>]? = { _ in nil }) {
        store = VoiceIdentityStore(db: database)
        history = VoiceHistoryPlanStore(db: database)
        prints = VoicePrintStore(db: database)
        speakers = VoiceSpeakerStore(db: database)
        self.files = files; self.models = models; self.analyzer = analyzer
        self.policy = policy; self.recipeID = recipeID; self.protector = protector
        self.transcriptTurns = transcriptTurns
    }

    public func status() async throws -> VoiceRecognitionStatus {
        try await reconcileProfileProtection()
        _ = await models.isInstalled()
        var status = VoiceRecognitionStatus(configuration: try await store.configuration(),
            models: await models.state(), isProcessing: processing || enrolling, lastMessage: lastMessage)
        status.pendingRecordings = try await store.pendingRecordingCount()
        status.failedRecordings = try await store.failedRecordingCount()
        status.lastWorkAtMs = lastWorkAtMs
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
    /// How many recordings a history run has yet to find and queue; nil until it has looked.
    public func historyRecordingsLeft(runID: String) -> Int? { historyLeft[runID] }

    public func setEnabled(_ enabled: Bool) async throws {
        if !enabled { cancelEnrollment() }
        try await store.setMode(enabled ? .local : .off)
        await analyzer.setEnabled(enabled)
        if !enabled { await models.cancel(); await analyzer.release() }
        discoveryAtMs = 0
        if enabled { discovered.removeAll(); seededDiscovery = false }
        openRecording = nil
        lastMessage = nil
        changed()
    }

    public func setForeground(_ value: Bool) async {
        if !value {
            cancelEnrollment()
            await analyzer.setEnabled(false)
            await releaseHeld()
        }
    }

    public func release() async {
        cancelEnrollment()
        await analyzer.setEnabled(false)
        await releaseHeld()
    }

    /// Models and the open recording stay loaded between slices while there is work: loading
    /// the models verifies 81 files and reads the recording back in. A minute with no window
    /// analysed (hot, no charger, nothing left) gives them back.
    public func releaseIfIdle(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async {
        guard !processing, !enrolling, let last = lastAnalysisAtMs, nowMs - last >= 60_000 else { return }
        await releaseHeld()
    }

    private func releaseHeld() async {
        await analyzer.release()
        openRecording = nil
        lastAnalysisAtMs = nil
    }

    /// The pipeline pass calls this; no timer or scan loop of its own. New recordings are found
    /// and queued on every call; the models run only while `mayAnalyze` holds, which is
    /// re-read between windows so unplugging stops at the next one. Recordings already analysed
    /// are named from their prints first, when they've just been heard or the voices have
    /// changed (`renamed`), also whenever `mayName` holds.
    public func pass(segmentStore: SegmentStore, maxWindows: Int = 2, mayName: Bool = false,
                     mayAnalyze: @escaping @Sendable () -> Bool) async -> (didWork: Bool, windows: Int, renamed: Int) {
        do { try await reconcileProfileProtection() }
        catch { lastMessage = error.localizedDescription; return (false, 0, 0) }
        // Voices sort themselves with or without a single name yet: that's what gets asked about.
        guard let config = try? await store.configuration(), config.mode == .local,
              await models.isInstalled(), let enabledAt = config.enabledAtMs else { return (false, 0, 0) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var queued = false
        let plans = (try? await history.plans()) ?? []
        var metas: [SegmentMeta]?
        if plans.contains(where: { $0.state == "active" && !$0.discoveryComplete }) {
            metas = await segmentStore.listSegments()
            do { queued = try await fillHistory(plans: plans, metas: metas!) }
            catch { lastMessage = error.localizedDescription; changed() }
        }
        if now - discoveryAtMs >= 30_000 {
            let currentMetas: [SegmentMeta]
            if let metas { currentMetas = metas } else { currentMetas = await segmentStore.listSegments() }
            let candidates = currentMetas.filter { !$0.isOpen && ($0.closedAtMs ?? $0.receivedAtMs) >= enabledAt }
            func key(_ meta: SegmentMeta) -> String { "\(meta.segmentId):\(meta.logBytes):\(meta.frameCount)" }
            // What's already queued or checked needs no look at its audio. `discovered` is this
            // launch's only, so every launch used to read and hash two whole recordings per
            // slice, about a thousand in all, just to learn each was already known.
            if !seededDiscovery, let covered = try? await store.coveredRecordings() {
                for meta in candidates where covered[meta.segmentId] == meta.frameCount * Int64(meta.frameSamples) / 16 {
                    discovered.insert(key(meta))
                }
                seededDiscovery = true
            }
            var attempted = 0
            for meta in candidates {
                let key = key(meta)
                guard !discovered.contains(key) else { continue }
                do { try await enqueueSegment(segmentId: meta.segmentId); queued = true }
                catch { lastMessage = error.localizedDescription }
                discovered.insert(key); attempted += 1
                if attempted >= 2 { break }
            }
            // A large catch-up is still bounded at two new segment jobs per pass.
            if attempted < 2 { discoveryAtMs = now }
        }
        // Naming from saved prints is comparisons, not models: on screen it needn't wait for a charger.
        // New work may already be known to need no models. So may what a launch inherits.
        if queued || !settledThisLaunch {
            settledThisLaunch = true
            if let settled = try? await store.settleCheckedRecordings(), settled > 0 { queued = true; changed() }
        }
        guard mayAnalyze() || mayName else { return (queued, 0, 0) }
        let renamed = await renameFromPrints()
        guard mayAnalyze() else { return (queued || renamed > 0, 0, renamed) }
        let slice = await analyzePending(maxWindows: maxWindows, mayRun: mayAnalyze)
        return (slice.didWork || queued || renamed > 0, slice.windows, renamed)
    }

    /// Brings names up to date from saved prints, without the models. A recording just heard is
    /// sorted into its speakers; every speaker across the archive is sorted into voices when
    /// anything they depend on changed; and each recording's turns take the names their speakers
    /// now go by. At most about `maxPrints` per call; returns how many recordings were read.
    @discardableResult func renameFromPrints(maxPrints: Int = 2_000) async -> Int {
        do {
            let (config, examples) = try await store.corpus()
            guard config.mode == .local else { return 0 }
            let sources = try await prints.stale(corpusRevision: config.corpusRevision,
                                                 maxPrints: maxPrints, maxSources: 64)
            let protector = protector
            if !sources.isEmpty {
                let known = try await speakers.cropCounts(segmentIds: sources.map(\.segmentId))
                let toSort = sources.filter { known[$0.segmentId] != $0.prints.count }
                if !toSort.isEmpty {
                    // Thousands of comparisons: off this actor, so status reads don't wait on them.
                    let sorted = try await Task.detached(priority: .utility) {
                        try toSort.map { source in
                            (segmentId: source.segmentId, drafts: try Self.speakerDrafts(source, protector: protector))
                        }
                    }.value
                    try await speakers.replaceSpeakers(sorted)
                }
            }
            try await sortVoicesIfNeeded(examples: examples)
            guard !sources.isEmpty else { return 0 }
            let inputs = try await speakers.namingInputs(segmentIds: sources.map(\.segmentId))
            let transcriptTurns = transcriptTurns
            let updates = await Task.detached(priority: .utility) {
                zip(sources, inputs).map { source, recording -> VoiceNamingUpdate in
                    let turns = transcriptTurns(source.segmentId)
                    return VoiceNamingUpdate(source: source, names: Self.names(recording, turns: turns,
                        sourceRevision: source.sourceRevision, recipeID: source.recipeID,
                        runID: source.prints.first?.runID ?? ""),
                        wholeRecording: true, speechMs: Self.speechMs(recording, turns: turns))
                }
            }.value
            let renamed = try await prints.commitNames(updates, corpusRevision: config.corpusRevision,
                                                       configGeneration: config.generation)
            changedSegments.formUnion(renamed)
            if !renamed.isEmpty { changed() }
            return sources.count
        } catch {
            lastMessage = error.localizedDescription
            return 0
        }
    }

    /// The speakers of one recording from its saved prints.
    static func speakerDrafts(_ source: VoicePrintSource, protector: any VoiceProfileProtecting) throws -> [VoiceSpeakerDraft] {
        // A print that no longer opens is left out rather than holding up the rest.
        let opened = source.prints.sorted { $0.startMediaMs < $1.startMediaMs }.compactMap { print in
            (try? open(print, protector: protector)).map { (record: print, embedding: $0) }
        }
        let crops = opened.map {
            SpeakerDiarization.Crop(startMs: $0.record.startMediaMs, endMs: $0.record.endMediaMs, embedding: $0.embedding)
        }
        let assigned = SpeakerDiarization.speakers(crops)
        let encoder = JSONEncoder()
        return try Set(assigned).sorted().map { speaker in
            let members = opened.indices.filter { assigned[$0] == speaker }.map { opened[$0] }
            let spans = members.map {
                VoiceSpeakerCrop(startMs: $0.record.startMediaMs, endMs: $0.record.endMediaMs,
                                 confidencePercent: Int(($0.record.speechConfidence * 100).rounded()))
            }
            guard members.count >= SpeakerDiarization.minimumCrops else {
                return VoiceSpeakerDraft(crops: spans, sealedVoice: nil, recipeJSON: nil)
            }
            let saved = try VoicePrintCodec.save(try SpeakerEmbedding.pooled(members.map(\.embedding)))
            return VoiceSpeakerDraft(crops: spans, sealedVoice: try protector.seal(saved.bytes),
                                     recipeJSON: try encoder.encode(saved.embedding.recipe))
        }
    }

    /// Sorts every speaker into voices again when anything that decides it changed: new speakers,
    /// or something a person said. Recordings whose names this changes are named on the next pass.
    private func sortVoicesIfNeeded(examples: [VoiceConfirmedExample]) async throws {
        let key = try await speakers.clusterKey()
        guard key != clusterKey else { return }
        let inputs = try await speakers.clusterInputs(minimumCrops: SpeakerDiarization.minimumCrops)
        let protector = protector
        // Samples recorded for the purpose belong to no recording's speakers: each is a labelled
        // voice of its own, and they're how a first group gets its name.
        let inRecordings = Set(inputs.map(\.segmentId))
        let assignments = try await Task.detached(priority: .utility) { () -> [VoiceSpeakerAssignment] in
            var ids: [Int64?] = []
            var items: [VoiceClustering.Item] = []
            for input in inputs {
                guard let opened = try? VoicePrintCodec.open(protector.open(input.sealedVoice),
                    recipe: JSONDecoder().decode(SpeakerEmbeddingRecipe.self, from: input.recipeJSON)) else { continue }
                ids.append(input.id)
                items.append(VoiceClustering.Item(source: input.segmentId, voice: opened.values, cropCount: input.cropCount,
                    person: input.person, rejected: input.rejected, ignored: input.ignored))
            }
            let samples = Dictionary(grouping: examples.filter { !inRecordings.contains($0.segmentId) }, by: \.confirmationID)
            for (confirmation, crops) in samples.sorted(by: { $0.key < $1.key }) {
                let voices = crops.compactMap { try? StoredEnrollmentEmbedding.decode(protector.open($0.embeddingJSON)).primary }
                guard let first = crops.first, !voices.isEmpty, let pooled = try? SpeakerEmbedding.pooled(voices),
                      items.first.map({ $0.voice.count == pooled.values.count }) ?? true else { continue }
                ids.append(nil)
                items.append(VoiceClustering.Item(source: confirmation, voice: pooled.values, cropCount: crops.count, person: first.personId))
            }
            return VoiceClustering.cluster(items).flatMap { group -> [VoiceSpeakerAssignment] in
                let speakerIds = group.members.compactMap { ids[$0] }
                guard let clusterId = speakerIds.min() else { return [] }
                return group.members.indices.compactMap { index in
                    guard let id = ids[group.members[index]] else { return nil }
                    return VoiceSpeakerAssignment(speakerId: id, clusterId: clusterId, personId: group.person,
                        score: group.similarity[index], suggestedPersonId: group.suggestion?.person,
                        suggestedScore: group.suggestion?.score, ignored: group.ignored)
                }
            }
        }.value
        let changedRecordings = try await speakers.applyClusters(assignments)
        clusterKey = key
        if changedRecordings > 0 { changed() }
    }

    /// Each turn takes its speaker's name; a name a person hasn't confirmed but might, as a
    /// suggestion. Turns a person decided about stay theirs. With no transcript, the crops
    /// themselves are all there is to name.
    static func names(_ recording: VoiceNamingRecording, turns: [Range<Int64>]?, sourceRevision: String,
                      recipeID: String, runID: String) -> [VoiceAutomaticAttribution] {
        var spans: [SpeakerDiarization.Span] = []
        for (index, speaker) in recording.speakers.enumerated() {
            spans += speaker.crops.map { .init(startMs: $0.startMs, endMs: $0.endMs, speaker: index) }
        }
        let stretches = turns ?? spans.map { $0.startMs..<$0.endMs }
        var out: [VoiceAutomaticAttribution] = []
        var mergeable = false
        for stretch in stretches.sorted(by: { $0.lowerBound < $1.lowerBound }) where !stretch.isEmpty {
            guard !recording.blocked.contains(where: { $0.overlaps(stretch) }),
                  let index = SpeakerDiarization.speaker(of: stretch, spans: spans) else { mergeable = false; continue }
            let speaker = recording.speakers[index]
            guard let person = speaker.personId ?? speaker.suggestedPersonId else { mergeable = false; continue }
            let disposition: VoiceAttributionDisposition = speaker.personId != nil ? .recognized : .suggestion
            if mergeable, let last = out.last, last.personId == person, last.disposition == disposition,
               stretch.lowerBound - last.endMediaMs <= 1_000 {
                out[out.count - 1] = VoiceAutomaticAttribution(personId: person, segmentId: recording.segmentId,
                    startMediaMs: last.startMediaMs, endMediaMs: max(last.endMediaMs, stretch.upperBound),
                    sourceRevision: sourceRevision, recipeID: recipeID, score: last.score, margin: nil,
                    calibrationID: clusterCalibrationID, runID: runID, disposition: disposition)
            } else {
                out.append(VoiceAutomaticAttribution(personId: person, segmentId: recording.segmentId,
                    startMediaMs: stretch.lowerBound, endMediaMs: stretch.upperBound, sourceRevision: sourceRevision,
                    recipeID: recipeID, score: min(1, max(-1, speaker.score ?? 0)), margin: nil,
                    calibrationID: clusterCalibrationID, runID: runID, disposition: disposition))
            }
            mergeable = true
        }
        return out
    }

    static func speechMs(_ recording: VoiceNamingRecording, turns: [Range<Int64>]?) -> Int64 {
        if let turns { return turns.reduce(0) { $0 + max(0, $1.upperBound - $1.lowerBound) } }
        return recording.speakers.reduce(0) { $0 + $1.crops.reduce(0) { $0 + $1.endMs - $1.startMs } }
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
        guard config.mode == .local, await models.isInstalled() else { return }
        let source = try await load(segmentId)
        guard !source.meta.isOpen, source.endMediaMs >= 2_000 else { return }
        _ = try await store.prepareSource(segmentId: segmentId, revision: source.revision)
        try await store.enqueueJob(runID: "recent:\(segmentId):\(config.generation):\(source.revision)", segmentId: segmentId,
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
        var advanced = false
        // A recording seen before needs no look at its audio: its sidecar says how long it is, and
        // a changed one is caught before analysis. Reading and hashing each of 3,400 recordings
        // kept "Counting recordings…" up for hours, working on whatever had been counted so far.
        var inspected = 0, read = 0
        let known = try await store.readySources()
        let ordered = metas.sorted { ($0.startWallMs, $0.segmentId) < ($1.startWallMs, $1.segmentId) }
        for plan in plans.reversed() where plan.state == "active" && !plan.discoveryComplete {
            let candidates = ordered.filter {
                !$0.isOpen && $0.startWallMs < plan.toMs
                    && $0.startWallMs + SegmentMediaClock($0).wallSpanMs > plan.fromMs
                    && ($0.startWallMs > plan.cursorStartMs
                        || ($0.startWallMs == plan.cursorStartMs && $0.segmentId > plan.cursorSegmentId))
            }
            historyLeft[plan.runID] = candidates.count
            if candidates.isEmpty { try await history.finishDiscovery(runID: plan.runID); advanced = true; continue }
            for meta in candidates {
                try Task.checkCancellation()
                guard inspected < 256, read < 2 else { if advanced { changed() }; return advanced }
                historyLeft[plan.runID] = max(0, (historyLeft[plan.runID] ?? 1) - 1)
                var queued = false
                do {
                    let endMediaMs: Int64
                    if known.contains(meta.segmentId), meta.frameCount > 0 {
                        endMediaMs = meta.frameCount * Int64(meta.frameSamples) / 16
                    } else {
                        read += 1
                        let source = try await load(meta.segmentId)
                        _ = try await store.prepareSource(segmentId: meta.segmentId, revision: source.revision)
                        endMediaMs = source.endMediaMs
                    }
                    let clock = SegmentMediaClock(meta)
                    let start = plan.fromMs <= meta.startWallMs ? 0
                        : clock.media(fromWall: plan.fromMs - meta.startWallMs)
                    let end = plan.toMs >= meta.startWallMs + clock.wallSpanMs ? endMediaMs
                        : min(endMediaMs, clock.media(fromWall: plan.toMs - meta.startWallMs))
                    if end - start >= 2_000 {
                        try await store.enqueueJob(runID: plan.runID, segmentId: meta.segmentId,
                            startMediaMs: start, endMediaMs: end, recipeID: recipeID, explicitRerun: true)
                        try await store.foldRecentJobs(segmentId: meta.segmentId, startMediaMs: start, endMediaMs: end)
                        changedSegments.insert(meta.segmentId)
                        queued = true
                    }
                } catch VoiceEnrollmentError.audioUnavailable { /* unavailable audio remains unavailable, no download */ }
                catch VoiceIdentityError.sourceDeleted { /* source deleted after scope was chosen */ }
                catch VoiceIdentityError.sourceInvalidated { /* source changed or was redacted; do not revive stale evidence */ }
                catch VoiceEnrollmentError.unsupportedAudio {
                    lastMessage = "Some recordings use an unsupported audio format and were skipped."
                }
                try await history.advance(runID: plan.runID, startMs: meta.startWallMs,
                    segmentId: meta.segmentId, queued: queued, complete: meta.segmentId == candidates.last?.segmentId)
                inspected += 1; advanced = true
            }
        }
        if advanced { changed() }
        return advanced
    }

    /// Each call performs at most `maxWindows` ten-second windows. False means no window was
    /// processed. Native handles stay loaded while there is more to do (`releaseIfIdle`).
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
        var steps = 0
        var queueEmpty = false
        do {
            if !resumed { try await store.resumeInterruptedJobs(); resumed = true }
            await analyzer.setEnabled(true)
            // What needs no model time (audio already analysed, stretches with no speech) doesn't
            // count against the windows.
            while windows < maxWindows, steps < 64 {
                steps += 1
                try Task.checkCancellation()
                guard mayRun() else { break }
                guard let job = try await store.claimNextJob() else { queueEmpty = true; break }
                do {
                    guard let context = try await store.workContext(segmentId: job.segmentId),
                          context.token.sameWork(as: job.token) else { throw VoiceEnrollmentError.changedDuringProcessing }
                    let analyzed = try await prints.analyzed(segmentId: job.segmentId, recipeID: job.recipeID, token: job.token)
                    if let covered = analyzed.first(where: { $0.contains(job.cursorMediaMs) }) {
                        // Its prints are named for this run by the next `renameFromPrints`.
                        try await store.adoptAnalyzed(id: job.id, expectedCursorMediaMs: job.cursorMediaMs,
                                                      nextCursorMediaMs: min(covered.upperBound, job.endMediaMs))
                        didWork = true; changed()
                        continue
                    }
                    // Up to the next stretch already analysed, if there is one.
                    let limit = analyzed.first(where: { $0.lowerBound > job.cursorMediaMs })
                        .map { min($0.lowerBound, job.endMediaMs) } ?? job.endMediaMs
                    // The transcriber found no words anywhere in it: no name could land on anything.
                    if try await store.transcribedAsNoSpeech(segmentId: job.segmentId) {
                        try await store.skipJob(id: job.id, expectedCursorMediaMs: job.cursorMediaMs, nextCursorMediaMs: limit)
                        lastWorkAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                        didWork = true; changed()
                        continue
                    }
                    let recording = try await open(job.segmentId)
                    guard recording.source.revision == job.token.sourceRevision else { throw VoiceEnrollmentError.changedDuringProcessing }
                    let source = recording.source
                    let range = recording.turns.map { Self.speech($0) }.map {
                        source.nextRange(afterMediaMs: job.cursorMediaMs, throughMediaMs: limit, speech: $0)
                    } ?? source.nextRange(afterMediaMs: job.cursorMediaMs, throughMediaMs: limit)
                    guard let range else {
                        try await store.skipJob(id: job.id, expectedCursorMediaMs: job.cursorMediaMs, nextCursorMediaMs: limit)
                        lastWorkAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                        didWork = true; changed()
                        continue
                    }
                    let pcm = try await Task.detached(priority: .utility) {
                        try source.pcm(startMediaMs: range.lowerBound, endMediaMs: range.upperBound)
                    }.value
                    let analysis = try await analyzer.analyze(SpeakerAnalysisAudio(
                        pcm16LE: pcm, sourceID: job.segmentId, sourceRevision: source.revision,
                        sessionID: job.segmentId, sourceStartSample: Int(range.lowerBound) * 16))
                    let turns = try Self.prints(analysis, window: range, runID: job.runID, protector: protector)
                    windows += 1
                    lastAnalysisAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    try Task.checkCancellation()
                    // Names wait until the whole recording has been heard (`speakerNames`).
                    try await store.advanceJob(id: job.id, expectedCursorMediaMs: job.cursorMediaMs,
                        nextCursorMediaMs: range.upperBound, attributions: [], window: range,
                        prints: turns.map(\.record), matchedCorpus: context.configuration.corpusRevision,
                        nameWhenDone: true)
                    lastWorkAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    didWork = true; changed()
                } catch VoiceEnrollmentError.audioUnavailable {
                    // Moved off the phone since it was queued (the cold tier), and voice work never
                    // downloads: nothing to check here, and no failure to report.
                    try? await store.skipJob(id: job.id, expectedCursorMediaMs: job.cursorMediaMs, nextCursorMediaMs: job.endMediaMs)
                    openRecording = nil
                    didWork = true; changed()
                } catch {
                    if !mayRun() || error is CancellationError || (error as? SpeakerRecognitionError) == .disabled {
                        try? await store.releaseJob(id: job.id)
                        break
                    }
                    try? await store.failJob(id: job.id, error: error.localizedDescription, retryable: false)
                    openRecording = nil
                    lastMessage = error.localizedDescription; changed()
                }
            }
        } catch {
            if !(error is CancellationError) { lastMessage = error.localizedDescription }
        }
        if queueEmpty || !mayRun() { await releaseHeld() }
        processing = false; changed()
        return (didWork, windows)
    }

    /// The recording this job is over, kept between slices.
    private func open(_ segmentId: String) async throws -> (source: VoiceAudioSource, turns: [Range<Int64>]?) {
        if let openRecording, openRecording.source.meta.segmentId == segmentId { return openRecording }
        let source = try await load(segmentId)
        let transcriptTurns = transcriptTurns
        let turns = await Task.detached(priority: .utility) { transcriptTurns(segmentId) }.value
        openRecording = (source, turns)
        return (source, turns)
    }

    /// Where speech is: the transcript's turns, joined across pauses too short to matter.
    static func speech(_ turns: [Range<Int64>]) -> [Range<Int64>] {
        var merged: [Range<Int64>] = []
        for turn in turns.sorted(by: { $0.lowerBound < $1.lowerBound }) where !turn.isEmpty {
            if let last = merged.last, turn.lowerBound <= last.upperBound + 1_000 {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, turn.upperBound)
            } else { merged.append(turn) }
        }
        return merged
    }

    /// The confirmed voices of one recipe, opened once for every turn they are matched against.
    static func roster(examples: [VoiceConfirmedExample], recipeID: String, policy: SpeakerMatchPolicy,
                       protector: any VoiceProfileProtecting) throws -> SpeakerMatchRoster {
        try SpeakerMatchRoster(examples: examples.compactMap { example -> ConfirmedSpeakerExample? in
            guard example.recipeID == recipeID, let person = UUID(uuidString: example.personId) else { return nil }
            let embedding = try StoredEnrollmentEmbedding.decode(protector.open(example.embeddingJSON))
            return ConfirmedSpeakerExample(id: example.id, personID: person,
                confirmationID: example.confirmationID, sessionID: example.sessionID,
                embedding: embedding.primary, embeddingVariants: embedding.variants)
        }, policy: policy)
    }

    /// The turns of a window that can be named, each with the print saved for it. Names always
    /// come from the saved print, so naming it again later decides exactly as this did.
    static func prints(_ analysis: SpeakerAnalysis, window: Range<Int64>, runID: String,
                       protector: any VoiceProfileProtecting) throws -> [(record: VoiceTurnPrint, embedding: SpeakerEmbedding)] {
        let encoder = JSONEncoder()
        return try analysis.turns.compactMap { turn in
            guard !turn.overlap, turn.speechConfidence >= 0.7, let embedding = turn.embedding,
                  turn.startSample >= Int(window.lowerBound) * 16, turn.endSample <= Int(window.upperBound) * 16,
                  turn.endSample / 16 > turn.startSample / 16 else { return nil }
            let print = try VoicePrintCodec.save(embedding)
            return (VoiceTurnPrint(startMediaMs: Int64(turn.startSample / 16), endMediaMs: Int64(turn.endSample / 16),
                speechConfidence: turn.speechConfidence, runID: runID, recipeJSON: try encoder.encode(embedding.recipe),
                sealedEmbedding: try protector.seal(print.bytes)), print.embedding)
        }
    }

    static func open(_ print: VoiceTurnPrint, protector: any VoiceProfileProtecting) throws -> SpeakerEmbedding {
        try VoicePrintCodec.open(protector.open(print.sealedEmbedding),
                                 recipe: JSONDecoder().decode(SpeakerEmbeddingRecipe.self, from: print.recipeJSON))
    }

    /// A voice heard across recordings that nobody has named, with a clip from each.
    public struct UnknownVoiceGroup: Equatable, Sendable {
        public let clusterId: Int64
        public let crops: [VoiceUnmatchedCrop]
        public var speechMs: Int64 = 0
        public var suggestedPersonId: String?
        public var suggestedScore: Double?
        public var recordingCount: Int { Set(crops.map(\.segmentId)).count }
        public init(clusterId: Int64, crops: [VoiceUnmatchedCrop], speechMs: Int64 = 0,
                    suggestedPersonId: String? = nil, suggestedScore: Double? = nil) {
            self.clusterId = clusterId; self.crops = crops; self.speechMs = speechMs
            self.suggestedPersonId = suggestedPersonId; self.suggestedScore = suggestedScore
        }
        /// Only the clips from these recordings: the person said the rest are someone else.
        public func limited(to recordings: Set<String>) -> UnknownVoiceGroup {
            UnknownVoiceGroup(clusterId: clusterId, crops: crops.filter { recordings.contains($0.segmentId) },
                              speechMs: speechMs, suggestedPersonId: suggestedPersonId, suggestedScore: suggestedScore)
        }
        public var id: String { "voice-\(clusterId)" }
    }

    /// Voices nobody has named, most heard first. Those that might be someone are among them.
    public func unknownVoiceGroups(limit: Int = 6) async throws -> [UnknownVoiceGroup] {
        try await speakers.unnamedClusters(limit: limit).map { cluster in
            UnknownVoiceGroup(clusterId: cluster.id, crops: cluster.clips.map { clip in
                VoiceUnmatchedCrop(id: String(clip.speakerId), segmentId: clip.segmentId, startMediaMs: clip.startMediaMs,
                    endMediaMs: clip.endMediaMs, sourceRevision: "", recipeID: recipeID, embeddingJSON: Data(),
                    speechConfidence: Double(clip.confidencePercent) / 100, createdAtMs: clip.heardAtMs)
            }, speechMs: cluster.speechMs, suggestedPersonId: cluster.suggestedPersonId, suggestedScore: cluster.suggestedScore)
        }
    }

    /// How much of what's been said has a name, and whose.
    public func coverage() async throws -> VoiceCoverage { try await speakers.coverage() }

    /// A stored crop's audio, for listening to before naming it.
    public func clipPCM(segmentId: String, startMediaMs: Int64, endMediaMs: Int64) async throws -> Data {
        let source = try await load(segmentId)
        // Within the clip's own continuous run: a sample's crops can sit either side of a gap.
        let range = source.contextRange(startMediaMs: startMediaMs, endMediaMs: endMediaMs, paddingMs: 0)
        return try await Task.detached(priority: .userInitiated) {
            try source.pcm(startMediaMs: range.lowerBound, endMediaMs: range.upperBound)
        }.value
    }

    /// The clip with the audio around it, to tell whose voice a short clip is.
    public func clipContextPCM(segmentId: String, startMediaMs: Int64, endMediaMs: Int64,
                               paddingMs: Int64 = 6_000) async throws -> Data {
        let source = try await load(segmentId)
        let range = source.contextRange(startMediaMs: startMediaMs, endMediaMs: endMediaMs, paddingMs: paddingMs)
        return try await Task.detached(priority: .userInitiated) {
            try source.pcm(startMediaMs: range.lowerBound, endMediaMs: range.upperBound)
        }.value
    }

    /// When a moment of a recording happened, on the wall clock.
    public nonisolated func wallMs(segmentId: String, mediaMs: Int64) -> Int64? {
        guard let meta = files.readMeta(segmentId) else { return nil }
        return meta.startWallMs + SegmentMediaClock(meta).wall(fromMedia: mediaMs)
    }

    /// The person said who a voice is: it carries their name wherever it's heard, now and from
    /// here on. Clips the person left out aren't them. The clearest few are kept as samples.
    public func nameUnknownVoice(_ group: UnknownVoiceGroup, personId: String) async throws -> Int {
        let chosen = group.crops.compactMap { Int64($0.id) }
        let everyone = try await speakers.speakers(inCluster: group.clusterId)
        try await speakers.decide(speakers: chosen, kind: .confirmed, personId: personId)
        try await speakers.decide(speakers: everyone.filter { !chosen.contains($0) }, kind: .rejected, personId: personId)
        var learned = 0
        // One clip per recording: different recordings are the independent evidence.
        var seen = Set<String>()
        for crop in group.crops.filter({ seen.insert($0.segmentId).inserted }).prefix(5) {
            if let outcome = try? await enroll(personId: personId, segmentId: crop.segmentId, startMediaMs: crop.startMediaMs,
                                               endMediaMs: min(crop.endMediaMs, crop.startMediaMs + 30_000)) {
                learned += outcome.examplesAdded
            }
        }
        changed()
        return learned
    }

    /// "It's someone else": this voice stays unnamed, and isn't suggested as them again.
    public func rejectSuggestion(_ group: UnknownVoiceGroup, personId: String) async throws {
        try await speakers.decide(speakers: try await speakers.speakers(inCluster: group.clusterId),
                                  kind: .rejected, personId: personId)
        changed()
    }

    /// Stop asking about this voice, here and wherever else it's heard.
    public func dismissUnknownVoice(_ group: UnknownVoiceGroup) async throws {
        try await speakers.decide(speakers: try await speakers.speakers(inCluster: group.clusterId), kind: .ignored, personId: nil)
        changed()
    }

    /// Leave this one recording's speaker out; the voice is still asked about elsewhere.
    public func ignoreUnknownClip(segmentId: String, startMediaMs: Int64, endMediaMs: Int64) async throws {
        try await speakers.decide(speakers: try await speakers.speakers(segmentId: segmentId, overlapping: startMediaMs..<endMediaMs),
                                  kind: .excluded, personId: nil)
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
        try await store.forgetProfile(personId: personId)
        try await speakers.forget(personId: personId)
        changed()
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
