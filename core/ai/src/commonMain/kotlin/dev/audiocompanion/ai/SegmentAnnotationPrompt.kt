package dev.audiocompanion.ai

/**
 * Prompt + response contract for automatic segment titles/summaries. One short call per
 * transcribed segment; output is parsed leniently so a slightly off-format model response
 * still yields usable row text.
 */
object SegmentAnnotationPrompt {
    private const val SYSTEM_PROMPT =
        "You label transcripts of background audio captured by the user's own always-on " +
            "wearable microphone. The audio is recorded from a low-quality microphone in noisy, " +
            "real-world conditions and then transcribed automatically, so the text very likely " +
            "contains misheard words, garbled names, run-on fragments, and annotated gaps where " +
            "audio was missing. Read past these errors and infer the most plausible intended " +
            "meaning, but never invent facts, names, or events that are not supported by the " +
            "text. Prefer general phrasing when a detail is clearly garbled rather than guessing " +
            "a specific wrong word.\n" +
            "Respond in plain text only. Do not use Markdown, bullets, headings, bold text, or " +
            "numbered lists. Respond with exactly three lines and nothing else:\n" +
            "TITLE: a specific, plain title of at most 8 words (no quotes, no trailing period)\n" +
            "SUMMARY: 1-3 plain sentences summarizing what was discussed\n" +
            "TAGS: 2-3 short topic tags, comma-separated (e.g. work, budget, Sarah)\n" +
            "If the transcript is too short or unclear to summarize, still produce your best " +
            "honest label, e.g. TITLE: Brief unclear conversation."

    /** Closed-segment, authoritative pass over the complete durable transcript. */
    val template = AiPromptTemplate(
        id = "segment-annotation",
        title = "Segment title and summary",
        systemPrompt = SYSTEM_PROMPT,
        userPrompt = "This is the complete transcript of a finished conversation. Create the " +
            "authoritative title and summary for it.",
    )

    /** In-progress pass while the conversation is still being recorded and transcribed. */
    val liveTemplate = AiPromptTemplate(
        id = "segment-annotation-live",
        title = "Segment title and summary (live)",
        systemPrompt = SYSTEM_PROMPT,
        userPrompt = "This conversation is still ongoing and only partially transcribed. " +
            "Summarize what has been discussed so far; a later pass will produce the final " +
            "version.",
    )

    /** The prompt to use for a given pass: [liveTemplate] while recording, [template] when final. */
    fun forPass(live: Boolean): AiPromptTemplate = if (live) liveTemplate else template

    data class Parsed(val title: String?, val summary: String?, val tags: List<String> = emptyList())

    fun parse(text: String): Parsed {
        var title: String? = null
        val summaryParts = mutableListOf<String>()
        var tags: List<String> = emptyList()
        var activeField: String? = null
        for (line in text.lineSequence()) {
            val trimmed = line.trim()
            val match = FIELD_LINE.matchEntire(trimmed)
            if (match != null) {
                val field = match.groupValues[1].uppercase()
                val value = AiPlainText.clean(match.groupValues[2])
                activeField = field
                when (field) {
                    "TITLE" -> if (title == null) title = value
                    "SUMMARY" -> if (!value.isNullOrBlank()) summaryParts += value
                    "TAGS" -> if (tags.isEmpty()) {
                        tags = match.groupValues[2]
                            .split(',', ';')
                            .mapNotNull { AiPlainText.clean(it) }
                            .filter { it.isNotBlank() }
                            .take(3)
                    }
                }
            } else if (activeField == "SUMMARY") {
                AiPlainText.cleanLine(trimmed)?.let { summaryParts += it }
            }
        }
        var summary = summaryParts.joinToString(" ").ifBlank { null }
        if (title == null && summary == null) {
            // Lenient fallback: first non-blank line is the title, the rest the summary.
            val lines = text.lines().mapNotNull { AiPlainText.cleanLine(it) }
            title = lines.firstOrNull()?.take(MAX_TITLE_CHARS)
            summary = lines.drop(1).joinToString(" ").ifBlank { null }
        }
        return Parsed(
            title = AiPlainText.clean(title, MAX_TITLE_CHARS),
            summary = AiPlainText.clean(summary, MAX_SUMMARY_CHARS),
            tags = tags,
        )
    }

    private val FIELD_LINE = Regex(
        "^\\s*(?:#{1,6}\\s*)?(?:[-*]\\s*)?(?:\\*\\*)?\\s*(TITLE|SUMMARY|TAGS)" +
            "\\s*:?\\s*(?:\\*\\*)?\\s*:?\\s*(.*)$",
        RegexOption.IGNORE_CASE,
    )
    private const val MAX_TITLE_CHARS = 80
    private const val MAX_SUMMARY_CHARS = 600
}
