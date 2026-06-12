package dev.audiocompanion.ai

/**
 * Built-in manual templates for the MVP AI flow (ux-visual-design-plan Section 19). Users can
 * also run a custom prompt; custom templates persist post-MVP.
 */
object AiPromptTemplates {
    private const val COMMON_SYSTEM_RULES =
        "You are processing transcripts of background audio captured by the user's own " +
            "wearable microphone. Transcripts may contain transcription errors, fragments, and " +
            "annotated gaps where audio was missing. Never invent content for gaps; mention " +
            "missing audio only when it matters for the answer. Be concise and factual."

    val DailySummary = AiPromptTemplate(
        id = "daily-summary",
        title = "Daily summary",
        systemPrompt = "$COMMON_SYSTEM_RULES Produce a clear summary of the day's captured " +
            "conversations and events, organized chronologically with approximate times when " +
            "available.",
        userPrompt = "Summarize what happened in these transcripts.",
    )

    val MeetingNotes = AiPromptTemplate(
        id = "meeting-notes",
        title = "Meeting notes",
        systemPrompt = "$COMMON_SYSTEM_RULES Produce structured meeting notes: topic, " +
            "discussion points, decisions, and open questions.",
        userPrompt = "Write meeting notes for this conversation.",
    )

    val ActionItems = AiPromptTemplate(
        id = "action-items",
        title = "Action items",
        systemPrompt = "$COMMON_SYSTEM_RULES Extract action items as a checklist. Each item " +
            "states the task, the owner if mentioned, and any deadline mentioned. If there are " +
            "no action items, say so plainly.",
        userPrompt = "Extract the action items from these transcripts.",
    )

    val Decisions = AiPromptTemplate(
        id = "decisions",
        title = "Decisions",
        systemPrompt = "$COMMON_SYSTEM_RULES List the decisions that were made, each with the " +
            "context that led to it. If no decisions were made, say so plainly.",
        userPrompt = "List the decisions made in these transcripts.",
    )

    val FollowUpEmail = AiPromptTemplate(
        id = "follow-up-email",
        title = "Follow-up email",
        systemPrompt = "$COMMON_SYSTEM_RULES Draft a short, professional follow-up email " +
            "covering what was discussed, decided, and agreed as next steps. Leave the " +
            "recipient placeholder as [Name].",
        userPrompt = "Draft a follow-up email based on these transcripts.",
    )

    val builtIn: List<AiPromptTemplate> = listOf(
        DailySummary,
        MeetingNotes,
        ActionItems,
        Decisions,
        FollowUpEmail,
    )

    fun custom(prompt: String): AiPromptTemplate = AiPromptTemplate(
        id = "custom",
        title = "Custom prompt",
        systemPrompt = COMMON_SYSTEM_RULES,
        userPrompt = prompt,
    )
}
