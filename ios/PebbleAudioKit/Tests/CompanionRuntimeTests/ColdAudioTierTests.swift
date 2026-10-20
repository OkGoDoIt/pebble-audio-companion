import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import CompanionRuntime

/// iCloud Drive as the tier sees it, in a temp folder: moves are renames, an upload completes
/// when the test says so, an eviction keeps the bytes aside and a download puts them back.
final class FakeUbiquity: UbiquityFiles, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    var hasAccount = true
    var containerAvailable = true
    private var uploaded = Set<String>()
    private var evictedBytes: [String: Data] = [:]
    private var downloadsPending = Set<String>()
    var uploadErrors: [String: String] = [:]
    /// Downloads complete on the next `status` call unless this is false (then `completeDownloads`).
    var downloadsCompleteImmediately = true
    private(set) var evictions = 0

    init(root: URL) { self.root = root }

    func containerURL() -> URL? { containerAvailable ? root : nil }

    func moveIntoCloud(from local: URL, to cloud: URL) throws {
        try FileManager.default.moveItem(at: local, to: cloud)
    }

    func moveOutOfCloud(from cloud: URL, to local: URL) throws {
        let key = cloud.lastPathComponent
        let evicted = lock.withLock { evictedBytes[key] != nil }
        if evicted { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "not downloaded"]) }
        try FileManager.default.moveItem(at: cloud, to: local)
        lock.withLock { _ = uploaded.remove(key) }
    }

    func status(of url: URL) -> UbiquitousFileStatus {
        let key = url.lastPathComponent
        return lock.withLock {
            if downloadsPending.contains(key), downloadsCompleteImmediately {
                finishDownloadLocked(key, url: url)
            }
            let evicted = evictedBytes[key] != nil
            let onDisk = FileManager.default.fileExists(atPath: url.path)
            guard evicted || onDisk else { return .missing }
            return UbiquitousFileStatus(
                exists: true,
                isUploaded: uploaded.contains(key),
                isUploading: !uploaded.contains(key) && uploadErrors[key] == nil && !evicted,
                isDownloaded: !evicted,
                isDownloading: downloadsPending.contains(key),
                uploadError: uploadErrors[key])
        }
    }

    func evict(_ url: URL) throws {
        let key = url.lastPathComponent
        try lock.withLock {
            guard uploaded.contains(key) else {
                throw NSError(domain: "fake", code: 2, userInfo: [NSLocalizedDescriptionKey: "not uploaded"])
            }
            evictedBytes[key] = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            evictions += 1
        }
    }

    func startDownload(_ url: URL) throws {
        lock.withLock { _ = downloadsPending.insert(url.lastPathComponent) }
    }

    private func finishDownloadLocked(_ key: String, url: URL) {
        guard let bytes = evictedBytes[key] else { downloadsPending.remove(key); return }
        try? bytes.write(to: url)
        evictedBytes[key] = nil
        downloadsPending.remove(key)
    }

    func completeDownloads() {
        lock.withLock {
            for key in downloadsPending {
                finishDownloadLocked(key, url: root.appendingPathComponent(ColdAudioLocator.folder).appendingPathComponent(key))
            }
        }
    }

    func remove(_ url: URL) throws {
        let key = url.lastPathComponent
        lock.withLock {
            evictedBytes[key] = nil
            uploaded.remove(key)
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func contents(of directory: URL) -> [URL] {
        let onDisk = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let evicted = lock.withLock { evictedBytes.keys.map { directory.appendingPathComponent($0) } }
        return onDisk + evicted
    }

    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func completeUploads() {
        lock.withLock {
            let dir = root.appendingPathComponent(ColdAudioLocator.folder)
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                uploaded.insert(file.lastPathComponent)
            }
        }
    }

    func isEvicted(_ segmentId: String) -> Bool {
        lock.withLock { evictedBytes[segmentId + SegmentStore.logSuffix] != nil }
    }
}

/// A settable clock the store, the locator and the tier all read.
final class TierClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64
    init(_ now: Int64) { _now = now }
    var now: Int64 {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

@Suite struct ColdAudioTierTests {
    private let streamId: UInt32 = 0x5EED_C01D
    private static let day: Int64 = 86_400_000

    final class World {
        let root: URL
        let cloud: URL
        let store: SegmentStore
        let files: FakeUbiquity
        let locator: ColdAudioLocator
        let clock: TierClock
        let tier: ColdAudioTier
        let policyBox: PolicyBox

        final class PolicyBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = ColdStoragePolicy(enabled: true, minAgeMs: 60 * ColdAudioTierTests.day)
            var value: ColdStoragePolicy {
                get { lock.withLock { _value } }
                set { lock.withLock { _value = newValue } }
            }
        }

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cold-\(UUID().uuidString)", isDirectory: true)
            let cloud = root.appendingPathComponent("icloud", isDirectory: true)
            try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
            let clock = TierClock(1_791_000_000_000)
            let store = SegmentStore(root: root, nowMs: { clock.now })
            let files = FakeUbiquity(root: cloud)
            let locator = ColdAudioLocator(files: files, nowMs: { clock.now })
            let box = PolicyBox()
            self.root = root
            self.cloud = cloud
            self.clock = clock
            self.store = store
            self.files = files
            self.locator = locator
            self.policyBox = box
            self.tier = ColdAudioTier(
                store: store, files: files, locator: locator, policy: { box.value },
                nowMs: { clock.now }, sleep: { _ in })
        }

        func setPolicy(_ policy: ColdStoragePolicy) { policyBox.value = policy }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// A closed, transcribed segment recorded `ageDays` ago with `frames` frames.
        @discardableResult
        func segment(ageDays: Int64, frames: Int = 50, state: TranscriptionState = .complete) async throws -> String {
            let receivedAt = clock.now - ageDays * ColdAudioTierTests.day
            let start = StreamStart(
                protocolVersion: 1, streamId: 0x5EED_C01D, codecIdRaw: 1, channels: 1, frameSamples: 320,
                sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
                startTimeMs: UInt64(receivedAt), startMonotonicMs: 1, flags: 0)
            try await store.openSegment(start: start, receivedAtMs: receivedAt, provenance: nil)
            let id = await store.openSegmentId!
            let batch = (0..<frames).map { i in
                SegmentFrame(sequence: UInt32(i), sampleIndex: UInt64(i) * 320, payload: [UInt8](repeating: UInt8(i & 0xFF), count: 25))
            }
            _ = try await store.appendFrames(streamId: 0x5EED_C01D, frames: batch)
            try await store.closeSegment(reason: .stopped(reasonRaw: 0, finalSequence: UInt32(frames - 1), finalSampleIndex: 0))
            try await store.updateTranscriptionState(id, state)
            await store.setColdAudioLocator(locator)
            return id
        }

        func meta(_ id: String) async -> SegmentMeta { await store.readMeta(id)! }
    }

    @Test func onlyOldTranscribedAudioMovesAndStaysReadableWhileUploading() async throws {
        let w = try World()
        let old = try await w.segment(ageDays: 90)
        let young = try await w.segment(ageDays: 10)
        let untranscribed = try await w.segment(ageDays: 120, state: .pending)
        let before = await w.store.readFrames(old)
        #expect(before.count == 50)

        #expect(await w.tier.sweepIfDue())

        let moved = await w.meta(old).coldStorage
        #expect(moved != nil)
        #expect(moved?.state == ColdStorageMeta.stateUploading)
        let expectedBytes: Int64 = 50 * 39
        #expect(moved?.bytes == expectedBytes)
        #expect(await w.store.localLogExists(old) == false)
        #expect(await w.meta(young).coldStorage == nil)
        #expect(await w.meta(untranscribed).coldStorage == nil)
        // Moved, not yet uploaded: the bytes are in the container and readable through the store.
        #expect(await w.store.readFrames(old).count == 50)
        let summary = await w.tier.summary()
        #expect(summary.uploadingCount == 1)
        #expect(summary.inCloudCount == 0)
        #expect(summary.onPhoneCount == 3, "uploading audio is still on the phone")
        #expect(summary.available)
    }

    /// End to end on the shipped defaults (Keep audio 30 days, move at 2 months): turning the
    /// switch on must move audio that retention has not deleted yet. Before 2026-10-20 the
    /// policy asked for 60-day-old audio, and retention had deleted everything past 30 days.
    @Test func theDefaultSettingsMoveAudioBeforeKeepAudioDeletesIt() async throws {
        let w = try World()
        let settings = RuntimeSettingsSnapshot(coldStorageEnabled: true)
        w.setPolicy(settings.coldStoragePolicy)
        let keepDays = Int64(settings.retentionDays)
        let movable = try await w.segment(ageDays: keepDays - 5)
        let young = try await w.segment(ageDays: 3)

        #expect(await w.tier.sweepIfDue())

        #expect(await w.meta(movable).coldStorage != nil, "audio younger than Keep audio moved")
        #expect(await w.meta(young).coldStorage == nil)
    }

    @Test func aConfirmedUploadIsEvictedAndFetchBringsItBack() async throws {
        let w = try World()
        let old = try await w.segment(ageDays: 90)
        await w.tier.sweep()
        // Not uploaded yet: nothing is evicted however often the sweep runs.
        await w.tier.sweep()
        #expect(await w.meta(old).coldStorage?.isEvicted == false)

        w.files.completeUploads()
        #expect(await w.tier.sweep())
        #expect(await w.meta(old).coldStorage?.isEvicted == true)
        #expect(w.files.isEvicted(old))
        #expect(await w.store.readFrames(old).isEmpty, "evicted audio reads as nothing, never blocks")
        let summary = await w.tier.summary()
        #expect(summary.inCloudCount == 1)
        #expect(summary.inCloudBytes == 50 * 39)
        #expect(summary.onPhoneCount == 0)
        #expect(await w.tier.availability(segmentIds: [old]) == .inCloud)

        try await w.tier.fetch(segmentIds: [old])
        #expect(await w.store.readFrames(old).count == 50)
        #expect(await w.tier.availability(segmentIds: [old]) == .onPhone)
        #expect(await w.meta(old).coldStorage?.isEvicted == true, "a fetch does not change the record")

        // Still here an hour later; gone again after the keep window.
        w.clock.now += 60 * 60_000
        await w.tier.sweep()
        #expect(await w.store.readFrames(old).count == 50)
        w.clock.now += ColdAudioTier.refetchKeepMs
        await w.tier.sweep()
        #expect(await w.store.readFrames(old).isEmpty)
    }

    @Test func theRuleOffMovesNothingAndThePreviewSaysWhatWould() async throws {
        let w = try World()
        _ = try await w.segment(ageDays: 90, frames: 100)
        _ = try await w.segment(ageDays: 40, frames: 20)
        _ = try await w.segment(ageDays: 5, frames: 10)
        w.setPolicy(ColdStoragePolicy(enabled: false, minAgeMs: 60 * Self.day))

        #expect(await w.tier.sweepIfDue() == false)
        for meta in await w.store.listSegments() { #expect(meta.coldStorage == nil) }

        let twoMonths = await w.tier.eligible(minAgeMs: 60 * Self.day)
        #expect(twoMonths.count == 1)
        #expect(twoMonths.bytes == 100 * 39)
        let month = await w.tier.eligible(minAgeMs: 30 * Self.day)
        #expect(month.count == 2)
        #expect(month.bytes == 120 * 39)
    }

    @Test func aChangedRuleIsDueAtOnce() async throws {
        let w = try World()
        _ = try await w.segment(ageDays: 45)
        w.setPolicy(ColdStoragePolicy(enabled: true, minAgeMs: 60 * Self.day))
        #expect(await w.tier.sweepIfDue() == false)
        #expect(await w.tier.isDue == false)
        w.setPolicy(ColdStoragePolicy(enabled: true, minAgeMs: 30 * Self.day))
        #expect(await w.tier.isDue)
        #expect(await w.tier.sweepIfDue())
    }

    @Test func aMoveInterruptedAfterTheMarkIsFinishedByTheNextSweep() async throws {
        let w = try World()
        let old = try await w.segment(ageDays: 90)
        try await w.store.setColdStorage(old, ColdStorageMeta(movedAtMs: w.clock.now, bytes: 50 * 39))
        #expect(await w.store.localLogExists(old))
        #expect(await w.tier.sweep())
        #expect(await w.store.localLogExists(old) == false)
        #expect(await w.store.readFrames(old).count == 50)
    }

    @Test func deletingASegmentRemovesTheCloudCopy() async throws {
        let w = try World()
        let old = try await w.segment(ageDays: 90)
        await w.tier.sweep()
        w.files.completeUploads()
        await w.tier.sweep()
        let url = w.locator.coldLogURL(segmentId: old)!
        #expect(w.files.status(of: url).exists)
        try await w.store.deleteSegment(old)
        #expect(w.files.status(of: url).exists == false)
        #expect(await w.store.readMeta(old) == nil)
    }

    @Test func anOrphanedCloudCopyIsRemovedByTheSweep() async throws {
        let w = try World()
        _ = try await w.segment(ageDays: 90)
        let orphan = w.locator.coldDirectory()!.appendingPathComponent("seg-gone" + SegmentStore.logSuffix)
        try w.files.createDirectory(w.locator.coldDirectory()!)
        try Data(count: 39).write(to: orphan)
        await w.tier.sweep()
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
    }

    @Test func restoreBringsEverythingBackAndClearsTheMarks() async throws {
        let w = try World()
        let a = try await w.segment(ageDays: 90)
        let b = try await w.segment(ageDays: 120)
        await w.tier.sweep()
        w.files.completeUploads()
        await w.tier.sweep()
        #expect(await w.meta(a).coldStorage?.isEvicted == true)

        await w.tier.beginRestoreAll()
        #expect(await w.tier.summary().restoring == .init(done: 0, total: 2))
        // The first sweep starts the downloads and waits; the next finds them complete (the
        // fake finishes a download on the next look), moves the files home and clears the marks.
        #expect(await w.tier.sweep() == false)
        #expect(await w.tier.summary().restoring == .init(done: 0, total: 2))
        #expect(await w.tier.isDue, "a restore in progress is always due")
        #expect(await w.tier.sweep())
        #expect(await w.tier.summary().restoring == nil)
        for id in [a, b] {
            #expect(await w.meta(id).coldStorage == nil)
            #expect(await w.store.localLogExists(id))
            #expect(await w.store.readFrames(id).count == 50)
        }
        // With the rule still on, the next sweep would move them again: a restore is for
        // people who turned the rule off first, and the screen does that.
    }

    @Test func noAccountMeansNothingMovesAndTheStateIsNamed() async throws {
        let w = try World()
        let old = try await w.segment(ageDays: 90)
        w.files.hasAccount = false
        w.locator.invalidate()
        #expect(await w.tier.sweep() == false)
        #expect(await w.meta(old).coldStorage == nil)
        #expect(await w.tier.summary().available == false)
    }

    @Test func audioInCloudWithNoAccountIsUnreachableNotMissing() async throws {
        let w = try World()
        let old = try await w.segment(ageDays: 90)
        await w.tier.sweep()
        w.files.completeUploads()
        await w.tier.sweep()
        w.files.hasAccount = false
        w.locator.invalidate()
        #expect(await w.tier.availability(segmentIds: [old]) == .inCloudUnreachable)
        await #expect(throws: ColdAudioTier.FetchError.unreachable) {
            try await w.tier.fetch(segmentIds: [old])
        }
        // The record of the audio is untouched.
        let meta = await w.meta(old)
        #expect(meta.frameCount == 50)
        #expect(meta.coldStorage?.isEvicted == true)
    }

    @Test func anUploadErrorIsReportedAndNothingIsEvicted() async throws {
        let w = try World()
        let old = try await w.segment(ageDays: 90)
        await w.tier.sweep()
        w.files.uploadErrors[old + SegmentStore.logSuffix] = "quota exceeded"
        await w.tier.sweep()
        #expect(await w.meta(old).coldStorage?.isEvicted == false)
        #expect(await w.store.readFrames(old).count == 50)
        #expect(await w.tier.summary().lastError?.contains("quota exceeded") == true)
    }

    @Test func aRangeDeleteOnEvictedAudioSaysItMustBeFetchedFirst() async throws {
        let w = try World()
        let old = try await w.segment(ageDays: 90)
        await w.tier.sweep()
        w.files.completeUploads()
        await w.tier.sweep()
        let silence = [UInt8](repeating: 0, count: 25)
        await #expect(throws: SegmentStoreError.audioNotOnPhone(segmentId: old)) {
            try await w.store.silenceAudio(old, mediaRangeMs: 0..<200, silenceFrame: silence)
        }
        try await w.tier.fetch(segmentIds: [old])
        let silenced = try await w.store.silenceAudio(old, mediaRangeMs: 0..<200, silenceFrame: silence)
        #expect(silenced == 10)
        #expect(await w.store.readFrames(old).prefix(10).allSatisfy { $0.payload == silence })
    }

    @Test func recoveryKeepsAColdSegmentWholeAcrossARelaunch() async throws {
        let w = try World()
        let old = try await w.segment(ageDays: 90)
        await w.tier.sweep()
        w.files.completeUploads()
        await w.tier.sweep()
        let relaunched = SegmentStore(root: w.root, nowMs: { [clock = w.clock] in clock.now })
        try await relaunched.recover()
        let meta = try #require(await relaunched.readMeta(old))
        #expect(meta.coldStorage?.isEvicted == true)
        #expect(meta.frameCount == 50)
        #expect(meta.logBytes == 50 * 39)
    }
}
