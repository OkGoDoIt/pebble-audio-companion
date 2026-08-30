package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import java.io.File
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

private class ProcessorFakeProvider(
    override val id: String,
    var available: Boolean = true,
    var error: Throwable? = null,
) : TranscriptionProvider {
    override val status = MutableStateFlow(ProviderStatus.Ready)

    override suspend fun isAvailable(): Boolean = available

    override suspend fun transcribe(
        pcmChunks: Flow<ByteArray>,
        sampleRateHz: Int,
    ): TranscriptionResult {
        error?.let { throw it }
        return TranscriptionResult("hello", id, "model")
    }
}

class TranscriptionProcessorTest {
    private var clock = 5_000L

    private fun tempRoot(): Path {
        val dir = File.createTempFile("txprocessor", null).apply {
            delete()
            mkdirs()
        }
        dir.deleteOnExit()
        return Path(dir.absolutePath)
    }

    private fun queue(root: Path) = FileTranscriptionQueue(SystemFileSystem, root) { clock++ }

    @Test
    fun processNextCompletesQueuedSegment() = runTest {
        val root = tempRoot()
        val queue = queue(root)
        queue.enqueue("seg-1")
        val local = ProcessorFakeProvider("local")
        val processor = TranscriptionProcessor(
            queue = queue,
            router = TranscriptionModeRouter(local, null) { TranscriptionMode.LocalOnly },
            pcmSource = { flowOf(byteArrayOf(1, 2, 3, 4)) },
        )

        processor.processNext()

        val task = queue.load("seg-1")
        assertEquals(TaskState.Complete, task?.state)
        assertEquals(TranscriptionMode.LocalOnly, task?.modeUsed)
        assertEquals("local", task?.providerId)
    }

    @Test
    fun processNextPersistsTranscriptTextDurably() = runTest {
        val root = tempRoot()
        val queue = queue(root)
        queue.enqueue("seg-1")
        val transcripts = FileTranscriptStore(SystemFileSystem, root) { clock++ }
        val local = ProcessorFakeProvider("local")
        val processor = TranscriptionProcessor(
            queue = queue,
            router = TranscriptionModeRouter(local, null) { TranscriptionMode.LocalOnly },
            pcmSource = { flowOf(byteArrayOf(1, 2, 3, 4)) },
            transcriptStore = transcripts,
        )

        processor.processNext()

        val transcript = transcripts.load("seg-1")
        assertEquals("hello", transcript?.text)
        assertEquals(TranscriptionMode.LocalOnly, transcript?.modeUsed)
        assertEquals("local", transcript?.providerId)
        assertEquals("model", transcript?.modelUsed)
    }

    @Test
    fun processNextSkipsOpenSegmentAndLeavesTaskPending() = runTest {
        // A RESUME reattach can reopen a segment while its task waits; an open segment must not
        // be transcribed — the result would cover a stale prefix.
        val root = tempRoot()
        val queue = queue(root)
        queue.enqueue("seg-1")
        val processor = TranscriptionProcessor(
            queue = queue,
            router = TranscriptionModeRouter(ProcessorFakeProvider("local"), null) { TranscriptionMode.LocalOnly },
            pcmSource = { flowOf(byteArrayOf(1, 2, 3, 4)) },
            isSegmentOpen = { true },
        )

        assertEquals(null, processor.processNext())

        val task = queue.load("seg-1")
        assertEquals(TaskState.Pending, task?.state)
        assertEquals(0, task?.attempts)
    }

    @Test
    fun processNextDiscardsResultWhenSegmentReopensMidTranscription() = runTest {
        // The reattach can also land while transcription is running: the finished result must be
        // discarded (not saved, not marked Complete) and the task re-run after the final close.
        val root = tempRoot()
        val queue = queue(root)
        queue.enqueue("seg-1")
        val transcripts = FileTranscriptStore(SystemFileSystem, root) { clock++ }
        val openAnswers = ArrayDeque(listOf(false, true)) // closed at pick, reopened at commit
        val processor = TranscriptionProcessor(
            queue = queue,
            router = TranscriptionModeRouter(ProcessorFakeProvider("local"), null) { TranscriptionMode.LocalOnly },
            pcmSource = { flowOf(byteArrayOf(1, 2, 3, 4)) },
            transcriptStore = transcripts,
            isSegmentOpen = { openAnswers.removeFirstOrNull() ?: false },
        )

        processor.processNext()

        assertEquals(TaskState.Pending, queue.load("seg-1")?.state)
        assertEquals(null, transcripts.load("seg-1"), "a stale transcript must not be persisted")
    }

    @Test
    fun enqueueRequeuesTerminalSuccessTaskForReattachedSegment() = runTest {
        // enqueueClosedSegments only receives closed, not-fully-transcribed segments. One that
        // already carries a Complete/NoSpeech task is a reattached segment that grew after
        // transcription: it must re-run, while a Failed task keeps its normal backoff path.
        val root = tempRoot()
        val queue = queue(root)
        queue.enqueue("seg-1")
        val processor = TranscriptionProcessor(
            queue = queue,
            router = TranscriptionModeRouter(ProcessorFakeProvider("local"), null) { TranscriptionMode.LocalOnly },
            pcmSource = { flowOf(byteArrayOf(1, 2, 3, 4)) },
        )
        processor.processNext()
        assertEquals(TaskState.Complete, queue.load("seg-1")?.state)

        queue.enqueue("seg-2")
        queue.markFailed("seg-2", "boom", retryable = true)

        processor.enqueueClosedSegments(listOf("seg-1", "seg-2", "seg-3"))

        assertEquals(TaskState.Pending, queue.load("seg-1")?.state, "reattached segment must requeue")
        assertEquals(TaskState.Failed, queue.load("seg-2")?.state, "failed task keeps its backoff")
        assertEquals(TaskState.Pending, queue.load("seg-3")?.state, "new segment enqueues normally")
    }

    @Test
    fun noSpeechIsTerminal() = runTest {
        val root = tempRoot()
        val queue = queue(root)
        queue.enqueue("seg-1")
        val local = ProcessorFakeProvider(
            "local",
            error = TranscriptionException.NoSpeechDetected("silence"),
        )
        val processor = TranscriptionProcessor(
            queue = queue,
            router = TranscriptionModeRouter(local, null) { TranscriptionMode.LocalOnly },
            pcmSource = { flowOf(ByteArray(4)) },
        )

        processor.processNext()

        assertEquals(TaskState.NoSpeech, queue.load("seg-1")?.state)
    }

    @Test
    fun nonExceptionProviderThrowableIsRecordedAsFailedTask() = runTest {
        val root = tempRoot()
        val queue = queue(root)
        queue.enqueue("seg-1")
        val local = ProcessorFakeProvider(
            "local",
            error = AssertionError("native boundary failed"),
        )
        val processor = TranscriptionProcessor(
            queue = queue,
            router = TranscriptionModeRouter(local, null) { TranscriptionMode.LocalOnly },
            pcmSource = { flowOf(ByteArray(4)) },
        )

        processor.processNext()

        val task = queue.load("seg-1")
        assertEquals(TaskState.Failed, task?.state)
        assertEquals("native boundary failed", task?.lastError)
    }

    @Test
    fun cancellationStillPropagates() = runTest {
        val root = tempRoot()
        val queue = queue(root)
        queue.enqueue("seg-1")
        val local = ProcessorFakeProvider(
            "local",
            error = CancellationException("stopping"),
        )
        val processor = TranscriptionProcessor(
            queue = queue,
            router = TranscriptionModeRouter(local, null) { TranscriptionMode.LocalOnly },
            pcmSource = { flowOf(ByteArray(4)) },
        )

        assertFailsWith<CancellationException> {
            processor.processNext()
        }
    }

    @Test
    fun unavailableProvidersDisableTask() = runTest {
        val root = tempRoot()
        val queue = queue(root)
        queue.enqueue("seg-1")
        val processor = TranscriptionProcessor(
            queue = queue,
            router = TranscriptionModeRouter(null, null) { TranscriptionMode.LocalOnly },
            pcmSource = { flowOf(ByteArray(4)) },
        )

        processor.processNext()

        assertEquals(TaskState.Disabled, queue.load("seg-1")?.state)
    }
}
