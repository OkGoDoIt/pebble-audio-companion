package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private class FakeProvider(
    override val id: String,
    var available: Boolean = true,
    var error: Throwable? = null,
) : TranscriptionProvider {
    override val status: StateFlow<ProviderStatus> = MutableStateFlow(ProviderStatus.Ready)
    var calls = 0

    override suspend fun isAvailable(): Boolean = available

    override suspend fun transcribe(pcmChunks: Flow<ByteArray>, sampleRateHz: Int): TranscriptionResult {
        calls++
        error?.let { throw it }
        return TranscriptionResult(text = "text-$id", providerId = id, modelUsed = "model-$id")
    }
}

class TranscriptionModeRouterTest {

    private val pcm = flowOf(ByteArray(320))

    private fun router(
        local: FakeProvider?,
        remote: FakeProvider?,
        mode: TranscriptionMode,
    ) = TranscriptionModeRouter(local, remote, { mode })

    @Test
    fun localOnly_usesLocal_neverRemote() = runTest {
        val local = FakeProvider("local")
        val remote = FakeProvider("remote")
        val result = router(local, remote, TranscriptionMode.LocalOnly).transcribe(pcm, 16000)
        assertEquals(TranscriptionMode.LocalOnly, result.modeUsed)
        assertEquals("local", result.providerId)
        assertEquals("model-local", result.modelUsed)
        assertEquals(0, remote.calls)
    }

    @Test
    fun localOnly_unavailable_throwsWithoutFallback() = runTest {
        val local = FakeProvider("local", available = false)
        val remote = FakeProvider("remote")
        assertFailsWith<TranscriptionException.ProviderUnavailable> {
            router(local, remote, TranscriptionMode.LocalOnly).transcribe(pcm, 16000)
        }
        assertEquals(0, remote.calls)
    }

    @Test
    fun remoteOnly_failure_doesNotFallBackToLocal() = runTest {
        val local = FakeProvider("local")
        val remote = FakeProvider("remote", error = TranscriptionException.TranscriptionFailed("boom"))
        assertFailsWith<TranscriptionException.TranscriptionFailed> {
            router(local, remote, TranscriptionMode.RemoteOnly).transcribe(pcm, 16000)
        }
        assertEquals(0, local.calls)
    }

    @Test
    fun localFirst_primarySuccess_keepsConfiguredModeUsed() = runTest {
        val local = FakeProvider("local")
        val remote = FakeProvider("remote")
        val result = router(local, remote, TranscriptionMode.LocalFirst).transcribe(pcm, 16000)
        assertEquals(TranscriptionMode.LocalFirst, result.modeUsed)
        assertEquals("local", result.providerId)
        assertEquals(0, remote.calls)
    }

    @Test
    fun localFirst_localFails_fallsBackWithRemoteOnlyProvenance() = runTest {
        val local = FakeProvider("local", error = TranscriptionException.TranscriptionFailed("oom"))
        val remote = FakeProvider("remote")
        val r = router(local, remote, TranscriptionMode.LocalFirst)
        val result = r.transcribe(pcm, 16000)
        assertEquals(TranscriptionMode.RemoteOnly, result.modeUsed, "fallback provenance must say RemoteOnly")
        assertEquals("remote", result.providerId)
        assertEquals(TranscriptionMode.RemoteOnly, r.lastSuccessfulMode)
    }

    @Test
    fun localFirst_nonExceptionProviderFailure_fallsBackToRemote() = runTest {
        val local = FakeProvider("local", error = AssertionError("native boundary failed"))
        val remote = FakeProvider("remote")
        val result = router(local, remote, TranscriptionMode.LocalFirst).transcribe(pcm, 16000)
        assertEquals(TranscriptionMode.RemoteOnly, result.modeUsed)
        assertEquals("remote", result.providerId)
    }

    @Test
    fun localFirst_localUnavailable_fallsBackToRemote() = runTest {
        val remote = FakeProvider("remote")
        val result = router(FakeProvider("local", available = false), remote, TranscriptionMode.LocalFirst)
            .transcribe(pcm, 16000)
        assertEquals(TranscriptionMode.RemoteOnly, result.modeUsed)
        assertEquals(1, remote.calls)
    }

    @Test
    fun localFirst_bothFail_throws() = runTest {
        val local = FakeProvider("local", error = TranscriptionException.TranscriptionFailed("a"))
        val remote = FakeProvider("remote", error = TranscriptionException.TranscriptionFailed("b"))
        assertFailsWith<TranscriptionException.TranscriptionFailed> {
            router(local, remote, TranscriptionMode.LocalFirst).transcribe(pcm, 16000)
        }
    }

    @Test
    fun remoteFirst_remoteFails_fallsBackWithLocalOnlyProvenance() = runTest {
        val local = FakeProvider("local")
        val remote = FakeProvider("remote", error = TranscriptionException.TranscriptionFailed("net"))
        val result = router(local, remote, TranscriptionMode.RemoteFirst).transcribe(pcm, 16000)
        assertEquals(TranscriptionMode.LocalOnly, result.modeUsed)
        assertEquals("local", result.providerId)
    }

    @Test
    fun remoteFirst_remoteSuccess_keepsConfiguredModeUsed() = runTest {
        val local = FakeProvider("local")
        val remote = FakeProvider("remote")
        val result = router(local, remote, TranscriptionMode.RemoteFirst).transcribe(pcm, 16000)
        assertEquals(TranscriptionMode.RemoteFirst, result.modeUsed)
        assertEquals(0, local.calls)
    }

    @Test
    fun noSpeech_isAResult_notAFallbackTrigger() = runTest {
        val local = FakeProvider("local", error = TranscriptionException.NoSpeechDetected("silence"))
        val remote = FakeProvider("remote")
        assertFailsWith<TranscriptionException.NoSpeechDetected> {
            router(local, remote, TranscriptionMode.LocalFirst).transcribe(pcm, 16000)
        }
        assertEquals(0, remote.calls, "no-speech must not trigger remote fallback")
    }

    @Test
    fun cancellation_propagatesWithoutFallback() = runTest {
        val local = FakeProvider("local", error = CancellationException("cancelled"))
        val remote = FakeProvider("remote")
        assertFailsWith<CancellationException> {
            router(local, remote, TranscriptionMode.LocalFirst).transcribe(pcm, 16000)
        }
        assertEquals(0, remote.calls)
    }

    @Test
    fun availabilityMatrix() = runTest {
        val up = FakeProvider("up")
        val down = FakeProvider("down", available = false)

        assertTrue(router(up, down, TranscriptionMode.LocalOnly).isAvailable())
        assertFalse(router(down, up, TranscriptionMode.LocalOnly).isAvailable())
        assertTrue(router(down, up, TranscriptionMode.RemoteOnly).isAvailable())
        assertFalse(router(up, down, TranscriptionMode.RemoteOnly).isAvailable())
        assertTrue(router(down, up, TranscriptionMode.LocalFirst).isAvailable())
        assertTrue(router(up, down, TranscriptionMode.RemoteFirst).isAvailable())
        assertFalse(router(down, down, TranscriptionMode.LocalFirst).isAvailable())
        assertFalse(router(null, null, TranscriptionMode.RemoteFirst).isAvailable())
    }
}
