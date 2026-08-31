import AppDB
import Foundation
import SegmentStore
import Transcription

@testable import Migration

// Shared fixtures for the migration tests: a synthetic legacy container (old-app-shaped
// spxlog + meta.json + transcript files), throwaway defaults suites, and a throwaway
// Keychain service (cleaned up per test).

let migrationTestEpochMs: Int64 = 1_781_000_000_000

func makeMigrationTempRoot(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Little-endian `{u32 seq, u64 sample_index, u16 len, u8 payload[len]}` records — the spxlog
/// format the old app wrote (same shape as `SegmentStore.recordHeaderBytes` parsing).
func frameLogData(
    firstSequence: UInt32, frameCount: Int, frameSamples: UInt64 = 320,
    firstSampleIndex: UInt64? = nil, payloadLen: Int = 25
) -> Data {
    var data = Data()
    let baseSample = firstSampleIndex ?? UInt64(firstSequence) * frameSamples
    for i in 0..<frameCount {
        let seq = firstSequence + UInt32(i)
        let sample = baseSample + UInt64(i) * frameSamples
        withUnsafeBytes(of: seq.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(payloadLen).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: (0..<payloadLen).map { UInt8((Int(seq) + $0) & 0xFF) })
    }
    return data
}

/// Builds an old-app-shaped closed SegmentMeta whose extents are consistent with
/// `frameLogData(firstSequence: firstSampleIndex/320, frameCount: frameCount, ...)`.
func makeLegacyMeta(
    id: String,
    streamId: UInt32 = 0x5EED_0001,
    startTimeMs: UInt64,
    receivedAtMs: Int64,
    firstSampleIndex: UInt64 = 0,
    frameCount: Int = 8,
    logBytes: Int64,
    closeKind: String = CloseReasonMeta.kindStopped,
    transcriptionState: TranscriptionState = .pending,
    recordedTimeZone: String? = nil
) -> SegmentMeta {
    let frameSamples: UInt64 = 320
    let firstSequence = UInt32(firstSampleIndex / frameSamples)
    return SegmentMeta(
        segmentId: id,
        streamId: streamId,
        protocolVersion: 1,
        codecIdRaw: 1,
        channels: 1,
        frameSamples: Int(frameSamples),
        sampleRateHz: 16_000,
        bitRateBps: 9_800,
        frameDurationMs: 20,
        startTimeMs: startTimeMs,
        startMonotonicMs: 66_000,
        receivedAtMs: receivedAtMs,
        firstSequence: firstSequence,
        lastSequence: firstSequence + UInt32(frameCount) - 1,
        firstSampleIndex: firstSampleIndex,
        lastSampleIndexExclusive: firstSampleIndex + UInt64(frameCount) * frameSamples,
        frameCount: Int64(frameCount),
        logBytes: logBytes,
        closeReason: CloseReasonMeta(kind: closeKind),
        closedAtMs: receivedAtMs + Int64(frameCount) * 20,
        transcriptionState: transcriptionState,
        recordedTimeZone: recordedTimeZone
    )
}

/// Writes a meta + matching spxlog pair into `root/segments/`, the way the old app left them.
/// Returns the meta actually written (logBytes filled from the generated log).
@discardableResult
func writeLegacySegment(
    root: URL,
    id: String,
    streamId: UInt32 = 0x5EED_0001,
    startTimeMs: UInt64,
    receivedAtMs: Int64,
    firstSampleIndex: UInt64 = 0,
    frameCount: Int = 8,
    closeKind: String = CloseReasonMeta.kindStopped,
    transcriptionState: TranscriptionState = .pending,
    recordedTimeZone: String? = nil
) throws -> SegmentMeta {
    let segmentsDir = root.appendingPathComponent("segments", isDirectory: true)
    try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
    let log = frameLogData(
        firstSequence: UInt32(firstSampleIndex / 320), frameCount: frameCount,
        firstSampleIndex: firstSampleIndex)
    let meta = makeLegacyMeta(
        id: id, streamId: streamId, startTimeMs: startTimeMs, receivedAtMs: receivedAtMs,
        firstSampleIndex: firstSampleIndex, frameCount: frameCount,
        logBytes: Int64(log.count), closeKind: closeKind,
        transcriptionState: transcriptionState, recordedTimeZone: recordedTimeZone)
    try log.write(to: segmentsDir.appendingPathComponent("\(id)\(SegmentStore.logSuffix)"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(meta).write(
        to: segmentsDir.appendingPathComponent("\(id)\(SegmentStore.metaSuffix)"))
    return meta
}

func writeLegacyTranscript(root: URL, segmentId: String, text: String = "hello world") throws {
    let dir =
        root
        .appendingPathComponent("transcription", isDirectory: true)
        .appendingPathComponent("transcripts", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let transcript = SegmentTranscript(
        segmentId: segmentId, text: text, modeUsed: .localFirst,
        providerId: "cactus-local", modelUsed: "parakeet-ctc-1.1b-int8:v1.14",
        createdAtMs: migrationTestEpochMs)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(transcript).write(
        to: dir.appendingPathComponent("\(segmentId)\(FileTranscriptStore.suffix)"))
}

/// Writes an ORPHAN frame log into `quarantine/` — audio whose sidecar was lost, exactly what
/// `SegmentStore.recover()` sweeps aside. `holeAfter` drops `holeFrames` frames partway through
/// so the recovery's hole detection has something to find.
@discardableResult
func writeQuarantinedLog(
    root: URL,
    id: String,
    firstSampleIndex: UInt64 = 0,
    frameCount: Int = 8,
    holeAfter: Int? = nil,
    holeFrames: Int = 0,
    payloadLen: Int = 25
) throws -> (data: Data, frames: Int) {
    let dir = root.appendingPathComponent("quarantine", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let frameSamples: UInt64 = 320
    let firstSequence = UInt32(firstSampleIndex / frameSamples)
    var data = Data()
    var written = 0
    var index = 0
    while written < frameCount {
        if let holeAfter, index == holeAfter { index += holeFrames }
        let sequence = firstSequence + UInt32(index)
        let sample = firstSampleIndex + UInt64(index) * frameSamples
        withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(payloadLen).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: (0..<payloadLen).map { UInt8((Int(sequence) + $0) & 0xFF) })
        index += 1
        written += 1
    }
    try data.write(to: dir.appendingPathComponent("\(id)\(SegmentStore.logSuffix)"))
    return (data, written)
}

func quarantineContents(root: URL) -> Set<String> {
    let dir = root.appendingPathComponent("quarantine", isDirectory: true)
    let entries =
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
        ?? []
    return Set(entries.map(\.lastPathComponent))
}

/// Writes one legacy `ai/outputs/<id>.ai.json` with only the fields the caller cares about, so
/// the "tolerate absent fields" contract is exercised by omission rather than by nulls.
func writeLegacyAiOutput(
    root: URL,
    outputId: String,
    promptTemplateId: String?,
    promptTitle: String? = nil,
    segmentIds: [String] = [],
    text: String,
    providerId: String? = "openai-chat",
    modelUsed: String? = "gpt-5.6-luna",
    createdAtMs: Int64? = migrationTestEpochMs
) throws {
    let dir =
        root
        .appendingPathComponent("ai", isDirectory: true)
        .appendingPathComponent("outputs", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var json: [String: Any] = ["outputId": outputId, "text": text, "segmentIds": segmentIds]
    if let promptTemplateId { json["promptTemplateId"] = promptTemplateId }
    if let promptTitle { json["promptTitle"] = promptTitle }
    if let providerId { json["providerId"] = providerId }
    if let modelUsed { json["modelUsed"] = modelUsed }
    if let createdAtMs { json["createdAtMs"] = createdAtMs }
    let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    try data.write(to: dir.appendingPathComponent("\(outputId).ai.json"))
}

func readMetaFile(root: URL, id: String) throws -> SegmentMeta {
    let url =
        root
        .appendingPathComponent("segments", isDirectory: true)
        .appendingPathComponent("\(id)\(SegmentStore.metaSuffix)")
    return try JSONDecoder().decode(SegmentMeta.self, from: Data(contentsOf: url))
}

/// One test's throwaway world: container root, in-memory DB, unique defaults suites, and a
/// unique Keychain service. Call `cleanup()` in a defer.
struct MigrationTestEnv {
    let root: URL
    let db: AppDatabase
    let oldSuite: String
    let newSuite: String
    let old: UserDefaults
    let new: UserDefaults
    let keychain: MigrationKeychain
    let now: Int64 = migrationTestEpochMs + 86_400_000

    init() throws {
        root = try makeMigrationTempRoot("migration")
        db = try AppDatabase.inMemory()
        let token = UUID().uuidString
        oldSuite = "dev.audiocompanion.migtest.old.\(token)"
        newSuite = "dev.audiocompanion.migtest.new.\(token)"
        old = UserDefaults(suiteName: oldSuite)!
        new = UserDefaults(suiteName: newSuite)!
        keychain = MigrationKeychain(service: "dev.audiocompanion.migtest.\(token)")
    }

    /// Where the importer's recovered-audio WAV exports land. Inside the throwaway root, so a
    /// test run never touches the developer's real Documents folder.
    var documentsRoot: URL { root.appendingPathComponent("Documents", isDirectory: true) }

    func importer(timeZoneID: String = "America/New_York") -> LegacyImporter {
        LegacyImporter(
            containerRoot: root, database: db, documentsRoot: documentsRoot, oldDefaults: old,
            newDefaults: new, keychain: keychain, timeZoneID: timeZoneID, nowMs: { [now] in now })
    }

    func cleanup() {
        UserDefaults().removePersistentDomain(forName: oldSuite)
        UserDefaults().removePersistentDomain(forName: newSuite)
        for key in MigrationKeychain.Key.allCases { keychain.remove(key) }
        try? FileManager.default.removeItem(at: root)
    }
}

/// 64 lowercase hex chars (32 bytes) — a valid old receiver id.
func testReceiverId(_ fill: String = "ab") -> String {
    String(repeating: fill, count: 32)
}

/// Snapshot of every file under `dir` (recursive) for byte-identity assertions. Keys are
/// paths relative to `dir` (symlinks resolved — /var vs /private/var on macOS).
func fileSnapshot(_ dir: URL) throws -> [String: Data] {
    var out: [String: Data] = [:]
    let base = dir.resolvingSymlinksInPath().path
    guard
        let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey])
    else { return out }
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == true {
            let path = url.resolvingSymlinksInPath().path
            out[path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path] =
                try Data(contentsOf: url)
        }
    }
    return out
}
