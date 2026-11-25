import AppDB
import AudioCodec
import Foundation
import SegmentStore
import Transcription

// Has the cloud hear what this device transcribed while the cloud account was refusing work.
//
// WHY THIS EXISTS (2026-11-25)
//
// Soniox ran out of funds on 2026-11-22 and was refilled on 2026-11-25. The account hold lifted by
// itself and new recordings went to Soniox at once, but the 180 the phone had settled meanwhile
// stayed as they were for good: 28 hours of audio, of which Apple Speech hears about a quarter of
// the words on the watch's recordings, and 85 of them settled as "no speech". An outage the person
// ended is not a reason to keep its transcripts.
//
// HOW
//
//  - A stand-in is a settled task marked `standInFor`. The mark is the whole work list: it survives
//    relaunches, and settling a hearing clears it, so nothing is heard twice.
//  - Nothing about the segment moves while it is being heard: the task and the sidecar stay settled
//    and the old transcript stays on screen. (Putting it back to Pending would take the
//    conversation out of History, merge it with its neighbours, and stop its AI work until the
//    upload landed.) Only the cloud is asked, never the on-device engine again, and a refusal
//    leaves the stand-in as it was.
//  - Results wait on disk and are applied a DAY at a time, newest day first, so the conversations
//    that share recordings are cut, titled, read for follow-ups and recapped once, not once per
//    recording.
//  - It runs when the queue has nothing else to do, inside the drain, and so under the drain's own
//    rules: on screen, or on a charger, and never when the phone is hot. It sends the watch's own
//    Speex frames (about 1 MB per 15 minutes), only on a network "Upload Audio" allows.
//  - It costs what the hearing costs, so each recording is sent at most `maxAttempts` times, counted
//    in the database before it is sent. A send that failed because of the account or the network
//    is given back.
public actor StandInRehearing {
    public typealias Send =
        @Sendable (_ segmentId: String, _ provider: CloudProvider) async throws -> TranscriptionResult

    public static let maxAttempts = 3
    static let concurrentSends = 4
    static let networkPauseMs: Int64 = 10 * 60_000

    private let queue: TranscriptionQueue
    private let transcripts: FileTranscriptStore
    private let store: SegmentStore
    private let database: AppDatabase
    private let cloud: SelectableCloudTranscriptionProvider
    private let settings: any RuntimeSettings
    private let clock: RuntimeClock
    private let log: RuntimeLog
    private let send: Send

    private var pausedUntilMs: Int64 = 0
    /// The settling each waiting result was made for, by segment; nil for "looked, none waiting".
    /// The files are whole transcripts, and a step asks about every stand-in.
    private var waiting: [String: Int64?] = [:]
    /// Applied since the runtime last asked (`takeReplaced`).
    private var replaced: Set<String> = []

    public init(
        queue: TranscriptionQueue, transcripts: FileTranscriptStore, store: SegmentStore,
        database: AppDatabase, cloud: SelectableCloudTranscriptionProvider,
        settings: any RuntimeSettings, clock: RuntimeClock, log: RuntimeLog = .silent,
        send: @escaping Send
    ) {
        self.queue = queue
        self.transcripts = transcripts
        self.store = store
        self.database = database
        self.cloud = cloud
        self.settings = settings
        self.clock = clock
        self.log = log
        self.send = send
    }

    /// Segments whose transcripts were replaced since the last call, for what keeps them in memory.
    public func takeReplaced() -> [String] {
        defer { replaced = [] }
        return Array(replaced)
    }

    /// Recordings still to be heard, or heard and waiting for the rest of their day. Not the ones
    /// that cannot be: their audio is gone or away, or the cloud could not do them.
    public func owedCount() async -> Int {
        guard settings.cloudIsPrimaryTranscription, let tasks = try? queue.standIns() else { return 0 }
        return await load(tasks).filter { $0.isDue || $0.isWaiting }.count
    }

    private struct Item {
        var task: TranscriptionTask
        var meta: SegmentMeta
        /// Heard, and waiting to be applied.
        var isWaiting: Bool
        var isDue: Bool
    }

    /// One bounded step: send up to `concurrentSends` recordings of the newest day that still has
    /// any, or apply that day when all of it has been heard. Returns whether it did something.
    public func step() async throws -> Bool {
        let tasks = try queue.standIns()
        // The ordinary case, and the whole cost of it: one indexed query.
        guard !tasks.isEmpty else { return false }
        let provider = settings.cloudTranscriptionProvider
        let held = cloud.hold?.active(for: provider) != nil
        let wanted = settings.cloudIsPrimaryTranscription && !held
        let items = await load(tasks)
        guard wanted else {
            // No more will be heard for now, so what was is used.
            return try await apply(items.filter(\.isWaiting))
        }
        let newestFirst = Dictionary(grouping: items) { Self.day(of: $0.meta) }
            .sorted { $0.key > $1.key }
        for (_, day) in newestFirst {
            let due = day.filter(\.isDue)
            guard !due.isEmpty else {
                if try await apply(day.filter(\.isWaiting)) { return true }
                continue
            }
            guard clock.nowMs >= pausedUntilMs, await cloud.isAvailable() else { return false }
            let batch = due.sorted { $0.meta.startWallMs > $1.meta.startWallMs }
                .prefix(Self.concurrentSends)
            let heard = try await hear(Array(batch), provider: provider)
            // The last of its day: applied in the same step rather than at the next pass.
            if heard, due.count == batch.count {
                let now = await load(try queue.standIns())
                let same = now.filter { Self.day(of: $0.meta) == Self.day(of: batch[0].meta) }
                if same.allSatisfy({ !$0.isDue }) {
                    _ = try await apply(same.filter(\.isWaiting))
                }
            }
            return heard
        }
        return false
    }

    private func load(_ tasks: [TranscriptionTask]) async -> [Item] {
        var items: [Item] = []
        for task in tasks {
            // Audio that is gone, still open, or away in iCloud cannot be sent. A stand-in whose
            // audio comes back is picked up then.
            guard let meta = await store.readMeta(task.segmentId), !meta.isOpen,
                meta.frameCount > 0
            else { continue }
            let isWaiting = waitingSince(task.segmentId) == task.updatedAtMs
            items.append(
                Item(
                    task: task, meta: meta, isWaiting: isWaiting,
                    isDue: !isWaiting && meta.coldStorage == nil
                        && (task.rehearAttempts ?? 0) < Self.maxAttempts))
        }
        return items
    }

    private func waitingSince(_ segmentId: String) -> Int64? {
        if let known = waiting[segmentId] { return known }
        let found = transcripts.loadReheard(segmentId)?.settledAtMs
        waiting[segmentId] = .some(found)
        return found
    }

    private func keep(_ task: TranscriptionTask, transcript: SegmentTranscript?, noSpeech: String?)
        throws
    {
        try transcripts.saveReheard(
            task.segmentId,
            .init(settledAtMs: task.updatedAtMs, transcript: transcript, noSpeech: noSpeech))
        waiting[task.segmentId] = nil
    }

    private static func day(of meta: SegmentMeta) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = meta.recordedTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let parts = calendar.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: Double(meta.startWallMs) / 1000))
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Hearing

    private enum Heard: Sendable {
        case result(TranscriptionResult)
        case noSpeech(String)
        case failed(String)
        case cancelled
    }

    /// Returns whether any recording moved: heard, or used up an attempt.
    private func hear(_ batch: [Item], provider: CloudProvider) async throws -> Bool {
        let send = self.send
        for item in batch { try queue.addRehearAttempt(item.task.segmentId, by: 1) }
        let outcomes = await withTaskGroup(of: (Int, Heard).self) { group in
            for (index, item) in batch.enumerated() {
                let id = item.task.segmentId
                group.addTask {
                    do {
                        let result = try await send(id, provider)
                        return (index, .result(result))
                    } catch is CancellationError {
                        return (index, .cancelled)
                    } catch let error as URLError where error.code == .cancelled {
                        return (index, .cancelled)
                    } catch TranscriptionError.noSpeechDetected(let reason) {
                        return (index, .noSpeech(reason))
                    } catch {
                        return (index, .failed(storedFailureMessage(error)))
                    }
                }
            }
            var all: [(Int, Heard)] = []
            for await outcome in group { all.append(outcome) }
            return all
        }

        // Never lifts a hold: it only runs when there is none, and one of these may have just been
        // refused while another, sent a moment earlier, was taken.
        var moved = false
        for (index, heard) in outcomes {
            let task = batch[index].task
            switch heard {
            case .result(let result):
                let transcript = SegmentTranscript(
                    segmentId: task.segmentId, text: result.text,
                    modeUsed: settings.transcriptionMode, providerId: result.providerId,
                    modelUsed: result.modelUsed, createdAtMs: clock.nowMs,
                    segments: result.segments, words: result.words)
                try keep(task, transcript: transcript, noSpeech: nil)
                moved = true
            case .noSpeech(let reason):
                try keep(task, transcript: nil, noSpeech: "\(provider.rawValue): \(reason)")
                moved = true
            case .cancelled:
                try queue.addRehearAttempt(task.segmentId, by: -1)
            case .failed(let message):
                cloud.noteFailureMessage(message, provider: provider)
                let kind = TranscriptionFailureKind.classify(message)
                let blameless =
                    CloudAccountHold.holdingKinds.contains(kind) || kind == .noConnection
                    || kind == .rateLimited || kind == .notConfigured
                if blameless {
                    try queue.addRehearAttempt(task.segmentId, by: -1)
                    pausedUntilMs = clock.nowMs + Self.networkPauseMs
                } else {
                    moved = true
                }
                log.write("rehearing \(task.segmentId) failed: \(message.prefix(200))")
            }
        }
        try Task.checkCancellation()
        return moved
    }

    // MARK: Applying

    /// Replaces the stand-ins' transcripts with what the cloud heard. Re-run from the top by the
    /// next step if the process dies part-way: the mark is cleared last.
    private func apply(_ items: [Item]) async throws -> Bool {
        guard !items.isEmpty else { return false }
        var settled: [ReheardTask] = []
        var changed: [String] = []
        for item in items {
            let id = item.task.segmentId
            guard let reheard = transcripts.loadReheard(id),
                reheard.settledAtMs == item.task.updatedAtMs
            else {
                // Part of it was deleted since: it is heard again from what is left.
                waiting[id] = nil
                continue
            }
            let outcome: ReheardTask.Outcome
            if let transcript = reheard.transcript, !transcript.text.isEmpty {
                // Names given to the old transcript's speaker labels move onto the audio first: the
                // new one's "Speaker 1" is somebody else.
                let names = try await LegacySpeakerMigration.anchorBeforeReprocessing(
                    segmentId: id, transcript: transcripts.loadWithoutWords(id),
                    database: database, nowMs: clock.nowMs)
                if names.unanchoredAssignments > 0 {
                    log.write(
                        "rehearing: \(names.unanchoredAssignments) old speaker assignment(s) need "
                            + "review; no reliable audio range")
                }
                let routed = RoutedTranscription(
                    text: transcript.text, modeUsed: transcript.modeUsed,
                    providerId: transcript.providerId, modelUsed: transcript.modelUsed,
                    segments: transcript.segments, words: transcript.words)
                try transcripts.save(id, result: routed)
                // Before the mark is cleared: a sidecar left saying "no speech" would never be
                // looked at again.
                try await store.updateTranscriptionState(id, .complete)
                changed.append(id)
                outcome = .transcript(routed)
            } else {
                outcome = .noSpeech(decidedBy: reheard.noSpeech ?? "cloud: nothing transcribed")
            }
            settled.append(
                ReheardTask(segmentId: id, settledAtMs: item.task.updatedAtMs, outcome: outcome))
        }
        guard !settled.isEmpty else { return false }
        try queue.settleReheard(settled)
        for item in settled {
            try? transcripts.dropReheard(item.segmentId)
            waiting[item.segmentId] = nil
        }
        replaced.formUnion(changed)
        let minutes = items.reduce(Int64(0)) {
            $0 + Int64($1.meta.frameCount) * Int64($1.meta.frameDurationMs)
        } / 60_000
        log.write(
            "rehearing: \(settled.count) recording(s), \(minutes) min, heard by "
                + "\(settings.cloudTranscriptionProvider.rawValue) after its account was refused; "
                + "\(changed.count) transcript(s) replaced")
        return true
    }
}

extension BackgroundUploadWiring {
    /// Sends one recording to `provider` while the app is awake, in the container the background
    /// uploader would use, and waits for the transcript.
    public static func rehear(
        cloud: SelectableCloudTranscriptionProvider,
        files: SegmentFileReader,
        transport: any HttpTransport,
        log: RuntimeLog = .silent
    ) -> StandInRehearing.Send {
        let audioSource = audioSource(files: files, log: log)
        return { segmentId, provider in
            guard let capable = cloud.capable(provider) else {
                throw TranscriptionError.providerUnavailable(providerId: provider.rawValue)
            }
            let format = capable.uploadFormat
            guard let audio = await audioSource(segmentId, format) else {
                throw TranscriptionError.transcriptionFailed("failed to read audio for \(segmentId)")
            }
            guard
                let plan = await capable.uploadPlan(
                    audio: audio.body(for: format), sampleRateHz: audio.sampleRateHz)
            else { throw TranscriptionError.providerUnavailable(providerId: provider.rawValue) }
            let (body, contentType) = MultipartBody.encode(
                boundary: "PebbleAudioBoundary-\(segmentId)", textFields: plan.textFields,
                file: plan.file)
            var headers = plan.headers
            headers["Content-Type"] = contentType
            let response = try await transport.execute(
                HttpTransportRequest(
                    method: "POST", url: plan.url, headers: headers, body: body,
                    carriesAudio: true))
            switch try await capable.onUploadResponse(
                httpStatus: response.status, body: response.text)
            {
            case .done(let result): return result
            case .needsControlPlane(let state):
                return try await capable.completeControlPlane(controlState: state)
            }
        }
    }
}
