package dev.audiocompanion.app

import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.ai.AiProvider
import dev.audiocompanion.ai.AiProviderResult
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.FileDailyDigestStore
import dev.audiocompanion.storage.CloseReasonMeta
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.storage.TranscriptionState
import kotlinx.coroutines.test.runTest
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toInstant
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private class RecordingAiProvider : AiProvider {
    override val id: String = "fake"
    val requests = mutableListOf<AiRunRequest>()

    override suspend fun isAvailable(): Boolean = true

    override suspend fun run(request: AiRunRequest): AiProviderResult {
        requests += request
        return AiProviderResult(text = "Recap ${requests.size}", modelUsed = "fake-model")
    }
}

class DailyRecapEngineTest {
    private val timeZone = TimeZone.UTC
    private var clock = atUtc(2026, 8, 29, 12, 0)
    private val segments = mutableListOf<SegmentMeta>()
    private val transcripts = mutableMapOf<String, String>()

    private fun atUtc(year: Int, month: Int, day: Int, hour: Int, minute: Int): Long =
        LocalDateTime(year, month, day, hour, minute)
            .toInstant(TimeZone.UTC)
            .toEpochMilliseconds()

    private fun tempStore(): FileDailyDigestStore {
        val dir = Path(SystemTemporaryDirectory, "recap-${Random.nextLong().toString(16)}")
        SystemFileSystem.createDirectories(dir)
        return FileDailyDigestStore(SystemFileSystem, dir) { clock }
    }

    private fun addSegment(segmentId: String, startMs: Long, text: String?) {
        segments += SegmentMeta(
            segmentId = segmentId,
            streamId = 1u,
            protocolVersion = 1,
            codecIdRaw = 1,
            channels = 1,
            frameSamples = 320,
            sampleRateHz = 16_000u,
            bitRateBps = 9_800u,
            frameDurationMs = 20,
            startTimeMs = startMs.toULong(),
            startMonotonicMs = 1uL,
            receivedAtMs = startMs,
            transcriptionState = if (text != null) {
                TranscriptionState.Complete
            } else {
                TranscriptionState.Pending
            },
            closeReason = CloseReasonMeta.Rotated,
        )
        if (text != null) transcripts[segmentId] = text
    }

    private fun engine(
        store: FileDailyDigestStore,
        provider: RecordingAiProvider,
        onDigestSaved: () -> Unit = {},
    ) = DailyRecapEngine(
        listSegments = { segments.toList() },
        transcriptTextOf = { transcripts[it] },
        digestStore = store,
        aiRouter = AiModeRouter(local = provider, remote = null) { AiProcessingMode.LocalOnly },
        onDigestSaved = onDigestSaved,
        timeZone = timeZone,
        nowMs = { clock },
    )

    @Test
    fun logicalDayRollsOverAtFiveAm() {
        assertEquals("2026-08-29", LogicalDay.keyFor(atUtc(2026, 8, 30, 4, 59), timeZone))
        assertEquals("2026-08-30", LogicalDay.keyFor(atUtc(2026, 8, 30, 5, 0), timeZone))
        assertEquals("2026-08-29", LogicalDay.keyFor(atUtc(2026, 8, 29, 23, 59), timeZone))
    }

    @Test
    fun groupsPostMidnightSegmentsIntoPreviousLogicalDay() = runTest {
        val store = tempStore()
        val provider = RecordingAiProvider()
        addSegment("seg-evening", atUtc(2026, 8, 29, 21, 0), "Talked about the trip.")
        addSegment("seg-night", atUtc(2026, 8, 30, 1, 30), "Late movie discussion.")
        clock = atUtc(2026, 8, 30, 2, 0)

        engine(store, provider).refreshDigests()

        assertEquals(1, provider.requests.size)
        val digest = store.load("2026-08-29")
        assertNotNull(digest)
        assertEquals(listOf("seg-evening", "seg-night"), digest.segmentIds)
        assertNull(store.load("2026-08-30"))
        val excerpts = provider.requests.single().transcripts
        assertEquals(listOf("seg-evening", "seg-night"), excerpts.map { it.segmentId })
        assertEquals("2026-08-29 21:00", excerpts.first().timeLabel)
    }

    @Test
    fun refreshesWhenNewTranscriptArrivesAfterDebounce() = runTest {
        val store = tempStore()
        val provider = RecordingAiProvider()
        var saves = 0
        val engine = engine(store, provider) { saves += 1 }
        addSegment("seg-1", atUtc(2026, 8, 29, 9, 0), "Morning standup.")
        clock = atUtc(2026, 8, 29, 9, 30)
        engine.refreshDigests()
        assertEquals(1, provider.requests.size)
        assertEquals(1, saves)
        val firstCreatedAt = clock

        // A new transcript inside the half-hour debounce window does not rerun the AI yet.
        addSegment("seg-2", atUtc(2026, 8, 29, 9, 40), "Coffee chat.")
        clock = firstCreatedAt + 10 * 60 * 1000L
        engine.refreshDigests()
        assertEquals(1, provider.requests.size)

        // Once the debounce expires the digest regenerates and covers both segments.
        clock = firstCreatedAt + 31 * 60 * 1000L
        engine.refreshDigests()
        assertEquals(2, provider.requests.size)
        assertEquals(2, saves)
        assertEquals(listOf("seg-1", "seg-2"), store.load("2026-08-29")?.segmentIds)
        assertEquals("Recap 2", store.load("2026-08-29")?.text)
    }

    @Test
    fun doesNotRegenerateWithoutNewContent() = runTest {
        val store = tempStore()
        val provider = RecordingAiProvider()
        val engine = engine(store, provider)
        addSegment("seg-1", atUtc(2026, 8, 29, 9, 0), "Morning standup.")
        engine.refreshDigests()
        assertEquals(1, provider.requests.size)

        clock += 2 * 60 * 60 * 1000L
        engine.refreshDigests()
        assertEquals(1, provider.requests.size)

        // A pending (untranscribed) segment is not new content either.
        addSegment("seg-2", atUtc(2026, 8, 29, 11, 0), text = null)
        clock += 60 * 60 * 1000L
        engine.refreshDigests()
        assertEquals(1, provider.requests.size)
    }

    @Test
    fun retentionDeletedSegmentsDoNotChurnTheDigest() = runTest {
        val store = tempStore()
        val provider = RecordingAiProvider()
        val engine = engine(store, provider)
        addSegment("seg-1", atUtc(2026, 8, 29, 9, 0), "Morning standup.")
        addSegment("seg-2", atUtc(2026, 8, 29, 10, 0), "Planning session.")
        engine.refreshDigests()
        assertEquals(1, provider.requests.size)

        segments.removeAll { it.segmentId == "seg-1" }
        clock += 2 * 60 * 60 * 1000L
        engine.refreshDigests()
        assertEquals(1, provider.requests.size)
        assertEquals(listOf("seg-1", "seg-2"), store.load("2026-08-29")?.segmentIds)
    }

    @Test
    fun eachLogicalDayGetsItsOwnDigestNewestFirst() = runTest {
        val store = tempStore()
        val provider = RecordingAiProvider()
        addSegment("seg-old", atUtc(2026, 8, 28, 14, 0), "Older meeting.")
        addSegment("seg-new", atUtc(2026, 8, 29, 9, 0), "Newer meeting.")
        clock = atUtc(2026, 8, 29, 10, 0)

        engine(store, provider).refreshDigests()

        assertEquals(2, provider.requests.size)
        // The current logical day is generated first: it backs the visible Today recap.
        assertTrue(provider.requests[0].transcripts.single().segmentId == "seg-new")
        assertNotNull(store.load("2026-08-28"))
        assertNotNull(store.load("2026-08-29"))
    }
}
