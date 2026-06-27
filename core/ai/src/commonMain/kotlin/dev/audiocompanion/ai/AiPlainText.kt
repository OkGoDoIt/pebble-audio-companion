package dev.audiocompanion.ai

/** Utilities for displaying model output in compact app surfaces. */
object AiPlainText {
    private val whitespace = Regex("\\s+")
    private val headingPrefix = Regex("^#{1,6}\\s+")
    private val bulletPrefix = Regex("^[-*•]\\s+")
    private val bold = Regex("\\*\\*([^*]+)\\*\\*")
    private val emphasis = Regex("(^|\\s)[*_]([^*_]+)[*_](\\s|$)")
    private val fieldLabel = Regex("^(TITLE|SUMMARY|TAGS)\\s*:\\s*", RegexOption.IGNORE_CASE)

    fun clean(text: String?, maxChars: Int? = null): String? {
        val cleaned = text
            ?.lineSequence()
            ?.mapNotNull { cleanLine(it) }
            ?.joinToString(" ")
            ?.replace(whitespace, " ")
            ?.trim()
            ?.ifBlank { null }
            ?: return null
        return maxChars?.let { cleaned.take(it).trimEnd() } ?: cleaned
    }

    fun cleanLine(line: String): String? {
        var value = line.trim()
        if (value.isBlank()) return null
        value = value
            .replace(headingPrefix, "")
            .replace(bulletPrefix, "")
            .replace(bold, "$1")
            .replace(emphasis, "$1$2$3")
            .replace("`", "")
            .replace(fieldLabel, "")
            .trim()
        return value.ifBlank { null }
    }
}
