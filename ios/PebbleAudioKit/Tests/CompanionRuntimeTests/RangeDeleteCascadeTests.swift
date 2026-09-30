import AppDB
import AudioCodec
import CompanionRuntime
import Foundation
import Intelligence
import SearchKit
import SegmentStore
import Testing
import Transcription
import WireProtocol

// One segment routinely holds the end of one conversation and the start of the next. Deleting
// a conversation has to destroy exactly its own pieces — completely — and nothing that belongs
// to the conversation it shares a segment with: not a frame of its audio, not a turn of its
// transcript, not its follow-ups, its title, its notes or its id.

@Suite struct RangeDeleteCascadeTests {

    /// SearchKit has a `TranscriptSegment` of its own; these are the transcript store's turns.
    private typealias Turn = Transcription.TranscriptSegment

    // MARK: - World

    /// The runtime fixture plus a cascade wired the way the app wires it (audio content
    /// included, which the shared fixture's cascade leaves out).
    private struct World {
        let fixture: RuntimeFixture
        let cascade: DeleteCascade
        let audioContent: AudioContentStore
        let cuts: ConversationCutStore
        let candidates: FollowUpCandidateStore
        let notes: NotesStore
        let people: PeopleStore
        let tags: TagStore
    }

    private func makeWorld() throws -> World {
        let fixture = try RuntimeFixture()
        let store = fixture.store
        let transcripts = fixture.transcriptStore
        let clock = fixture.clock
        let audioContentStore = AudioContentStore(db: fixture.database)
        let candidates = FollowUpCandidateStore(db: fixture.database)
        let cascade = DeleteCascade(
            store: store,
            transcription: fixture.transcription,
            annotations: fixture.annotations,
            aiOutputs: fixture.aiOutputs,
            followUps: fixture.followUps,
            candidates: candidates,
            recaps: fixture.recap,
            enrichment: fixture.enrichment,
            index: fixture.index,
            donator: SpotlightDonator(index: fixture.index, spotlight: fixture.spotlight),
            boundaryOverrides: BoundaryOverrideStore(db: fixture.database),
            audioContent: AudioContentService(
                listSegments: { await store.listSegments() },
                speechTimingsOf: { transcripts.loadSpeechTimings($0) },
                transcriptVersionOf: { transcripts.version($0) },
                store: audioContentStore,
                nowMs: { clock.nowMs }),
            live: fixture.live)
        return World(
            fixture: fixture, cascade: cascade, audioContent: audioContentStore,
            cuts: ConversationCutStore(db: fixture.database), candidates: candidates,
            notes: NotesStore(db: fixture.database), people: PeopleStore(db: fixture.database),
            tags: TagStore(db: fixture.database))
    }

    static let dayMs: UInt64 = 1_756_512_000_000

    /// Real Speex frames of a tone, so the log holds what the watch would have sent and a
    /// silenced frame is unmistakable beside them. Forty distinct frames, cycled.
    private static let speechFrames: [[UInt8]] = {
        let encoder = try! SpeexFrameEncoder()
        return (0..<40).map { frame in
            let samples = (0..<320).map { i -> Int16 in
                let t = Double(frame * 320 + i) / 16_000
                return Int16(6_000 * sin(2 * .pi * (180 + Double(frame) * 9) * t))
            }
            return [UInt8](try! encoder.encodeFrame(samples))
        }
    }()

    /// A closed, transcribed-looking segment of `seconds` of audio, recorded the way the watch
    /// records: 25-byte frames at 9800 bps.
    private func writeSegment(
        _ world: World, streamId: UInt32 = 0x5EED_0001, startTimeMs: UInt64 = dayMs,
        seconds: Int = 60
    ) async throws -> String {
        let store = world.fixture.store
        let start = StreamStart(
            protocolVersion: ProtocolConstants.protocolVersion, streamId: streamId,
            codecIdRaw: CodecId.speexWideband.rawValue, channels: 1, frameSamples: 320,
            sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: startTimeMs, startMonotonicMs: 0, flags: 0)
        try await store.openSegment(
            start: start, receivedAtMs: Int64(startTimeMs), provenance: nil)
        let count = seconds * 50
        let frames = (0..<count).map {
            SegmentFrame(
                sequence: UInt32($0), sampleIndex: UInt64($0) * 320,
                payload: Self.speechFrames[$0 % Self.speechFrames.count])
        }
        _ = try await store.appendFrames(streamId: streamId, frames: frames)
        let id = try #require(await store.openSegmentId)
        // The phone's clock at close bounds the segment's wall span; put it past the audio.
        let closeAt = Int64(startTimeMs) + Int64(seconds) * 1_000 + 1_000
        if world.fixture.clock.nowMs < closeAt {
            await world.fixture.clock.advance(by: closeAt - world.fixture.clock.nowMs)
        }
        try await store.closeSegment(
            reason: .stopped(
                reasonRaw: Int(StopReason.shutdown.rawValue), finalSequence: UInt32(count - 1),
                finalSampleIndex: UInt64(count) * 320))
        return id
    }

    private func turn(_ text: String, _ startMs: Int64, _ endMs: Int64) -> Turn {
        Turn(text: text, startMs: startMs, endMs: endMs, speaker: "1")
    }

    /// Saves a transcript with these turns (one word timing per turn) and settles the segment.
    private func transcribe(
        _ world: World, _ segmentId: String, _ turns: [Turn]
    ) async throws {
        try world.fixture.transcriptStore.save(segmentId, result: routed(turns))
        try world.fixture.queue.enqueue(segmentId)
        try await world.fixture.store.updateTranscriptionState(segmentId, .complete)
    }

    private func routed(_ turns: [Turn]) -> RoutedTranscription {
        RoutedTranscription(
            text: turns.map(\.text).joined(separator: " "), modeUsed: .localOnly,
            providerId: "fake", modelUsed: nil, segments: turns,
            words: turns.map {
                TranscriptWord(
                    text: String($0.text.split(separator: " ").first ?? ""), startMs: $0.startMs,
                    endMs: $0.startMs + 300)
            })
    }

    private func split(_ world: World, _ segmentId: String, at mediaMs: Int64) async throws {
        try await world.cuts.setOverride(
            at: ConversationCut(segmentId: segmentId, mediaMs: mediaMs), decision: .split)
    }

    // The two conversations every test below is about: the dentist, then the budget.
    private static let dentist = [
        Turn(text: "remember the dentist on friday", startMs: 2_000, endMs: 8_000, speaker: "1"),
        Turn(text: "i will call the dentist back", startMs: 10_000, endMs: 15_000, speaker: "2"),
    ]
    private static let budget = [
        Turn(text: "now about the budget numbers", startMs: 40_000, endMs: 45_000, speaker: "1"),
        Turn(text: "send the budget spreadsheet tonight", startMs: 47_000, endMs: 55_000, speaker: "2"),
    ]

    /// One 60 s segment: the dentist conversation owns `[0, 30 s)`, the budget one the rest.
    private func twoConversationsInOneSegment(
        _ world: World
    ) async throws -> (segmentId: String, first: GroupedConversation, second: GroupedConversation) {
        let segmentId = try await writeSegment(world)
        try await transcribe(world, segmentId, Self.dentist + Self.budget)
        try await split(world, segmentId, at: 30_000)
        let conversations = try await world.fixture.enrichment.regroup()
        try #require(conversations.count == 2)
        #expect(conversations[0].members == [ConversationMember(segmentId: segmentId, endMediaMs: 30_000)])
        #expect(conversations[1].members == [ConversationMember(segmentId: segmentId, startMediaMs: 30_000)])
        return (segmentId, conversations[0], conversations[1])
    }

    /// Everything a conversation accumulates, for one of the two: keyed by its id and placed
    /// at `atMs` of the shared segment.
    private func seed(
        _ world: World, _ conversation: GroupedConversation, segmentId: String, name: String,
        atMs: Int64
    ) async throws {
        let fixture = world.fixture
        let id = conversation.id
        _ = try await fixture.annotations.save(
            ConversationAnnotation(conversationId: id, title: "\(name) title", summary: "\(name) summary"))
        _ = try await world.tags.addTag(conversationId: id, name: name, source: "user")
        _ = try await world.notes.create(
            conversationId: id, templateId: "summary", title: "\(name) note", body: "about the \(name)")
        let person = try await world.people.createPerson(name: "\(name) person")
        try await world.people.assign(conversationId: id, label: "1", personId: person.id)
        // An extracted follow-up, placed by where its quote was spoken…
        try await fixture.followUps.upsertExtracted(
            FollowUp(
                id: "fu-\(name)", text: "follow up on the \(name)", done: false,
                sourceConversationId: id, sourceSegmentId: segmentId, createdAtMs: 0,
                quote: "the \(name)", sourceStartMs: atMs, sourceEndMs: atMs + 1_000))
        // …and one the person wrote on the conversation, which carries no position.
        let written = try await fixture.followUps.add(
            text: "my own \(name) reminder", conversationId: id, segmentId: segmentId, nowMs: 0)
        try await world.candidates.save(
            FollowUpCandidate(
                id: "cand-\(name)", conversationId: id, segmentId: segmentId,
                task: "candidate about the \(name)", startMs: atMs, createdAtMs: 0))
        try fixture.index.upsert([
            IndexItem(
                id: id, kind: .conversation, title: "\(name) title",
                fullText: (Self.dentist + Self.budget).map(\.text).joined(separator: " "),
                contentCreationDateMs: 0),
            IndexItem(
                id: "fu-\(name)", kind: .followUp, title: "follow up on the \(name)",
                contentCreationDateMs: 0),
            IndexItem(
                id: written.id, kind: .followUp, title: written.text, contentCreationDateMs: 0),
        ])
        for note in try await world.notes.list(conversationId: id) {
            try fixture.index.upsert([
                IndexItem(
                    id: note.id, kind: .note, title: note.title, fullText: note.body,
                    contentCreationDateMs: 0)
            ])
        }
    }

    private func frames(_ world: World, _ segmentId: String) async -> [FrameRecord] {
        await world.fixture.store.readFrames(segmentId)
    }

    // MARK: - Deleting one of two conversations that share a segment

    @Test func deletingTheLaterConversationLeavesTheEarlierOneExactlyAsItWas() async throws {
        let world = try makeWorld()
        let fixture = world.fixture
        let (segmentId, dentist, budget) = try await twoConversationsInOneSegment(world)
        try await seed(world, dentist, segmentId: segmentId, name: "dentist", atMs: 3_000)
        try await seed(world, budget, segmentId: segmentId, name: "budget", atMs: 41_000)
        _ = try await fixture.recapStore.save(
            DailyRecap(dateKey: "2026-08-30", text: "dentist and budget", segmentIds: [segmentId]))
        try fixture.index.upsert([
            IndexItem(
                id: RecapIndex.documentId(dateKey: "2026-08-30"), kind: .recap, title: "Recap",
                fullText: "dentist and budget", contentCreationDateMs: 0)
        ])
        // A decision inside the budget conversation, and a correction about each half.
        try await world.cuts.setOverride(
            at: ConversationCut(segmentId: segmentId, mediaMs: 46_000), decision: .join)
        let day = Int64(Self.dayMs)
        let budgetCorrection = try await world.audioContent.addOverride(
            startMs: day + 40_000, endMs: day + 50_000, kind: .noConversation, atMs: 0)
        let dentistCorrection = try await world.audioContent.addOverride(
            startMs: day + 2_000, endMs: day + 8_000, kind: .noConversation, atMs: 0)
        let spanning = try await world.audioContent.addOverride(
            startMs: day + 20_000, endMs: day + 40_000, kind: .conversation, atMs: 0)

        let before = await frames(world, segmentId)
        let metaBefore = try #require(await fixture.store.readMeta(segmentId))
        let silence = try SpeexSilence.frame()

        let deleted = await world.cascade.deleteConversation(budget.id)

        // The segment is shared, so it still exists: nothing was deleted WHOLE.
        #expect(deleted.isEmpty)

        // --- the audio ---------------------------------------------------------------------
        let after = await frames(world, segmentId)
        #expect(after.count == before.count)
        // The dentist's 30 s: byte for byte what it was.
        #expect(Array(after[..<1_500]) == Array(before[..<1_500]))
        // The budget's 30 s: silence, in the same records.
        #expect(after[1_500...].allSatisfy { $0.payload == silence })
        #expect(after.map(\.sequence) == before.map(\.sequence))
        #expect(after.map(\.sampleIndex) == before.map(\.sampleIndex))
        // Same frame count, same extents, same size: every clock is where it was.
        #expect(await fixture.store.readMeta(segmentId) == metaBefore)
        // And it still decodes end to end — the neighbour's audio is playable.
        let pcm = try SpeexFrameDecoder().decodeAll(frames: after.map { Data($0.payload) })
        #expect(pcm.count == after.count * 320 * 2)

        // --- the transcript ----------------------------------------------------------------
        let transcript = try #require(fixture.transcriptStore.load(segmentId))
        #expect(transcript.segments == Self.dentist)
        #expect(transcript.words.map(\.startMs) == [2_000, 10_000])
        #expect(!transcript.text.contains("budget"))
        // A transcription made from the audio as it WAS lands after the delete: the words do
        // not come back.
        let landed = try fixture.transcriptStore.save(
            segmentId, result: routed(Self.dentist + Self.budget))
        #expect(landed.segments == Self.dentist)

        // --- follow-ups --------------------------------------------------------------------
        let followUps = try await fixture.followUps.list(scope: .all)
        #expect(
            Set(followUps.map(\.text)) == ["follow up on the dentist", "my own dentist reminder"])
        #expect(try await world.candidates.list(conversationId: budget.id).isEmpty)
        #expect(try await world.candidates.list(conversationId: dentist.id).map(\.id) == ["cand-dentist"])

        // --- everything keyed by the conversation ------------------------------------------
        #expect(try await fixture.annotations.load(budget.id) == nil)
        #expect(try await fixture.annotations.load(dentist.id)?.title == "dentist title")
        #expect(try await world.notes.list(conversationId: budget.id).isEmpty)
        #expect(try await world.notes.list(conversationId: dentist.id).count == 1)
        #expect(try await world.people.assignments(forConversation: budget.id).isEmpty)
        #expect(try await world.people.assignments(forConversation: dentist.id).count == 1)
        #expect(try await world.tags.tags(forConversation: budget.id).isEmpty)
        #expect(try await world.tags.tags(forConversation: dentist.id).count == 1)

        // --- search ------------------------------------------------------------------------
        #expect(!fixture.index.contains(id: budget.id, kind: .conversation))
        #expect(!fixture.index.contains(id: "fu-budget", kind: .followUp))
        #expect(fixture.index.contains(id: "fu-dentist", kind: .followUp))
        // The neighbour is still findable, by its own words and none of the deleted ones.
        let findable = try #require(fixture.index.fullText(id: dentist.id, kind: .conversation))
        #expect(findable.contains("dentist"))
        #expect(!findable.contains("budget"))
        // The note written from the deleted conversation is gone from search too.
        #expect(fixture.index.ids.allSatisfy { id in
            fixture.index.fullText(id: id, kind: .note).map { !$0.contains("budget") } ?? true
        })
        // The day recap quoted the segment: it goes, and regenerates.
        #expect(try await fixture.recapStore.list().isEmpty)
        #expect(!fixture.index.contains(id: "day-2026-08-30", kind: .recap))

        // --- cuts, decisions, corrections --------------------------------------------------
        #expect(try await world.cuts.overrides().isEmpty)
        let corrections = try await world.audioContent.overrides(overlappingMs: day..<(day + 60_000))
        #expect(!corrections.contains(budgetCorrection))
        #expect(corrections.contains(dentistCorrection))
        #expect(corrections.contains(spanning))

        // --- the grouping ------------------------------------------------------------------
        // No empty conversation where the deleted one was: its silence is the tail of the
        // conversation before it, which keeps its id.
        let conversations = try await fixture.enrichment.regroup()
        #expect(conversations.map(\.id) == [dentist.id])
        #expect(conversations[0].memberSegmentIds == [segmentId])

        // --- and then the neighbour --------------------------------------------------------
        let rest = await world.cascade.deleteConversation(dentist.id)

        #expect(rest == [segmentId])
        #expect(await fixture.store.listSegments().isEmpty)
        #expect(fixture.transcriptStore.load(segmentId) == nil)
        #expect(fixture.transcriptStore.redactions(segmentId).isEmpty)
        #expect(try await fixture.followUps.list(scope: .all).isEmpty)
        #expect(try await world.candidates.list(conversationId: dentist.id).isEmpty)
        #expect(try await fixture.annotations.load(dentist.id) == nil)
        #expect(try await world.notes.list(conversationId: dentist.id).isEmpty)
        #expect(try await world.people.assignments(forConversation: dentist.id).isEmpty)
        #expect(fixture.index.ids.isEmpty)
        #expect(try await fixture.enrichment.regroup().isEmpty)
        // A correction that was only about the deleted recording goes with it.
        #expect(try await world.audioContent.overrides(overlappingMs: day..<(day + 60_000)).isEmpty)
    }

    /// The other direction, which is the harder one for the grouping: the deleted conversation
    /// OPENED the segment, so its silence has nothing before it to join and becomes the lead-in
    /// of the conversation after it. That conversation must still be the same conversation —
    /// same id, same title, same notes — not a new one that happens to hold its audio.
    @Test func deletingTheEarlierConversationLeavesTheLaterOneItsIdentity() async throws {
        let world = try makeWorld()
        let fixture = world.fixture
        let (segmentId, dentist, budget) = try await twoConversationsInOneSegment(world)
        try await seed(world, dentist, segmentId: segmentId, name: "dentist", atMs: 3_000)
        try await seed(world, budget, segmentId: segmentId, name: "budget", atMs: 41_000)
        let before = await frames(world, segmentId)
        let silence = try SpeexSilence.frame()

        let deleted = await world.cascade.deleteConversation(dentist.id)

        #expect(deleted.isEmpty)
        let after = await frames(world, segmentId)
        #expect(after[..<1_500].allSatisfy { $0.payload == silence })
        #expect(Array(after[1_500...]) == Array(before[1_500...]))

        // The budget's turns are where they were, on the clock they were on.
        #expect(fixture.transcriptStore.load(segmentId)?.segments == Self.budget)
        let followUps = try await fixture.followUps.list(scope: .all)
        #expect(Set(followUps.map(\.text)) == ["follow up on the budget", "my own budget reminder"])
        let kept = try #require(followUps.first { $0.id == "fu-budget" })
        #expect(kept.sourceStartMs == 41_000)

        // One conversation, and it is the budget one: not renamed, and above all not handed
        // the id of the conversation that was just deleted.
        let conversations = try await fixture.enrichment.regroup()
        #expect(conversations.map(\.id) == [budget.id])
        #expect(budget.id != dentist.id)
        #expect(try await fixture.annotations.load(budget.id)?.title == "budget title")
        #expect(try await world.notes.list(conversationId: budget.id).count == 1)
        #expect(try await world.tags.tags(forConversation: budget.id).count == 1)
        #expect(try await fixture.annotations.load(dentist.id) == nil)
        #expect(try await world.notes.list(conversationId: dentist.id).isEmpty)
        // It stays the same conversation on the rebuild after that, too.
        await fixture.enrichment.invalidateGrouping()
        #expect(try await fixture.enrichment.regroup().map(\.id) == [budget.id])

        // Deleting it now removes what is left of the recording.
        #expect(await world.cascade.deleteConversation(budget.id) == [segmentId])
        #expect(await fixture.store.listSegments().isEmpty)
        #expect(fixture.transcriptStore.load(segmentId) == nil)
        #expect(try await fixture.followUps.list(scope: .all).isEmpty)
        #expect(try await world.cuts.overrides().isEmpty)
    }

    @Test func deletingTheMiddleOfThreeLeavesBothNeighbours() async throws {
        let world = try makeWorld()
        let fixture = world.fixture
        let segmentId = try await writeSegment(world)
        let opening = [turn("good morning everyone", 2_000, 8_000)]
        let middle = [turn("the secret thing nobody should keep", 22_000, 30_000)]
        let closing = [turn("see you all next week", 42_000, 50_000)]
        try await transcribe(world, segmentId, opening + middle + closing)
        try await split(world, segmentId, at: 20_000)
        try await split(world, segmentId, at: 40_000)
        let conversations = try await fixture.enrichment.regroup()
        try #require(conversations.count == 3)
        let before = await frames(world, segmentId)
        let silence = try SpeexSilence.frame()

        #expect(await world.cascade.deleteConversation(conversations[1].id).isEmpty)

        let after = await frames(world, segmentId)
        #expect(Array(after[..<1_000]) == Array(before[..<1_000]))
        #expect(after[1_000..<2_000].allSatisfy { $0.payload == silence })
        #expect(Array(after[2_000...]) == Array(before[2_000...]))
        #expect(fixture.transcriptStore.load(segmentId)?.segments == opening + closing)
        #expect(fixture.transcriptStore.redactions(segmentId) == [20_000..<40_000])
        // The cut that began the deleted conversation went with it; the one that begins the
        // next conversation is still there.
        #expect(
            try await world.cuts.overrides()
                == [ConversationCut(segmentId: segmentId, mediaMs: 40_000): .split])
        let remaining = try await fixture.enrichment.regroup()
        #expect(remaining.map(\.id) == [conversations[0].id, conversations[2].id])
        #expect(remaining[0].members == [ConversationMember(segmentId: segmentId, endMediaMs: 40_000)])
    }

    /// A conversation that ends one segment and owns the whole of the next: the segment it
    /// owns outright is deleted, the one it shares is only silenced from where it began.
    @Test func aConversationAcrossTwoSegmentsDeletesOneAndSilencesPartOfTheOther() async throws {
        let world = try makeWorld()
        let fixture = world.fixture
        let first = try await writeSegment(world, streamId: 1, startTimeMs: Self.dayMs)
        let second = try await writeSegment(world, streamId: 2, startTimeMs: Self.dayMs + 60_000)
        try await transcribe(
            world, first,
            [turn("good morning everyone", 2_000, 8_000), turn("about the budget", 40_000, 50_000)])
        try await transcribe(
            world, second,
            [turn("the budget is late", 1_000, 9_000), turn("fix the budget tonight", 12_000, 20_000)])
        try await split(world, first, at: 30_000)
        let conversations = try await fixture.enrichment.regroup()
        try #require(conversations.count == 2)
        let budget = conversations[1]
        #expect(
            budget.members == [
                ConversationMember(segmentId: first, startMediaMs: 30_000),
                ConversationMember(segmentId: second),
            ])
        let before = await frames(world, first)
        let silence = try SpeexSilence.frame()

        let deleted = await world.cascade.deleteConversation(budget.id)

        #expect(deleted == [second])
        #expect(await fixture.store.listSegments().map(\.segmentId) == [first])
        #expect(fixture.transcriptStore.load(second) == nil)
        let after = await frames(world, first)
        #expect(Array(after[..<1_500]) == Array(before[..<1_500]))
        #expect(after[1_500...].allSatisfy { $0.payload == silence })
        #expect(fixture.transcriptStore.load(first)?.segments.map(\.text) == ["good morning everyone"])
        #expect(try await fixture.enrichment.regroup().map(\.id) == [conversations[0].id])
    }

    /// Why the cascade takes the deleted pieces out of the stored grouping, and why it does so
    /// on BOTH sides of dropping the speech evidence. The pipeline regroups on its own schedule
    /// and nothing holds it off while a delete is in progress; these are the two places its
    /// rebuild can land, replayed by hand.
    @Test func theStoredGroupingHandOverAndWhatItGuardsAgainst() async throws {
        // Without the hand-over: the deleted conversation's words go, the rebuild gives its
        // silence to the conversation after it — and gives that conversation the deleted id.
        do {
            let world = try makeWorld()
            let (segmentId, dentist, _) = try await twoConversationsInOneSegment(world)
            try world.fixture.transcriptStore.redact(segmentId, mediaRangeMs: 0..<30_000)
            await world.fixture.enrichment.invalidateSpeechEvidence(segmentId: segmentId)
            let renamed = try await world.fixture.enrichment.regroup()
            #expect(renamed.map(\.id) == [dentist.id], "the hazard this test is about has gone")
        }

        // With it, and with a rebuild landing between its two halves: the rebuild still
        // remembers the deleted turns, so it writes the deleted conversation's place back; the
        // second release takes it out again, and the neighbour keeps its id.
        let world = try makeWorld()
        let enrichment = world.fixture.enrichment
        let (segmentId, dentist, budget) = try await twoConversationsInOneSegment(world)
        let piece = try #require(dentist.members.first)
        try world.fixture.transcriptStore.redact(segmentId, mediaRangeMs: 0..<30_000)

        try await world.cuts.releaseStoredPlace(of: [piece])
        let remembered = try await enrichment.regroup()
        #expect(remembered.map(\.id) == [dentist.id, budget.id])
        await enrichment.invalidateSpeechEvidence(segmentId: segmentId)
        try await world.cuts.releaseStoredPlace(of: [piece])

        #expect(try await enrichment.regroup().map(\.id) == [budget.id])
        // Releasing what is already released changes nothing.
        try await world.cuts.releaseStoredPlace(of: [piece])
        await enrichment.invalidateGrouping()
        #expect(try await enrichment.regroup().map(\.id) == [budget.id])
    }

    // MARK: - The staged upload

    /// A cloud-primary segment handed to the background transport sits on disk as a multipart
    /// body holding its audio as it was. Deleting the audio has to take that copy too.
    @Test func theStagedUploadBodyDoesNotOutliveTheAudioItHolds() async throws {
        let world = try makeWorld()
        let fixture = world.fixture
        let (segmentId, dentist, budget) = try await twoConversationsInOneSegment(world)
        let bodyDir = BackgroundUploadWiring.bodyDir(root: fixture.root)
        try FileManager.default.createDirectory(at: bodyDir, withIntermediateDirectories: true)
        let body = bodyDir.appendingPathComponent("\(segmentId).body")
        let jobs = CloudUploadJobStore(root: fixture.root)
        func stage() throws {
            try Data("the original audio".utf8).write(to: body)
            jobs.save(
                CloudUploadJob(
                    jobId: segmentId, provider: .openAi, bodyFilePath: body.path, createdAtMs: 0))
        }

        // Part of the segment: the body goes, the job stays so its outcome is still handled —
        // and what it brings back is cut by the redaction.
        try stage()
        _ = await world.cascade.deleteConversation(budget.id)
        #expect(!FileManager.default.fileExists(atPath: body.path))
        #expect(jobs.load(jobId: segmentId) != nil)

        // The whole segment: the job goes too, so a late outcome is dropped rather than saved
        // as the transcript of a recording that no longer exists.
        try stage()
        _ = await world.cascade.deleteConversation(dentist.id)
        #expect(!FileManager.default.fileExists(atPath: body.path))
        #expect(jobs.load(jobId: segmentId) == nil)
    }

    // MARK: - Whole segments, and the open one

    @Test func aWholeSegmentDeleteForgetsItsCutsAndItsRedactions() async throws {
        let world = try makeWorld()
        let fixture = world.fixture
        let (segmentId, _, budget) = try await twoConversationsInOneSegment(world)
        _ = await world.cascade.deleteConversation(budget.id)
        try await split(world, segmentId, at: 12_000)
        #expect(!fixture.transcriptStore.redactions(segmentId).isEmpty)

        // The retention path: the segment goes as a segment, whoever owned what.
        #expect(await world.cascade.deleteSegment(segmentId))

        #expect(try await world.cuts.overrides().isEmpty)
        #expect(try await world.cuts.committed().isEmpty)
        #expect(fixture.transcriptStore.redactions(segmentId).isEmpty)
        #expect(fixture.transcriptStore.load(segmentId) == nil)
    }

    @Test func aPieceOfTheOpenSegmentIsSkipped() async throws {
        let world = try makeWorld()
        let fixture = world.fixture
        _ = try await Fixture.writeSegment(into: fixture.store, close: false)
        let openId = try #require(await fixture.store.openSegmentId)
        let conversationId = try #require(try await fixture.enrichment.regroup().first?.id)
        let before = await fixture.store.readFrames(openId)

        #expect(await world.cascade.deleteConversation(conversationId).isEmpty)

        #expect(await fixture.store.readMeta(openId) != nil)
        #expect(await fixture.store.readFrames(openId) == before)
        #expect(fixture.transcriptStore.redactions(openId).isEmpty)
    }
}
