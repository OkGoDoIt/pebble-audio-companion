package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class BackgroundCloudUploadCoordinatorTest {

    private class FakeUploader : BackgroundUploader {
        val enqueued = mutableListOf<CloudUploadRequest>()
        private val _outcomes = MutableSharedFlow<CloudUploadOutcome>(extraBufferCapacity = 16)
        override val outcomes: Flow<CloudUploadOutcome> = _outcomes
        private val inFlight = mutableSetOf<String>()
        override suspend fun enqueue(request: CloudUploadRequest) {
            enqueued += request
            inFlight += request.jobId
        }
        override suspend fun reconcile() {}
        override suspend fun inFlightJobIds(): Set<String> = inFlight.toSet()
        suspend fun deliver(outcome: CloudUploadOutcome) {
            inFlight -= outcome.jobId
            _outcomes.emit(outcome)
        }
    }

    private class FakeOpenAi : TranscriptionProvider, CloudUploadCapable {
        override val id = "openai"
        override val status = MutableStateFlow(ProviderStatus.Ready)
        override suspend fun isAvailable() = true
        override suspend fun transcribe(pcmChunks: Flow<ByteArray>, sampleRateHz: Int) =
            error("not used")
        override suspend fun uploadPlan(wav: ByteArray, sampleRateHz: Int) = CloudUploadPlan(
            url = "https://openai/transcriptions",
            file = MultipartBody.FilePart("file", "s.wav", "audio/wav", wav),
        )
        override suspend fun onUploadResponse(httpStatus: Int, body: String) =
            CloudUploadStep.Done(TranscriptionResult(text = body, providerId = id, modelUsed = "m"))
        override suspend fun completeControlPlane(controlState: String) = error("no control plane")
    }

    private class FakeSoniox : TranscriptionProvider, CloudUploadCapable {
        override val id = "soniox"
        override val status = MutableStateFlow(ProviderStatus.Ready)
        override suspend fun isAvailable() = true
        override suspend fun transcribe(pcmChunks: Flow<ByteArray>, sampleRateHz: Int) =
            error("not used")
        override suspend fun uploadPlan(wav: ByteArray, sampleRateHz: Int) = CloudUploadPlan(
            url = "https://soniox/files",
            file = MultipartBody.FilePart("file", "s.wav", "audio/wav", wav),
        )
        override suspend fun onUploadResponse(httpStatus: Int, body: String) =
            CloudUploadStep.NeedsControlPlane("file-123")
        override suspend fun completeControlPlane(controlState: String) =
            TranscriptionResult(text = "soniox $controlState", providerId = id, modelUsed = "m")
    }

    private class Fixture(provider: CloudProvider) {
        val root = Path(SystemTemporaryDirectory, "upload-coord-${Random.nextLong()}")
        val nowMs = { 1L }
        val queue = FileTranscriptionQueue(SystemFileSystem, root, nowMs)
        val transcriptStore = FileTranscriptStore(SystemFileSystem, root, nowMs)
        val jobStore = CloudUploadJobStore(SystemFileSystem, root)
        val uploader = FakeUploader()
        val cloud = SelectableCloudTranscriptionProvider(
            selected = { provider },
            openAi = FakeOpenAi(),
            soniox = FakeSoniox(),
        )
        val coordinator = BackgroundCloudUploadCoordinator(
            uploader = uploader,
            cloudProvider = cloud,
            jobStore = jobStore,
            queue = queue,
            transcriptStore = transcriptStore,
            audioSource = { SegmentAudio(ByteArray(64) { 1 }, 16_000) },
            onStateChanged = { _, _ -> },
            fileSystem = SystemFileSystem,
            bodyDir = Path(root, "bodies"),
            nowMs = nowMs,
            cloudPrimary = { true },
        )
    }

    @Test
    fun openAiSingleShotUploadCompletesTranscript() = runTest {
        val f = Fixture(CloudProvider.OpenAi)
        f.queue.enqueue("seg1")
        f.coordinator.start(backgroundScope)
        runCurrent()

        f.coordinator.submitPending()
        assertEquals(TaskState.Uploading, f.queue.load("seg1")?.state)
        assertEquals(1, f.uploader.enqueued.size)
        assertTrue(SystemFileSystem.exists(Path(f.uploader.enqueued.first().bodyFilePath)))

        f.uploader.deliver(CloudUploadOutcome("seg1", httpStatus = 200, responseBody = "hello cloud"))
        runCurrent()

        assertEquals(TaskState.Complete, f.queue.load("seg1")?.state)
        assertEquals("hello cloud", f.transcriptStore.load("seg1")?.text)
        assertNull(f.jobStore.load("seg1"))
        assertTrue(!SystemFileSystem.exists(Path(f.uploader.enqueued.first().bodyFilePath)))
    }

    @Test
    fun sonioxUploadThenControlPlaneCompletesTranscript() = runTest {
        val f = Fixture(CloudProvider.Soniox)
        f.queue.enqueue("seg2")
        f.coordinator.start(backgroundScope)
        runCurrent()

        f.coordinator.submitPending()
        f.uploader.deliver(CloudUploadOutcome("seg2", httpStatus = 201, responseBody = """{"id":"file-123"}"""))
        runCurrent()

        assertEquals(TaskState.Complete, f.queue.load("seg2")?.state)
        assertEquals("soniox file-123", f.transcriptStore.load("seg2")?.text)
        assertNull(f.jobStore.load("seg2"))
    }

    @Test
    fun failedUploadMarksTaskFailedRetryable() = runTest {
        val f = Fixture(CloudProvider.OpenAi)
        f.queue.enqueue("seg3")
        f.coordinator.start(backgroundScope)
        runCurrent()

        f.coordinator.submitPending()
        f.uploader.deliver(CloudUploadOutcome("seg3", httpStatus = 0, error = "network lost"))
        runCurrent()

        val task = f.queue.load("seg3")
        assertEquals(TaskState.Failed, task?.state)
        assertEquals(true, task?.retryable)
        assertNull(f.jobStore.load("seg3"))
    }
}
