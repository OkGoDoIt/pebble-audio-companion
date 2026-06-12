package dev.audiocompanion.app.ui

import dev.audiocompanion.ai.AiException
import dev.audiocompanion.ai.AiOutput
import dev.audiocompanion.ai.AiPromptTemplate
import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SegmentTranscript
import dev.audiocompanion.transcription.TranscriptionMode

/**
 * Everything the shared Compose UI can ask the platform/runtime layer to do. Both platforms
 * wire this once; screens never talk to the runtime directly so the UI stays previewable and
 * platform-free.
 */
class AppActions(
    // Receiver lifecycle
    val pairWatch: () -> Unit = {},
    /** Onboarding: request platform permissions without starting watch association. */
    val requestPermissions: () -> Unit = {},
    val setOnboardingComplete: (Boolean) -> Unit = {},
    val startReceiver: () -> Unit = {},
    val stopReceiver: () -> Unit = {},
    val setBackgroundReceiverEnabled: (Boolean) -> Unit = {},
    val refreshDiagnostics: () -> Unit = {},
    /** Live waveform decode runs only while the Today screen is visible. */
    val setWaveformActive: (Boolean) -> Unit = {},
    // Segment playback
    val playSegment: (segmentId: String) -> Unit = {},
    val pausePlayback: () -> Unit = {},
    val stopPlayback: () -> Unit = {},
    val seekPlayback: (segmentId: String, positionMs: Long) -> Unit = { _, _ -> },
    val cyclePlaybackSpeed: () -> Unit = {},
    // Durable content reads (file-backed; cheap at MVP scale)
    val loadSegments: () -> List<SegmentMeta> = { emptyList() },
    /** Decoded waveform of one stored segment (computed off the UI path, cached). */
    val loadSegmentWaveform: suspend (segmentId: String) -> dev.audiocompanion.app.SegmentWaveform? = { null },
    val loadTranscript: (segmentId: String) -> SegmentTranscript? = { null },
    /** Rolling live transcript preview of a still-recording segment, or null. */
    val loadLiveTranscript: (segmentId: String) -> String? = { null },
    val loadAnnotation: (segmentId: String) -> SegmentAnnotation? = { null },
    val loadAiOutputs: () -> List<AiOutput> = { emptyList() },
    // Content management
    val deleteSegment: (segmentId: String) -> Unit = {},
    val deleteAiOutput: (outputId: String) -> Unit = {},
    val deleteAll: () -> Unit = {},
    val revokeReceiver: () -> Unit = {},
    val exportSupportReport: () -> dev.audiocompanion.app.AudioCompanionSupportReport? = { null },
    val audioExportDirectory: () -> String? = { null },
    val exportSegmentAudio: suspend (segmentId: String) -> Result<dev.audiocompanion.app.AudioExportResult> = {
        Result.failure(IllegalStateException("audio export is not wired"))
    },
    val exportAllAudio: suspend () -> Result<dev.audiocompanion.app.AudioExportResult> = {
        Result.failure(IllegalStateException("audio export is not wired"))
    },
    // AI
    val runAi: suspend (AiPromptTemplate, List<String>) -> Result<AiOutput> = { _, _ ->
        Result.failure(AiException.ProviderUnavailable("not wired"))
    },
    // Settings
    val setRetentionDays: (Int) -> Unit = {},
    val setTranscriptionMode: (TranscriptionMode) -> Unit = {},
    val setLocalTranscriptionModel: (String) -> Unit = {},
    val setCloudTranscriptionConsent: (Boolean) -> Unit = {},
    val setOpenAiApiKey: (String) -> Unit = {},
    val setAiMode: (AiProcessingMode) -> Unit = {},
    val setRemoteAiConsent: (Boolean) -> Unit = {},
    val setAutomaticWavExportEnabled: (Boolean) -> Unit = {},
    // Local transcription model
    val refreshLocalModel: () -> Unit = {},
    val downloadLocalModel: () -> Unit = {},
    val cancelModelDownload: () -> Unit = {},
)
