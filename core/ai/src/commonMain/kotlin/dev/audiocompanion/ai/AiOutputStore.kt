package dev.audiocompanion.ai

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class AiOutput(
    val outputId: String,
    val requestId: String,
    val promptTemplateId: String,
    val promptTitle: String,
    val segmentIds: List<String>,
    val text: String,
    val modeUsed: AiProcessingMode,
    val providerId: String,
    val modelUsed: String? = null,
    val inputTokens: Int? = null,
    val outputTokens: Int? = null,
    val createdAtMs: Long,
    val userConsentedToRemote: Boolean,
)

/**
 * DB-less durable AI output store for the MVP manual processing flow.
 *
 * Outputs are linked to transcript/segment ids and written atomically under
 * `<root>/ai/outputs/`. The rule engine and richer index can build on this without changing
 * provider routing.
 */
class FileAiOutputStore(
    private val fileSystem: FileSystem,
    root: Path,
    private val nowMs: () -> Long,
) {
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
    }
    private val outputDir = Path(Path(root, "ai"), "outputs")

    private fun outputPath(outputId: String) = Path(outputDir, "$outputId.ai.json")

    fun save(
        request: AiRunRequest,
        result: RoutedAiResult,
        userConsentedToRemote: Boolean,
    ): AiOutput {
        val output = AiOutput(
            outputId = request.requestId,
            requestId = request.requestId,
            promptTemplateId = request.prompt.id,
            promptTitle = request.prompt.title,
            segmentIds = request.transcripts.map { it.segmentId }.distinct(),
            text = result.text,
            modeUsed = result.modeUsed,
            providerId = result.providerId,
            modelUsed = result.modelUsed,
            inputTokens = result.inputTokens,
            outputTokens = result.outputTokens,
            createdAtMs = nowMs(),
            userConsentedToRemote = userConsentedToRemote,
        )
        write(output)
        return output
    }

    fun load(outputId: String): AiOutput? {
        val path = outputPath(outputId)
        if (!fileSystem.exists(path)) return null
        val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(AiOutput.serializer(), text) }.getOrNull()
    }

    fun list(): List<AiOutput> {
        if (!fileSystem.exists(outputDir)) return emptyList()
        return fileSystem.list(outputDir)
            .filter { it.name.endsWith(".ai.json") }
            .mapNotNull { load(it.name.removeSuffix(".ai.json")) }
            .sortedBy { it.createdAtMs }
    }

    fun delete(outputId: String) {
        fileSystem.delete(outputPath(outputId), mustExist = false)
    }

    private fun write(output: AiOutput) {
        fileSystem.createDirectories(outputDir)
        val tmp = Path(outputDir, "${output.outputId}.ai.json.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(AiOutput.serializer(), output).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, outputPath(output.outputId))
    }
}
