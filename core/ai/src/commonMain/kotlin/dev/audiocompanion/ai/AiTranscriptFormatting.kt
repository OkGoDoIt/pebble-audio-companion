package dev.audiocompanion.ai

/**
 * Builds the user-message body for an [AiRunRequest]: the prompt's user instruction followed by each
 * transcript segment, bounded to [maxInputChars] (always-on recorder transcripts can be very large).
 * Shared by the cloud and on-device providers so they format identical input.
 */
internal object AiTranscriptFormatting {
    fun buildUserContent(request: AiRunRequest, maxInputChars: Int): String {
        val content = buildString {
            append(request.prompt.userPrompt.trim())
            append("\n\n")
            for (transcript in request.transcripts) {
                append("--- Transcript segment ")
                append(transcript.segmentId)
                transcript.startTimeMs?.let { append(" (starts at epoch ms $it)") }
                append(" ---\n")
                append(transcript.text.trim())
                append("\n\n")
            }
        }
        return if (content.length <= maxInputChars) content
        else content.take(maxInputChars) + "\n[transcript truncated for length]"
    }
}
