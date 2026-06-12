package dev.audiocompanion.app

import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.ai.AiProvider
import dev.audiocompanion.ai.AiProviderResult
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.FileSegmentAnnotationStore
import dev.audiocompanion.storage.CloseReasonMeta
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.storage.TranscriptionState
import dev.audiocompanion.transcription.SegmentTranscript
import dev.audiocompanion.transcription.TranscriptionMode
import kotlinx.coroutines.test.runTest
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

private class FakeAiProvider(
    var response: String = "TITLE: Team sync\nSUMMARY: Discussed the plan.",
    var error: Exception? = null,
) : AiProvider {
    override val id: String = "fake"
    var runCount = 0

    override suspend fun isAvailable(): Boolean = true

    override suspend fun run(request: AiRunRequest): AiProviderResult {
        runCount += 1
        error?.let { throw it }
        return AiProviderResult(text = response, modelUsed = "fake-model")
    }
}

class SegmentEnrichmentWorkerTest {
    private var clock = 50_000L

    private fun tempRoot(): Path {
        val dir = Path(SystemTemporaryDirectory, "enrich-${Random.nextLong().toString(16)}")
        SystemFileSystem.createDirectories(dir)
        return dir
    }

    private fun meta(
        segmentId: String,
        state: TranscriptionState = TranscriptionState.Complete,
        open: Boolean = false,
    ) = SegmentMeta(
        segmentId = segmentId,
        streamId = 1u,
        protocolVersion = 1,
        codecIdRaw = 1,
        channels = 1,
        frameSamples = 320,
        sampleRateHz = 16_000u,
        bitRateBps = 9_800u,
        frameDurationMs = 20,
        startTimeMs = 1_000uL,
        startMonotonicMs = 1uL,
        receivedAtMs = 1_000,
        transcriptionState = state,
        closeReason = if (open) null else CloseReasonMeta.Rotated,
    )

    private fun transcript(segmentId: String) = SegmentTranscript(
        segmentId = segmentId,
        text = "We agreed on the plan.",
        modeUsed = TranscriptionMode.LocalOnly,
        providerId = "local",
        createdAtMs = 0,
    )

    private fun worker(
        store: FileSegmentAnnotationStore,
        provider: FakeAiProvider?,
    ) = SegmentEnrichmentWorker(
        annotations = store,
        router = provider?.let { AiModeRouter(local = it, remote = null) { AiProcessingMode.LocalOnly } },
        nowMs = { clock++ },
    )

    @Test
    fun annotatesTranscribedSegments() = runTest {
        val store = FileSegmentAnnotationStore(SystemFileSystem, tempRoot()) { clock++ }
        val provider = FakeAiProvider()

        val annotated = worker(store, provider).enrich(listOf(meta("seg-1"))) { transcript(it) }

        assertEquals(listOf("seg-1"), annotated)
        val annotation = store.load("seg-1")
        assertEquals("Team sync", annotation?.title)
        assertEquals("Discussed the plan.", annotation?.summary)
        assertEquals(AiProcessingMode.LocalOnly, annotation?.modeUsed)
        assertEquals("fake", annotation?.providerId)
    }

    @Test
    fun skipsOpenUntranscribedAndAlreadyAnnotatedSegments() = runTest {
        val store = FileSegmentAnnotationStore(SystemFileSystem, tempRoot()) { clock++ }
        val provider = FakeAiProvider()
        val worker = worker(store, provider)

        worker.enrich(
            listOf(
                meta("seg-open", open = true),
                meta("seg-pending", state = TranscriptionState.Pending),
                meta("seg-nospeech", state = TranscriptionState.NoSpeech),
            ),
        ) { transcript(it) }
        assertEquals(0, provider.runCount)

        // Annotate once, then a second pass must not re-run the provider.
        worker.enrich(listOf(meta("seg-1"))) { transcript(it) }
        worker.enrich(listOf(meta("seg-1"))) { transcript(it) }
        assertEquals(1, provider.runCount)
    }

    @Test
    fun noRouterMeansNoAnnotationsAndNoErrors() = runTest {
        val store = FileSegmentAnnotationStore(SystemFileSystem, tempRoot()) { clock++ }

        val annotated = worker(store, null).enrich(listOf(meta("seg-1"))) { transcript(it) }

        assertTrue(annotated.isEmpty())
        assertNull(store.load("seg-1"))
    }

    @Test
    fun failuresAreBoundedToMaxAttempts() = runTest {
        val store = FileSegmentAnnotationStore(SystemFileSystem, tempRoot()) { clock++ }
        val provider = FakeAiProvider(error = IllegalStateException("provider down"))
        val worker = worker(store, provider)

        repeat(5) { worker.enrich(listOf(meta("seg-1"))) { transcript(it) } }

        assertEquals(SegmentEnrichmentWorker.MAX_ATTEMPTS, provider.runCount)
        val annotation = store.load("seg-1")
        assertEquals(SegmentEnrichmentWorker.MAX_ATTEMPTS, annotation?.attempts)
        assertEquals("provider down", annotation?.lastError)
        assertEquals(false, annotation?.hasContent)

        // Recovery: provider works again, the next pass overwrites the failure record... but
        // only if attempts allow; bounded retries are intentional, so it stays failed.
        provider.error = null
        worker.enrich(listOf(meta("seg-1"))) { transcript(it) }
        assertEquals(SegmentEnrichmentWorker.MAX_ATTEMPTS, provider.runCount)
    }
}
