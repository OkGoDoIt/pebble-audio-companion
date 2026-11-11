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
        let everyone = try await composition.people.listPeople().map(\.person)
        let colors = PersonPalette.indices(of: everyone)
        let coverage = try await cachedCoverage()
        let stats = Dictionary(coverage.byPerson.map { ($0.personId, $0) }, uniquingKeysWith: { a, _ in a })
        var people: [VoicePersonDisplay] = []
        for person in everyone {
            let own = examples.filter { $0.personId == person.id }
            let compatible = own.filter { $0.recipeID == LocalSpeakerDiarizer.recipeID }.count
            var row = VoicePersonDisplay(person: person, examples: VoiceExampleDisplay.grouped(own, kinds: kinds),
                                         compatibleExampleCount: compatible, colorIndex: colors[person.id] ?? 1)
            if let found = stats[person.id] {
                row.speechMs = found.speechMs
                row.conversations = found.conversations
                row.lastHeard = found.lastHeardMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
            }
            people.append(row)
        }
        people.sort { (a: VoicePersonDisplay, b: VoicePersonDisplay) -> Bool in
            a.speechMs == b.speechMs ? a.person.name < b.person.name : a.speechMs > b.speechMs
        }
        var display = VoiceSettingsDisplay(enabled: status.configuration.mode == .local,
                                           modelsReady: status.models == .installed,
                                           currentUser: everyone.first(where: \.isCurrentUser),
                                           people: people, notice: status.lastMessage)
        if coverage.speechMs > 0 {
            var shares: [VoiceCoverageDisplay.Share] = []
            for person in people where person.speechMs > 0 {
                shares.append(.init(id: person.id, name: person.name,
                                    fraction: Double(person.speechMs) / Double(coverage.speechMs), colorIndex: person.colorIndex))
            }
            display.coverage = VoiceCoverageDisplay(speechMs: coverage.speechMs, namedMs: coverage.namedMs, shares: shares)
        }
        display.people = await Self.placeClips(display.people, service: service, transcripts: composition.transcripts)
        display.pendingRecordings = status.pendingRecordings
        // This screen is on screen: the foreground rule (a charger, not too hot, no Low Power).
        if case .hold(let reason) = BackgroundWorkPolicy.decideVoiceRecognition(
            composition.settings.backgroundCatchUp, composition.foregroundState.devicePower, foreground: true) {
            display.waiting = reason
        }
        if let run {
            let runID = run.runID
            let startedAtMs = plan?.createdAtMs ?? run.updatedAtMs
            let (ownMatches, namedRecordings, newerWaiting, newerDone) = try await composition.database.reader.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM voice_auto_attributions WHERE runID = ? AND disposition = 'recognized'",
                                  arguments: [runID]) ?? 0,
                 // Every recording with a name, whichever pass found it: a run re-reading audio
                 // already named leaves those names under the pass that first found them.
                 try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT segmentId) FROM voice_auto_attributions WHERE disposition = 'recognized'") ?? 0,
                 // One queue, one count: the recordings arriving while a run works are part of
                 // what's left and what's been done. Counting only the run's own read
                 // "0 of 3831" for hours while newer recordings were being checked.
                 try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT segmentId) FROM voice_jobs WHERE runID LIKE 'recent:%' AND state IN ('pending', 'running')
                        AND segmentId NOT IN (SELECT segmentId FROM voice_jobs WHERE runID = ?)
                    """, arguments: [runID]) ?? 0,
                 try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT segmentId) FROM voice_jobs WHERE runID LIKE 'recent:%' AND state = 'done' AND updatedAtMs >= ?
                        AND segmentId NOT IN (SELECT segmentId FROM voice_jobs WHERE runID = ?)
                    """, arguments: [startedAtMs, runID]) ?? 0)
            }
            let discovering = plan?.state == "active" && plan?.discoveryComplete == false
            // Still finding clips: the ones queued so far plus the ones it has yet to look at.
            let left = discovering ? await service.historyRecordingsLeft(runID: runID) : 0
            let queued = run.pending + run.running + run.done + run.failed + newerWaiting + newerDone
            display.run = VoiceRunDisplay(id: run.runID,
                completed: run.done + run.failed + newerDone, total: left.map { queued + $0 },
                matched: namedRecordings, isRunning: discovering || run.pending + run.running + newerWaiting > 0,
                canUndo: ownMatches > 0, stopped: plan?.state != "active", failed: run.failed,
                progress: run.progress + Double(newerDone))
        }
        if display.run == nil, let plan {
            let discovering = plan.state == "active" && !plan.discoveryComplete
            display.run = VoiceRunDisplay(id: plan.runID, completed: 0,
                total: discovering ? await service.historyRecordingsLeft(runID: plan.runID) : 0, matched: 0,
                isRunning: discovering, canUndo: false, stopped: plan.state != "active")
        }
        return display
    }

    /// When each conversation sample was heard and what was said, read off its recording.
    private static func placeClips(_ people: [VoicePersonDisplay], service: VoiceRecognitionService,
                                   transcripts: FileTranscriptStore) async -> [VoicePersonDisplay] {
        await Task.detached(priority: .userInitiated) {
            people.map { person in
                var person = person
                person.examples = person.examples.map { example in
                    guard var clip = example.clip else { return example }
                    var example = example
                    clip.heardAt = service.wallMs(segmentId: clip.segmentId, mediaMs: clip.startMs)
                        .map { Date(timeIntervalSince1970: Double($0) / 1_000) }
                    clip.quote = UnknownVoiceDisplay.quote(transcripts.load(clip.segmentId), from: clip.startMs, to: clip.endMs)
                    example.clip = clip
                    return example
                }
                return person
            }
        }.value
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
        // The first time on, the whole archive is worth sorting: that's what there is to ask about.
        if enabled, try await service.historyPlans().isEmpty {
            _ = try await service.recognizeHistory(fromMs: 0, toMs: Int64(Date().timeIntervalSince1970 * 1_000))
        }
        changed()
    }
    func currentUser(name: String) async throws -> Person {
        try await composition.people.ensureCurrentUser(displayName: name)
    }
    func enrollPCM(personId: String, pcm16LE: Data, sessionID: String, kind: VoiceSampleKind?) async throws -> Int {
        let result = try await service.enrollPCM(personId: personId, pcm16LE: pcm16LE, sessionID: sessionID)
        try await record(kind, of: result)
        changed()
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
        changed()
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
        changed()
        return result
    }
    /// Every voice the screens have been shown. Kept past the next read: an answer goes to the
    /// speakers the person was looking at, however they've been sorted since.
    private var unknownGroups: [String: VoiceRecognitionService.UnknownVoiceGroup] = [:]
    /// Waiting out the offer to undo before learning from an answer.
    private var learning: [String: Task<Void, Never>] = [:]

    /// People & voices reads these at most this often unless something it shows was answered:
    /// voices are sorted again on every pass, and re-reading coverage on each one dirtied 1 GB of
    /// SQLite temp files in 22 minutes on the phone (2026-11-11, on the charger, screen open).
    private static let freshForSeconds: TimeInterval = 30
    private var coverageCache: (at: Date, value: VoiceCoverage)?
    private var voicesCache: (at: Date, value: [UnknownVoiceDisplay])?

    /// Something a person did changed what the screens show: read it again, and say so.
    private func changed() {
        coverageCache = nil
        voicesCache = nil
        composition.runtime.notifyVoiceConfigurationChanged()
    }

    private func cachedCoverage() async throws -> VoiceCoverage {
        if let cached = coverageCache, Date().timeIntervalSince(cached.at) < Self.freshForSeconds { return cached.value }
        let value = try await service.coverage()
        coverageCache = (Date(), value)
        return value
    }

    func unknownVoices() async -> [UnknownVoiceDisplay] {
        if let cached = voicesCache, Date().timeIntervalSince(cached.at) < Self.freshForSeconds { return cached.value }
        let voices = await readUnknownVoices()
        voicesCache = (Date(), voices)
        return voices
    }

    private func readUnknownVoices() async -> [UnknownVoiceDisplay] {
        guard (try? await service.status().configuration.mode) == .local,
              let groups = try? await service.unknownVoiceGroups(limit: 60) else { return [] }
        for group in groups { unknownGroups[group.id] = group }
        let people = (try? await composition.people.listPeople().map(\.person)) ?? []
        return await Task.detached(priority: .userInitiated) {
            // When each recording began is close enough for a list, and needs no file read; what
            // was said and the exact moment wait for `voiceDetail`.
            groups.map { group in
                let began = Dictionary(group.crops.map { ($0.segmentId, $0.createdAtMs) }, uniquingKeysWith: { a, _ in a })
                return UnknownVoiceDisplay.build(group, people: people, wallMs: { segment, _ in began[segment] },
                                                 transcript: { _ in nil })
            }
        }.value
    }

    func voiceDetail(id: String) async -> UnknownVoiceDisplay? {
        guard let group = await group(id) else { return nil }
        let people = (try? await composition.people.listPeople().map(\.person)) ?? []
        let service = service, transcripts = composition.transcripts
        return await Task.detached(priority: .userInitiated) {
            UnknownVoiceDisplay.build(group, people: people, wallMs: service.wallMs(segmentId:mediaMs:),
                                      transcript: { transcripts.load($0) })
        }.value
    }

    private func group(_ id: String) async -> VoiceRecognitionService.UnknownVoiceGroup? {
        if let known = unknownGroups[id] { return known }
        guard id.hasPrefix("voice-"), let clusterId = Int64(id.dropFirst(6)),
              let group = try? await service.unknownVoiceGroup(clusterId: clusterId) else { return nil }
        unknownGroups[id] = group
        return group
    }

    private var splitUndos: [String: VoiceSplitUndo] = [:]

    func prepareVoiceSplit(id: String) async throws -> VoiceSplitDraft {
        guard let group = await group(id) else { throw VoiceSplitError.unavailable }
        let preview = try await service.splitPreview(speakerIDs: group.crops.compactMap { Int64($0.id) })
        let service = service, transcripts = composition.transcripts
        return await Task.detached(priority: .userInitiated) {
            var clips: [String: UnknownVoiceClip] = [:]
            for (segment, atoms) in Dictionary(grouping: preview.atoms, by: \.segmentId) {
                let transcript = transcripts.load(segment)
                for atom in atoms {
                    let wall = service.wallMs(segmentId: segment, mediaMs: atom.startMs)
                    clips[atom.id] = UnknownVoiceClip(id: atom.id,segmentId: segment,startMs: atom.startMs,endMs: atom.endMs,
                        heardAt: wall.map { Date(timeIntervalSince1970: Double($0)/1000) },
                        quote: UnknownVoiceDisplay.quote(transcript,from: atom.startMs,to: atom.endMs))
                }
            }
            return VoiceSplitDraft(id: UUID().uuidString.lowercased(), groups: preview.groups.map { $0.compactMap { clips[$0] } }, payload: preview)
        }.value
    }

    private func splitPreview(_ draft: VoiceSplitDraft) throws -> VoiceSplitPreview {
        guard var preview = draft.payload else { throw VoiceSplitError.unavailable }
        let ids = draft.groups.flatMap { $0.map(\.id) }
        guard Set(ids).count == ids.count, Set(ids) == Set(preview.atoms.map(\.id)), draft.groups.allSatisfy({ !$0.isEmpty }) else {
            throw VoiceSplitError.invalidPartition
        }
        preview.groups = draft.groups.map { $0.map(\.id) }
        return preview
    }

    func refineVoiceSplit(_ draft: VoiceSplitDraft, group: Int, individual: Bool) async throws -> VoiceSplitDraft {
        let preview = try await splitPreview(draft).refined(group: group, individual: individual)
        let clips = Dictionary(uniqueKeysWithValues: draft.groups.flatMap { $0 }.map { ($0.id,$0) })
        return VoiceSplitDraft(id: draft.id,groups: preview.groups.map { $0.compactMap { clips[$0] } },payload: preview)
    }

    func saveVoiceSplit(_ draft: VoiceSplitDraft) async throws -> VoiceSplitResult {
        let saved = try await service.saveSplitGroups(splitPreview(draft))
        let undo = saved.undo
        splitUndos[undo.operation] = undo
        unknownGroups.removeAll()
        // Kept under their own ids: a name given with the split goes to these speakers, whatever
        // the next sort numbers their voices.
        let ids = saved.groups.indices.map { "split-\(undo.operation)-\($0)" }
        for (id, group) in zip(ids, saved.groups) { unknownGroups[id] = group }
        changed()
        Task { [weak self] in
            try? await Task.sleep(for: SnackbarItem.lifetime + .seconds(2))
            self?.splitUndos[undo.operation] = nil
        }
        return VoiceSplitResult(undoToken: undo.operation, groupIDs: ids)
    }

    func undoVoiceSplit(id: String) async throws {
        guard let undo = splitUndos[id] else { throw VoiceSplitError.changed }
        try await service.undoSplit(undo)
        splitUndos[id] = nil
        unknownGroups.removeAll()
        changed()
    }

    func nameUnknownVoice(id: String, personId: String, clips: Set<String>?) async throws -> Int {
        guard let whole = await group(id) else { throw SpeakerEditorError.voiceUnavailable }
        let group = clips.map { whole.selecting(clips: $0) } ?? whole
        guard !group.crops.isEmpty else { return 0 }
        try await service.confirmUnknownVoice(group, personId: personId)
        changed()
        // Samples come from the models, and the offer to undo is still up: this waits.
        let service = service
        learning[id] = Task { [weak self] in
            try? await Task.sleep(for: SnackbarItem.lifetime + .seconds(1))
            guard !Task.isCancelled else { return }
            await service.learnFrom(group, personId: personId)
            self?.changed()
        }
        return group.recordingCount
    }

    func undoNaming(id: String, personId: String) async throws {
        learning[id]?.cancel()
        learning[id] = nil
        guard let group = await group(id) else { throw SpeakerEditorError.voiceUnavailable }
        try await service.undoUnknownVoice(group, personId: personId)
        changed()
    }

    func rejectSuggestion(id: String, personId: String) async throws {
        guard let group = await group(id) else { throw SpeakerEditorError.voiceUnavailable }
        try await service.rejectSuggestion(group, personId: personId)
        changed()
    }

    func appearances(personId: String) async -> [VoiceAppearanceDisplay] {
        guard let found = try? await service.appearances(personId: personId) else { return [] }
        return found.map { appearance in
            let heardAt = Date(timeIntervalSince1970: Double(appearance.startMs) / 1_000)
            return VoiceAppearanceDisplay(conversationId: appearance.conversationId,
                title: appearance.title ?? "Conversation", heardAt: heardAt, speechMs: appearance.speechMs,
                speakerIds: appearance.speakerIds,
                clip: UnknownVoiceClip(id: "\(appearance.conversationId):\(appearance.clip.speakerId)",
                    segmentId: appearance.clip.segmentId, startMs: appearance.clip.startMediaMs,
                    endMs: appearance.clip.endMediaMs, heardAt: heardAt))
        }
    }

    func notThisPerson(_ appearance: VoiceAppearanceDisplay, personId: String) async throws {
        try await service.notThisPerson(speakerIds: appearance.speakerIds, personId: personId)
        changed()
    }

    /// The transcript paragraph a clip sits in, when most of the clip is inside it: naming the
    /// clip should name what the person reads, and a name over part of a paragraph names nothing.
    nonisolated static func paragraph(around clip: Range<Int64>, in segments: [TranscriptSegment]) -> Range<Int64>? {
        let best = segments.map { segment -> (Range<Int64>, Int64) in
            let range = segment.startMs..<max(segment.startMs + 1, segment.endMs)
            return (range, max(0, min(range.upperBound, clip.upperBound) - max(range.lowerBound, clip.lowerBound)))
        }.max { $0.1 < $1.1 }
        guard let best, best.1 * 2 >= clip.upperBound - clip.lowerBound else { return nil }
        return best.0
    }

    func dismissUnknownVoice(id: String) async throws {
        guard let group = await group(id) else { throw SpeakerEditorError.voiceUnavailable }
        try await service.dismissUnknownVoice(group)
        unknownGroups[id] = nil
        changed()
    }
    func ignoreUnknownClip(_ clip: UnknownVoiceClip) async throws {
        try await service.ignoreUnknownClip(segmentId: clip.segmentId, startMediaMs: clip.startMs, endMediaMs: clip.endMs)
        changed()
    }
    func clipAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data? {
        try? await service.clipPCM(segmentId: segmentId, startMediaMs: startMs, endMediaMs: endMs)
    }
    func clipContextAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data? {
        try? await service.clipContextPCM(segmentId: segmentId, startMediaMs: startMs, endMediaMs: endMs)
    }

    func recognizeAfterLearning(personId: String, since earliestMs: Int64?) async {
        // A name changes what voices sort into, and the names follow from saved prints. Nothing
        // has to be listened to again.
        changed()
    }
    func cancelEnrollment() async {
        service.cancelEnrollment()
        await composition.voiceModels.cancel()
    }
    func recognizeHistory(days: Int?) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let from = days.map { now - Int64(max(1, $0)) * 86_400_000 } ?? 0
        _ = try await service.recognizeHistory(fromMs: from, toMs: now)
        changed()
    }
    func cancelRun(id: String) async throws {
        try await service.cancel(runId: id)
        changed()
    }
    func undoRun(id: String) async throws {
        try await service.undo(runId: id)
        changed()
    }
    func clearAutomaticNames() async throws {
        try await service.clearAutomaticNames()
        changed()
    }
    func forgetVoice(personId: String) async throws {
        try await service.forgetProfile(personId: personId)
        changed()
    }
    func removeExamples(ids: [String]) async throws {
        try await service.removeExamples(ids: ids)
        changed()
    }
}

extension UnknownVoiceDisplay {
    /// One clip per recording, newest first, with what was said; and when the voice tends to be heard.
    nonisolated static func build(_ group: VoiceRecognitionService.UnknownVoiceGroup, people: [Person] = [],
                                  wallMs: (String, Int64) -> Int64?,
                                  transcript: (String) -> SegmentTranscript?,
                                  now: Date = Date(), calendar: Calendar = .current) -> UnknownVoiceDisplay {
        let timed = group.crops.map { crop in
            (crop, wallMs(crop.segmentId, crop.startMediaMs).map { Date(timeIntervalSince1970: Double($0) / 1_000) })
        }
        var clips: [UnknownVoiceClip] = []
        for (crop, heardAt) in timed.sorted(by: { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) })
        {
            clips.append(UnknownVoiceClip(id: crop.id, segmentId: crop.segmentId, startMs: crop.startMediaMs,
                endMs: crop.endMediaMs, heardAt: heardAt,
                quote: quote(transcript(crop.segmentId), from: crop.startMediaMs, to: crop.endMediaMs)))
        }
        let dates = timed.compactMap(\.1)
        let parts = [timeOfDay(dates, calendar: calendar), dates.max().map { lastHeard($0, now: now, calendar: calendar) }]
            .compactMap { $0 }
        let detail = parts.joined(separator: " · ")
        var display = UnknownVoiceDisplay(id: group.id, recordingCount: group.recordingCount,
                                          detail: detail.prefix(1).uppercased() + detail.dropFirst(), clips: clips,
                                          speechMs: group.speechMs, leadClipID: group.crops.first?.id)
        display.repaired = group.repaired
        if let id = group.suggestedPersonId, let person = people.first(where: { $0.id == id }) {
            display.suggestion = VoiceSuggestionDisplay(person: person, colorIndex: PersonPalette.indices(of: people)[id] ?? 1,
                                                        score: group.suggestedScore ?? 0)
        }
        return display
    }

    /// What was said during a clip, in the paragraph's own words. Word timings are subword
    /// tokens with no spacing ("L", "ike"), so they only locate the clip inside the paragraph
    /// text; the quote is that text, widened to whole words.
    nonisolated static func quote(_ transcript: SegmentTranscript?, from start: Int64, to end: Int64) -> String? {
        guard let transcript else { return nil }
        let paragraphs = transcript.segments.filter { $0.startMs < end && $0.endMs > start }
        let parts = paragraphs.map { paragraph -> String in
            let tokens = transcript.words.filter { $0.startMs >= paragraph.startMs && $0.endMs <= paragraph.endMs }
            return excerpt(paragraph.text, tokens: tokens, from: start, to: end) ?? paragraph.text
        }
        let text = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        guard text.count > 140 else { return "“\(text)”" }
        let cut = text.prefix(140)
        return "“\(cut.prefix(upTo: cut.lastIndex(of: " ") ?? cut.endIndex))…”"
    }

    /// The words of `text` the clip covers, found by walking the tokens through it. Nil when
    /// the tokens don't spell the text (another provider's tokens), so the caller shows it all.
    nonisolated static func excerpt(_ text: String, tokens: [TranscriptWord], from start: Int64, to end: Int64) -> String? {
        let chars = Array(text)
        var index = 0
        var lower: Int?, upper: Int?
        for token in tokens {
            let letters = token.text.filter { !$0.isWhitespace }
            guard !letters.isEmpty else { continue }
            while index < chars.count, chars[index].isWhitespace { index += 1 }
            let tokenStart = index
            for letter in letters {
                guard index < chars.count, chars[index] == letter else { return nil }
                index += 1
            }
            if token.startMs < end && token.endMs > start {
                if lower == nil { lower = tokenStart }
                upper = index
            }
        }
        guard var lo = lower, var hi = upper else { return nil }
        while lo > 0, !chars[lo - 1].isWhitespace { lo -= 1 }
        while hi < chars.count, !chars[hi].isWhitespace { hi += 1 }
        let words = String(chars[lo..<hi]).trimmingCharacters(in: .whitespaces)
        let before = lo > 0 ? "…" : "", after = hi < chars.count ? "…" : ""
        return before + words + after
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
