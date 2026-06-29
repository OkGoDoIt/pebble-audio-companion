package dev.audiocompanion.app

import dev.audiocompanion.transcription.CloudConnectivityResult
import kotlin.test.Test
import kotlin.test.assertEquals

class CloudHealthMonitorTest {
    private fun monitor() = CloudHealthMonitor(nowMs = { 1_000 }, failureThreshold = 3)

    @Test
    fun transientFailuresBelowThresholdAreNotSurfaced() {
        val monitor = monitor()
        monitor.report(CloudConnectivityResult.Failed("Request timeout"))
        monitor.report(CloudConnectivityResult.Failed("Request timeout"))
        // Two back-to-back failures still look transient — banner stays clear.
        assertEquals(CloudHealthStatus.Unknown, monitor.state.value.status)
    }

    @Test
    fun repeatedFailuresSurfaceAsFailed() {
        val monitor = monitor()
        repeat(3) { monitor.report(CloudConnectivityResult.Failed("Request timeout")) }
        assertEquals(CloudHealthStatus.Failed, monitor.state.value.status)
        assertEquals("Request timeout", monitor.state.value.message)
    }

    @Test
    fun successResetsTheFailureStreak() {
        val monitor = monitor()
        monitor.report(CloudConnectivityResult.Failed("blip"))
        monitor.report(CloudConnectivityResult.Failed("blip"))
        monitor.report(CloudConnectivityResult.Ok("connected"))
        assertEquals(CloudHealthStatus.Ok, monitor.state.value.status)
        // Streak reset: the next two failures are again treated as transient.
        monitor.report(CloudConnectivityResult.Failed("blip"))
        monitor.report(CloudConnectivityResult.Failed("blip"))
        assertEquals(CloudHealthStatus.Ok, monitor.state.value.status)
    }

    @Test
    fun notConfiguredSurfacesImmediately() {
        val monitor = monitor()
        monitor.report(CloudConnectivityResult.NotConfigured("Add an API key"))
        assertEquals(CloudHealthStatus.NotConfigured, monitor.state.value.status)
    }

    @Test
    fun explicitProbeReportsImmediately() {
        val monitor = monitor()
        monitor.reportImmediate(CloudConnectivityResult.Failed("rejected the API key"))
        assertEquals(CloudHealthStatus.Failed, monitor.state.value.status)
        // And one more automatic failure keeps it visible (the streak was primed).
        monitor.report(CloudConnectivityResult.Failed("Request timeout"))
        assertEquals(CloudHealthStatus.Failed, monitor.state.value.status)
    }
}
