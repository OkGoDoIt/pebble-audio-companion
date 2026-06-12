package dev.audiocompanion.ai

/**
 * Prompt + response contract for automatic segment titles/summaries. One short call per
 * transcribed segment; output is parsed leniently so a slightly off-format model response
 * still yields usable row text.
 */
object SegmentAnnotationPrompt {
    val template = AiPromptTemplate(
        id = "segment-annotation",
        title = "Segment title and summary",
        systemPrompt = "You label transcripts of background audio captured by the user's own " +
            "wearable microphone. Transcripts may contain transcription errors and gaps. " +
            "Respond with exactly two lines:\n" +
            "TITLE: a specific title of at most 8 words (no quotes, no trailing period)\n" +
            "SUMMARY: 1-3 plain sentences summarizing what was said\n" +
            "Do not invent content. If the transcript is too short or unclear, still produce " +
            "your best honest label, e.g. TITLE: Brief unclear conversation.",
        userPrompt = "Create the title and summary for this transcript.",
    )

    data class Parsed(val title: String?, val summary: String?)

    fun parse(text: String): Parsed {
        var title: String? = null
        var summary: String? = null
        for (line in text.lineSequence()) {
            val trimmed = line.trim()
            when {
                trimmed.startsWith("TITLE:", ignoreCase = true) && title == null ->
                    title = trimmed.substring("TITLE:".length).trim().ifBlank { null }
                trimmed.startsWith("SUMMARY:", ignoreCase = true) && summary == null ->
                    summary = trimmed.substring("SUMMARY:".length).trim().ifBlank { null }
            }
        }
        if (title == null && summary == null) {
            // Lenient fallback: first non-blank line is the title, the rest the summary.
            val lines = text.lines().map { it.trim() }.filter { it.isNotBlank() }
            title = lines.firstOrNull()?.take(MAX_TITLE_CHARS)
            summary = lines.drop(1).joinToString(" ").ifBlank { null }
        }
        return Parsed(title = title?.take(MAX_TITLE_CHARS), summary = summary?.take(MAX_SUMMARY_CHARS))
    }

    private const val MAX_TITLE_CHARS = 80
    private const val MAX_SUMMARY_CHARS = 600
}
