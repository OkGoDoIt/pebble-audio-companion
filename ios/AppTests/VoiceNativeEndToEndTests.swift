import AppDB
import AudioCodec
import CryptoKit
import Foundation
import Receiver
import SegmentStore
import SpeakerRecognition
import Testing
import WireProtocol
import CompanionRuntime

private struct InstalledEvaluationVoiceModels: VoiceModelManaging {
    func state() async -> SpeakerModelInstallState { .installed }
    func isInstalled() async -> Bool { true }
    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        Issue.record("The evaluation must use already downloaded models")
    }
    func cancel() async {}
}

/// Explicit opt-in, offline integration check against the public labeled corpus prepared by
/// Tools/SpeakerEvaluation. Never uses the user's enrollment, recordings, keychain or database.
@Suite struct VoiceNativeEndToEndTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PEBBLE_VOICE_NATIVE_CORPUS"] != nil,
                   "Set PEBBLE_VOICE_NATIVE_CORPUS to the offline public corpus and model directory"))
    func confirmedPublicVoiceMatchesHeldOutSpeexAudioAndRejectsUnknownWithoutASR() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PEBBLE_VOICE_NATIVE_CORPUS"])
        let base = URL(fileURLWithPath: path, isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-voice-evaluation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase.inMemory()
        let files = SegmentFileReader(root: root)
        let segments = SegmentStore(root: root, nowMs: { Int64(Date().timeIntervalSince1970 * 1_000) })
        let analyzer = LocalSpeakerDiarizer(embeddingModelDirectory: base.appendingPathComponent("model"),
            segmentationModelDirectory: base.appendingPathComponent("Segmentation.mlmodelc"))
        let service = VoiceRecognitionService(database: db, files: files, models: InstalledEvaluationVoiceModels(),
            analyzer: analyzer, policy: VoiceRecognitionService.initialPolicy, recipeID: LocalSpeakerDiarizer.recipeID,
            protector: VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256)))
        let person = try await PeopleStore(db: db).createPerson(name: "Public speaker 6930")
        let enrollment = try Data(contentsOf: base.appendingPathComponent("public-corpus/6930-75918-0001.pcm"))
        let outcome = try await service.enrollPCM(personId: person.id, pcm16LE: enrollment,
            sessionID: "official-public-speaker-6930-chapter-75918")
        #expect(outcome.examplesAdded >= 2)
        let examples = try await service.examples()
        #expect(examples.allSatisfy { !String(decoding: $0.embeddingJSON, as: UTF8.self).contains("values") })
        try await service.setEnabled(true)

        let known = try await writeSpeex(try Data(contentsOf: base.appendingPathComponent(
            "public-corpus/6930-76324-0002.pcm")), stream: 10, to: segments)
        let unknown = try await writeSpeex(try Data(contentsOf: base.appendingPathComponent(
            "public-corpus/2094-142345-0000.pcm")), stream: 11, to: segments)
        // No transcript, ASR provider, credential or network service exists in this fixture.
        try await service.enqueueSegment(segmentId: known)
        try await service.enqueueSegment(segmentId: unknown)
        #expect(await service.processPending(maxWindows: 2))
        let identity = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: [known, unknown])
        let matched = identity.automaticAttributions.filter { $0.attribution.segmentId == known }
        #expect(!matched.isEmpty)
        #expect(matched.allSatisfy { $0.person.id == person.id })
        #expect(!identity.automaticAttributions.contains { $0.attribution.segmentId == unknown })
        // Automatic evidence is not a source of new training examples.
        #expect(try await service.examples().count == examples.count)

        let match = try #require(matched.first)
        try await SpeakerCorrectionStore(db: db).set(segmentId: known,
            startMediaMs: match.attribution.startMediaMs, endMediaMs: match.attribution.endMediaMs,
            personId: nil)
        try await service.undo(runId: match.attribution.runID)
        let after = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: [known])
        #expect(after.automaticAttributions.isEmpty)
        #expect(after.resolve(segmentId: known, startMediaMs: match.attribution.startMediaMs,
            endMediaMs: match.attribution.endMediaMs) == .unnamed)
        await service.release()
    }

    private func writeSpeex(_ pcm: Data, stream: UInt32, to store: SegmentStore) async throws -> String {
        let frameCount = pcm.count / 640
        let samples: [Int16] = pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stride(from: 0, to: frameCount * 640, by: 2).map { offset in
                Int16(bitPattern: UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8)
            }
        }
        let encoder = try SpeexFrameEncoder()
        var frames: [SegmentFrame] = []
        for index in 0..<frameCount {
            let payload = try encoder.encodeFrame(Array(samples[(index * 320)..<((index + 1) * 320)]))
            frames.append(SegmentFrame(sequence: UInt32(index), sampleIndex: UInt64(index * 320),
                                       payload: Array(payload)))
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await store.openSegment(start: StreamStart(protocolVersion: ProtocolConstants.protocolVersion,
            streamId: stream, codecIdRaw: CodecId.speexWideband.rawValue, channels: 1, frameSamples: 320,
            sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: UInt64(now), startMonotonicMs: 0, flags: 0), receivedAtMs: now, provenance: nil)
        _ = try await store.appendFrames(streamId: stream, frames: frames)
        let id = try #require(await store.openSegmentId)
        try await store.closeSegment(reason: .stopped(reasonRaw: Int(StopReason.shutdown.rawValue),
            finalSequence: UInt32(frameCount - 1), finalSampleIndex: UInt64(frameCount * 320)))
        return id
    }
}
