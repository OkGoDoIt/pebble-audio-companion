import CompanionRuntime
import Foundation
import SegmentStore
import Testing
import Transcription

// The background-upload path, wired the way the app wires it (`BackgroundUploadWiring`), driven
// through the real runtime lifecycle.
//
// The gating suite is the important one: it is the only thing standing between a user who chose
// on-device transcription and their audio being uploaded to a cloud provider while they are not
// looking. It asserts the negative case per mode, not just the happy path.

@Suite struct BackgroundUploadWiringTests {

    /// A closed segment with a Pending queue task — the exact shape the hand-off looks for.
    private func pendingSegment(_ fixture: RuntimeFixture, streamId: UInt32 = 0x5EED_0001)
        async throws -> String
    {
        let segmentId = try await Fixture.writeSegment(into: fixture.store, streamId: streamId)
        try fixture.queue.enqueue(segmentId)
        return segmentId
    }

    // MARK: - Cloud-primary gating

    @Test(arguments: [TranscriptionMode.remoteOnly, .remoteFirst])
    func cloudPrimaryModesHandPendingSegmentsToTheUploader(mode: TranscriptionMode) async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(captureIntent: .active, transcriptionMode: mode),
            withBackgroundUploads: true
        )
        let segmentId = try await pendingSegment(fixture)

        await fixture.runtime.setForeground(false)

        #expect(
            fixture.uploads.uploadedSegmentIds == [segmentId],
            "\(mode) is cloud-primary: backgrounding must hand pending audio to the uploader"
        )
        #expect(try fixture.queue.load(segmentId)?.state == .uploading)
    }

    @Test(arguments: [TranscriptionMode.localOnly, .localFirst])
    func localPrimaryModesNeverUploadAudioInTheBackground(mode: TranscriptionMode) async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(captureIntent: .active, transcriptionMode: mode),
            withBackgroundUploads: true
        )
        let segmentId = try await pendingSegment(fixture)

        await fixture.runtime.setForeground(false)
        // The BGProcessing maintenance window offers the same hand-off — it must refuse too.
        await fixture.runtime.runBackgroundMaintenance()

        #expect(
            fixture.uploads.enqueued.isEmpty,
            "\(mode) keeps transcription on device: no audio may be uploaded from the background"
        )
        #expect(try fixture.queue.load(segmentId)?.state == .pending)
    }

    @Test func aModeChangeToLocalStopsFurtherUploadsImmediately() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, transcriptionMode: .remoteFirst
            ),
            withBackgroundUploads: true
        )
        _ = try await pendingSegment(fixture)
        await fixture.runtime.setForeground(false)
        #expect(fixture.uploads.enqueued.count == 1)

        // A second segment arrives after the user switches to on-device transcription.
        fixture.settings.apply { $0.transcriptionMode = .localOnly }
        _ = try await pendingSegment(fixture, streamId: 0x5EED_0002)
        await fixture.runtime.runBackgroundMaintenance()

        #expect(fixture.uploads.enqueued.count == 1, "the gate is re-read on every hand-off")
    }

    @Test func segmentsWithoutReadableAudioAreSkippedRatherThanUploadedEmpty() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, transcriptionMode: .remoteOnly
            ),
            withBackgroundUploads: true,
            segmentAudio: { _ in nil }
        )
        let segmentId = try await pendingSegment(fixture)

        await fixture.runtime.setForeground(false)

        #expect(fixture.uploads.enqueued.isEmpty)
        #expect(try fixture.queue.load(segmentId)?.state == .pending)
    }

    // MARK: - Hand-off, completion and observability

    @Test func aFinishedUploadSavesTheTranscriptAsRemoteOnlyAndClearsTheQueue() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, transcriptionMode: .remoteFirst
            ),
            withBackgroundUploads: true
        )
        let segmentId = try await pendingSegment(fixture)
        await fixture.transcription.startUploader()
        await fixture.runtime.setForeground(false)

        fixture.uploads.deliver(
            CloudUploadOutcome(jobId: segmentId, httpStatus: 200, responseBody: "from the cloud")
        )
        #expect(
            await waitUntil { (try? fixture.queue.load(segmentId))??.state == .complete },
            "the delivered outcome must complete the task"
        )

        let transcript = fixture.transcriptStore.load(segmentId)
        #expect(transcript?.text == "from the cloud")
        // Provenance is honest: a background upload is always the remote path, whatever the
        // configured mode was.
        #expect(transcript?.modeUsed == .remoteOnly)
        // The segment's own metadata is mirrored, so the next pass does not requeue it.
        #expect(await fixture.store.readMeta(segmentId)?.transcriptionState == .complete)
        await fixture.transcription.stopUploader()
    }

    @Test func uploadingWorkIsCountedByDiagnosticsRatherThanLookingStalled() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, transcriptionMode: .remoteOnly
            ),
            withBackgroundUploads: true
        )
        let segmentId = try await pendingSegment(fixture)

        await fixture.runtime.setForeground(false)
        let diagnostics = await fixture.diagnostics.refresh()

        #expect(try fixture.queue.load(segmentId)?.state == .uploading)
        #expect(
            diagnostics.queuedTranscriptionTasks == 1,
            "an in-flight upload is still queued work — the Diagnostics row must not read 0"
        )
        #expect(diagnostics.failedTranscriptionTasks == 0)
    }

    @Test func aFailedUploadSurfacesInTheDiagnosticsLogAndStaysRetryable() async throws {
        let log = LogRecorder()
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, transcriptionMode: .remoteOnly
            ),
            withBackgroundUploads: true
        )
        let segmentId = try await pendingSegment(fixture)
        // Drive the hooks directly with the app's log so the failure path is observable.
        let hooks = BackgroundUploadWiring.queueHooks(
            queue: fixture.queue,
            transcripts: fixture.transcriptStore,
            store: fixture.store,
            log: RuntimeLog { log.record($0) }
        )
        await hooks.markUploading(segmentId)
        await hooks.markFailed(segmentId, "connection lost", true)

        #expect(try fixture.queue.load(segmentId)?.state == .failed)
        #expect(try fixture.queue.load(segmentId)?.retryable == true)
        #expect(
            log.lines.contains { $0.contains(segmentId) && $0.contains("connection lost") },
            "a background failure the user cannot see anywhere else must reach the log; got \(log.lines)"
        )
    }

    // MARK: - Relaunch reconciliation

    @Test func relaunchReconcilesAbandonedUploadsBackToPending() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, transcriptionMode: .remoteOnly
            ),
            withBackgroundUploads: true
        )
        let segmentId = try await pendingSegment(fixture)
        // A previous process handed it to the transport and died; the transport does not have it.
        try fixture.queue.markUploading(segmentId)
        try await fixture.store.updateTranscriptionState(segmentId, .uploading)

        await fixture.transcription.startUploader()

        #expect(
            await waitUntil { (try? fixture.queue.load(segmentId))??.state == .pending },
            "an upload the transport forgot must go back to Pending, not sit Uploading forever"
        )
        #expect(await fixture.store.readMeta(segmentId)?.transcriptionState == .pending)
        #expect(fixture.uploads.reconcileCount >= 1)
        await fixture.transcription.stopUploader()
    }

    @Test func stillInFlightUploadsSurviveRelaunchUntouched() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, transcriptionMode: .remoteOnly
            ),
            withBackgroundUploads: true
        )
        let segmentId = try await pendingSegment(fixture)
        try fixture.queue.markUploading(segmentId)
        // The OS kept uploading while we were dead.
        await fixture.uploads.enqueue(
            CloudUploadRequest(jobId: segmentId, url: "https://fake.invalid", bodyFilePath: "/x")
        )

        await fixture.runtime.handleBackgroundUploadEvents()
        await TestClock.settle()

        #expect(try fixture.queue.load(segmentId)?.state == .uploading)
        #expect(fixture.uploads.reconcileCount >= 1)
    }

    @Test func backgroundUrlSessionEventsReconnectTheUploader() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, transcriptionMode: .remoteOnly
            ),
            withBackgroundUploads: true
        )
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)

        await coordinator.handle(.backgroundUrlSessionEvents)

        #expect(fixture.uploads.reconcileCount >= 1)
    }

    // MARK: - Session identity (plan 4.8)

    @Test func theBackgroundSessionIdentifierIsNotTheOldKmpApps() {
        // A migrated install inherits the old container; sharing the identifier would adopt the
        // dead app's queued upload tasks.
        #expect(
            BackgroundUploadWiring.sessionIdentifier
                != "dev.audiocompanion.app.transcription-upload"
        )
        // The app and the transport must agree, or handleEventsForBackgroundURLSession is routed
        // to nobody.
        #expect(
            BackgroundUploadWiring.sessionIdentifier
                == URLSessionBackgroundUploader.sessionIdentifier
        )
    }
}

/// Collects `RuntimeLog` lines.
final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []

    var lines: [String] { lock.withLock { _lines } }
    func record(_ line: String) { lock.withLock { _lines.append(line) } }
}
