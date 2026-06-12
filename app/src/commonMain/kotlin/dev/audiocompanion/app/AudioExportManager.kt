package dev.audiocompanion.app

import dev.audiocompanion.storage.FrameRecord
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.PcmWav
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path

data class AudioExportedFile(
    val segmentId: String,
    val path: String,
    val bytes: Long,
)

data class AudioExportResult(
    val directory: String,
    val files: List<AudioExportedFile>,
    val skippedOpenSegments: Int = 0,
) {
    val fileCount: Int get() = files.size
}

/**
 * Writes user-accessible WAV copies of stored watch audio.
 *
 * The durable store remains the compact Speex frame log. Exports are opt-in because WAV uses
 * much more disk space, but the resulting files are normal audio files visible in the platform
 * export directory.
 */
class AudioExportManager(
    private val fileSystem: FileSystem,
    private val exportRoot: Path,
    private val listSegments: () -> List<SegmentMeta>,
    private val readMeta: (segmentId: String) -> SegmentMeta?,
    private val readFrames: (segmentId: String) -> List<FrameRecord>,
    private val decodePcm: (SegmentMeta, List<FrameRecord>) -> Flow<ByteArray>,
) {
    val directory: String get() = exportRoot.toString()

    suspend fun exportSegment(segmentId: String, overwrite: Boolean = true): AudioExportResult {
        val meta = readMeta(segmentId) ?: return AudioExportResult(directory, emptyList())
        val file = exportOne(meta, overwrite)
        return AudioExportResult(directory, listOfNotNull(file))
    }

    suspend fun exportAllClosedSegments(overwrite: Boolean = false): AudioExportResult {
        var skippedOpen = 0
        val exported = mutableListOf<AudioExportedFile>()
        for (meta in listSegments()) {
            if (meta.isOpen) {
                skippedOpen += 1
                continue
            }
            exportOne(meta, overwrite)?.let(exported::add)
        }
        return AudioExportResult(directory, exported, skippedOpen)
    }

    private suspend fun exportOne(meta: SegmentMeta, overwrite: Boolean): AudioExportedFile? {
        val frames = readFrames(meta.segmentId)
        if (frames.isEmpty()) return null
        fileSystem.createDirectories(exportRoot)
        val outputPath = Path(exportRoot, "${exportBaseName(meta)}.wav")
        if (!overwrite && fileSystem.exists(outputPath)) {
            val size = fileSystem.metadataOrNull(outputPath)?.size ?: 0L
            return AudioExportedFile(meta.segmentId, outputPath.toString(), size)
        }

        val expectedPcmBytes = (frames.size.toLong() * meta.frameSamples * Short.SIZE_BYTES)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
        var written = 0L
        fileSystem.sink(outputPath).buffered().use { sink ->
            val header = PcmWav.headerMono16(expectedPcmBytes, meta.sampleRateHz.toInt())
            sink.write(header)
            written += header.size
            decodePcm(meta, frames).collect { pcm ->
                sink.write(pcm)
                written += pcm.size
            }
        }
        return AudioExportedFile(meta.segmentId, outputPath.toString(), written)
    }

    private fun exportBaseName(meta: SegmentMeta): String {
        val timePart = meta.receivedAtMs.toString()
        val shortId = meta.segmentId.takeLast(12)
        return "pebble-audio-$timePart-$shortId".sanitizeFilename()
    }

    private fun String.sanitizeFilename(): String =
        map { char ->
            if (char.isLetterOrDigit() || char == '-' || char == '_') char else '-'
        }.joinToString("")
}
