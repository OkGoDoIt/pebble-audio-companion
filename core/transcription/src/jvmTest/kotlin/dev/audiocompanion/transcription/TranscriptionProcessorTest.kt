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
