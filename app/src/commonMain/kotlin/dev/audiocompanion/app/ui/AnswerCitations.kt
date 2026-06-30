package dev.audiocompanion.app.ui

/**
 * Pure parsing/resolution for the citations an AI answer makes to the transcript moments it drew
 * from. Kept Compose-free so the messy normalisation can be unit-tested directly.
 *
 * References reach us in several shapes and we fold them all into one resolved, numbered form so
 * the UI can render a single consistent affordance instead of opaque ids:
 *  - `[n]` footnote numbers keyed to the prompt's numbered source list (the preferred form Ask now
 *    asks the model to emit);
 *  - `[seg-…](#)` markdown links the model used to invent, where the id is usually truncated;
 *  - bare `seg-…` ids dropped into the prose.
 *
 * Truncated ids resolve against the real source list by prefix, so historical outputs still link.
 */
internal sealed interface AnswerToken {
    /** Literal prose (may still contain `**bold**` / `*italic*`, handled at render time). */
    data class Span(val text: String) : AnswerToken

    /** A resolved citation: [number] is the 1-based display index, [segmentId] the real source. */
    data class Citation(val number: Int, val segmentId: String) : AnswerToken
}

/** One rendered line of the answer: an optional list/quote [marker] plus inline [tokens]. */
internal data class AnswerLine(val marker: String?, val tokens: List<AnswerToken>)

internal data class GroundedAnswer(
    val lines: List<AnswerLine>,
    /** Distinct cited segment ids in first-appearance order; `index + 1` is the display number. */
    val citedSegmentIds: List<String>,
)

private val MARKDOWN_LINK = Regex("""\[([^\]\n]*)]\(([^)\n]*)\)""")
private val FOOTNOTE = Regex("""\[(\d{1,3})]""")
private val SEG_TOKEN = Regex("""seg-[A-Za-z0-9_-]+""")

/** Earliest-wins union of every citation shape, scanned left to right across a line. */
private val ANY_CITATION = Regex("""\[[^\]\n]*]\([^)\n]*\)|\[\d{1,3}]|seg-[A-Za-z0-9_-]+""")

/** Separator-only spans between two adjacent citations that we collapse away. */
private val CONNECTOR = setOf(",", ";", "·", "/", "&", "and", "+")

/**
 * Parse [text] into renderable lines with citations resolved against [sourceIds] (the answer's
 * real source segment ids, in the order the model was shown them). Numbering is assigned by first
 * appearance so inline chips and the "Based on" list share one stable set of numbers.
 */
internal fun parseGroundedAnswer(text: String, sourceIds: List<String>): GroundedAnswer {
    val numberBySegment = LinkedHashMap<String, Int>()
    fun numberFor(segmentId: String): Int = numberBySegment.getOrPut(segmentId) { numberBySegment.size + 1 }

    val lines = splitAnswerBlocks(text).mapNotNull { block ->
        val tokens = cleanupConnectors(tokenizeLine(block.text, sourceIds, ::numberFor))
        val meaningful = tokens.any { it is AnswerToken.Citation } ||
            tokens.any { it is AnswerToken.Span && it.text.isNotBlank() }
        if (block.marker == null && !meaningful) null else AnswerLine(block.marker, tokens)
    }
    return GroundedAnswer(lines, numberBySegment.keys.toList())
}

private data class RawBlock(val marker: String?, val text: String)

/**
 * Split markdown-ish answer text into list/quote blocks. Mirrors the bullet/number/checkbox
 * handling the answer view needs; continuation lines (indented) fold into the prior block.
 */
private fun splitAnswerBlocks(text: String): List<RawBlock> =
    text.lines()
        .map { it.trimEnd() }
        .fold(mutableListOf<RawBlock>()) { blocks, rawLine ->
            val line = rawLine.trim()
            when {
                line.isBlank() -> blocks
                line.startsWith("- [ ] ") ->
                    blocks += RawBlock("☐", line.removePrefix("- [ ] ").trim())
                line.startsWith("- [x] ", ignoreCase = true) ->
                    blocks += RawBlock("☑", line.substringAfter("] ").trim())
                line.startsWith("- ") || line.startsWith("* ") ->
                    blocks += RawBlock("•", line.drop(2).trim())
                line.matches(Regex("^\\d+[.)]\\s+.*")) -> {
                    val marker = line.substringBefore(' ').let {
                        if (it.endsWith(".") || it.endsWith(")")) it else "$it."
                    }
                    blocks += RawBlock(marker, line.replaceFirst(Regex("^\\d+[.)]\\s+"), ""))
                }
                blocks.lastOrNull()?.marker != null && rawLine.startsWith("  ") -> {
                    val previous = blocks.removeAt(blocks.lastIndex)
                    blocks += previous.copy(text = previous.text + " " + line)
                }
                else -> blocks += RawBlock(null, line)
            }
            blocks
        }

private fun tokenizeLine(
    line: String,
    sourceIds: List<String>,
    numberFor: (String) -> Int,
): List<AnswerToken> {
    val out = mutableListOf<AnswerToken>()
    var index = 0
    while (index < line.length) {
        val match = ANY_CITATION.find(line, index)
        if (match == null) {
            out += AnswerToken.Span(line.substring(index))
            break
        }
        if (match.range.first > index) out += AnswerToken.Span(line.substring(index, match.range.first))
        val resolved = resolveCitation(match.value, sourceIds)
        if (resolved != null) {
            out += AnswerToken.Citation(numberFor(resolved), resolved)
        } else {
            fallbackText(match.value)?.let { out += AnswerToken.Span(it) }
        }
        index = match.range.last + 1
    }
    return out
}

/** What to keep when a citation can't be resolved: link/number text stays, opaque ids are dropped. */
private fun fallbackText(raw: String): String? = when {
    MARKDOWN_LINK.matchEntire(raw) != null -> {
        val label = MARKDOWN_LINK.matchEntire(raw)!!.groupValues[1]
        // A real hyperlink keeps its human label; an unresolved seg-link contributes nothing.
        if (SEG_TOKEN.containsMatchIn(label) || label.trim().toIntOrNull() != null) null else label
    }
    raw.startsWith("seg-") -> null
    else -> raw // e.g. a genuine "[12]" bracketed number, not a footnote
}

private fun resolveCitation(raw: String, sourceIds: List<String>): String? {
    MARKDOWN_LINK.matchEntire(raw)?.let { link ->
        val label = link.groupValues[1]
        val url = link.groupValues[2]
        SEG_TOKEN.find(label)?.value?.let { return resolveSeg(it, sourceIds) }
        SEG_TOKEN.find(url)?.value?.let { return resolveSeg(it, sourceIds) }
        label.trim().toIntOrNull()?.let { return sourceIds.getOrNull(it - 1) }
        return null
    }
    FOOTNOTE.matchEntire(raw)?.let { return sourceIds.getOrNull(it.groupValues[1].toInt() - 1) }
    if (raw.startsWith("seg-")) return resolveSeg(raw, sourceIds)
    return null
}

/** Resolve a (possibly truncated) `seg-…` token to a real source id: exact, then either-way prefix. */
private fun resolveSeg(token: String, sourceIds: List<String>): String? {
    val trimmed = token.trimEnd('.', ',', ')', ';', ':')
    return sourceIds.firstOrNull { it == trimmed }
        ?: sourceIds.firstOrNull { it.startsWith(trimmed) }
        ?: sourceIds.firstOrNull { trimmed.startsWith(it) }
}

/**
 * Strip the punctuation that historically wrapped citations — `(`, `)`, and `, ` separators that
 * the model put around `([seg…](#), [seg…](#))` — so chips hug the sentence cleanly: "…committed¹²."
 */
private fun cleanupConnectors(tokens: List<AnswerToken>): List<AnswerToken> {
    val out = mutableListOf<AnswerToken>()
    tokens.forEachIndexed { i, token ->
        if (token !is AnswerToken.Span) {
            out += token
            return@forEachIndexed
        }
        val prevIsCitation = out.lastOrNull() is AnswerToken.Citation
        val nextIsCitation = tokens.getOrNull(i + 1) is AnswerToken.Citation
        var text = token.text
        if (prevIsCitation && nextIsCitation && (text.isBlank() || text.trim() in CONNECTOR)) {
            return@forEachIndexed // drop a pure separator sitting between two chips
        }
        if (nextIsCitation) text = text.replace(Regex("""\(\s*$"""), "")
        if (prevIsCitation) text = text.replace(Regex("""^\s*\)"""), "")
        if (text.isNotEmpty()) out += AnswerToken.Span(text)
    }
    return out
}
