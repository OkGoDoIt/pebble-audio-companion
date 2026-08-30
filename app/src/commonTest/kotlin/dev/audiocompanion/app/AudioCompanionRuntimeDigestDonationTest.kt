package dev.audiocompanion.app

import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.ai.AiProvider
import dev.audiocompanion.ai.AiProviderResult
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.FileAiOutputStore
import dev.audiocompanion.ai.FileDailyDigestStore
import dev.audiocompanion.ai.FileSegmentAnnotationStore
import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.search.InMemoryTranscriptIndex
import dev.audiocompanion.search.IndexKind
import dev.audiocompanion.storage.FileReceiverResumeStore
import dev.audiocompanion.storage.FreeSpaceProvider
import dev.audiocompanion.storage.RetentionManager
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.transcription.FileTranscriptStore
import dev.audiocompanion.transcription.FileTranscriptionQueue
import dev.audiocompanion.transcription.RoutedTranscription
import dev.audiocompanion.transcription.TranscriptionMode
import dev.audiocompanion.transcription.TranscriptionModeRouter
import dev.audiocompanion.transcription.TranscriptionProcessor
import dev.audiocompanion.transport.AudioGattLink
import dev.audiocompanion.transport.ConnectFailure
import dev.audiocompanion.transport.LinkState
import dev.audiocompanion.transport.ReceiverConfig
import dev.audiocompanion.transport.SegmentCloseReason
import dev.audiocompanion.transport.SegmentFrame
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.datetime.TimeZone
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * End-to-end wiring check for daily-digest search donation: a saved digest must land in the
 * transcript index through the runtime's onDigestSaved callback (segments and action items have
 * their own donation paths; this one was historically unwired).
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class AudioCompanionRuntimeDigestDonationTest {

    private class FakeAiProvider : AiProvider {
        override val id: String = "fake"
        override suspend fun isAvailable(): Boolean = true
        override suspend fun run(request: AiRunRequest): AiProviderResult =
            AiProviderResult(text = "Digest of the day", modelUsed = "fake-model")
    }

    /** A link that never connects: the receiver session idles and never reads/streams. */
    private class IdleGattLink : AudioGattLink {
        override val connectionState: StateFlow<LinkState> = MutableStateFlow(LinkState.Disconnected)
        override val lastFailure: StateFlow<ConnectFailure?> = MutableStateFlow(null)
        override suspend fun readInfo(): ByteArray = ByteArray(0)
        override suspend fun writeControl(message: ByteArray) {}
        override val controlNotifications: Flow<ByteArray> = emptyFlow()
        override val dataNotifications: Flow<ByteArray> = emptyFlow()
    }

    @Test
    fun savedDailyDigestIsDonatedToTheTranscriptIndex() = runTest {
        val root = Path(SystemTemporaryDirectory, "runtime-digest-${Random.nextLong()}")
        SystemFileSystem.createDirectories(root)
        val clock = 1_756_500_000_000L
        val nowMs = { clock }
        val store = SegmentStore(SystemFileSystem, root, nowMs)

        // One closed, transcribed segment: exactly what the recap engine digests.
        store.openSegment(
            StreamStart(
                protocolVersion = 1,
                streamId = 7u,
                codecIdRaw = 1,
                channels = 1,
                frameSamples = 320,
                sampleRateHz = 16_000u,
                bitRateBps = 9_800u,
                frameDurationMs = 20,
                startTimeMs = clock.toULong(),
                startMonotonicMs = 1u,
                flags = 0u,
            ),
            receivedAtMs = clock,
            provenance = null,
        )
        val segmentId = store.openSegmentId!!
        store.appendFrames(
            7u,
            listOf(SegmentFrame(sequence = 0u, sampleIndex = 0u, payload = ByteArray(25))),
        )
        store.closeSegment(SegmentCloseReason.Interrupted)
        val transcriptStore = FileTranscriptStore(SystemFileSystem, root, nowMs)
        transcriptStore.save(
            segmentId,
            RoutedTranscription(
                text = "Talked about the launch.",
                modeUsed = TranscriptionMode.LocalOnly,
                providerId = "fake",
                modelUsed = null,
            ),
        )

        val queue = FileTranscriptionQueue(SystemFileSystem, root, nowMs)
        val index = InMemoryTranscriptIndex()
        val runtime = AudioCompanionRuntime(
            link = IdleGattLink(),
            store = store,
            retention = RetentionManager(
                store = store,
                freeSpace = object : FreeSpaceProvider {
                    override fun freeBytes(): Long = Long.MAX_VALUE
                },
                nowMs = nowMs,
            ),
            resumeStore = FileReceiverResumeStore(SystemFileSystem, root),
            transcriptionQueue = queue,
            transcriptionProcessor = TranscriptionProcessor(
                queue = queue,
                router = TranscriptionModeRouter(
                    local = null,
                    remote = null,
                    mode = { TranscriptionMode.LocalOnly },
                ),
                pcmSource = { emptyFlow() },
                transcriptStore = transcriptStore,
            ),
            transcriptStore = transcriptStore,
            aiOutputStore = FileAiOutputStore(SystemFileSystem, root, nowMs),
            annotationStore = FileSegmentAnnotationStore(SystemFileSystem, root, nowMs),
            receiverConfig = ReceiverConfig(
                receiverId = Random.nextBytes(32),
                receiverName = "test",
            ),
            nowMs = nowMs,
            aiRouter = AiModeRouter(local = FakeAiProvider(), remote = null) {
                AiProcessingMode.LocalOnly
            },
            digestStore = FileDailyDigestStore(SystemFileSystem, root, nowMs),
            transcriptIndexDonator = TranscriptIndexDonator(index = index),
        )

        // Backgrounded, the transcription pass stays receive-only; the recap engine's own loop
        // still runs, so the donation observed here comes through onDigestSaved alone.
        runtime.setForeground(false)
        runtime.start(backgroundScope)
        runCurrent()

        val hit = index.search("digest").single()
        assertEquals(IndexKind.DayDigest, hit.kind)
        val expectedDay = LogicalDay.keyFor(clock, TimeZone.currentSystemDefault())
        assertEquals("day-$expectedDay", hit.id)
    }
}
