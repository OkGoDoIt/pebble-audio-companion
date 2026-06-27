package dev.audiocompanion.app

import dev.audiocompanion.ai.FilePersonalContextStore
import dev.audiocompanion.ai.PersonalContext
import dev.audiocompanion.ai.PersonalContextFormatting
import dev.audiocompanion.ai.PersonalContextTermExtractor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Holds durable [PersonalContext], exposes budgeted slices for transcription/AI providers, and
 * refreshes derived STT terms when profile text changes.
 */
class PersonalContextCoordinator(
    private val store: FilePersonalContextStore,
    private val extractor: PersonalContextTermExtractor,
) {
    private val _state = MutableStateFlow(store.load())
    val state: StateFlow<PersonalContext> = _state.asStateFlow()

    fun snapshot(): PersonalContext = _state.value

    fun transcriptionText(): String? =
        PersonalContextFormatting.transcriptionText(snapshot())

    fun transcriptionTerms(): List<String> =
        PersonalContextFormatting.transcriptionTerms(snapshot())

    fun openAiSttPrompt(): String? =
        PersonalContextFormatting.openAiSttPrompt(snapshot())

    fun aiGroundingBlock(): String? =
        PersonalContextFormatting.aiGroundingBlock(snapshot())

    /**
     * Persists profile text and kicks off term extraction on [scope] when text changes.
     */
    fun setProfileText(text: String?, scope: CoroutineScope) {
        val trimmed = text?.trim()?.takeIf { it.isNotEmpty() }
        val saved = store.save(snapshot().copy(profileText = trimmed))
        _state.value = saved
        scope.launch { refreshDerivedTermsIfNeeded() }
    }

    fun clear(scope: CoroutineScope) {
        store.clear()
        _state.value = PersonalContext()
        scope.launch { refreshDerivedTermsIfNeeded() }
    }

    fun mergeImported(imported: PersonalContextImport, scope: CoroutineScope): PersonalContext {
        val current = snapshot()
        val saved = store.save(
            current.copy(
                people = (current.people + imported.people).distinctBy { it.id }.sortedBy { it.name },
                orgs = (current.orgs + imported.orgs).distinct().sorted(),
                topics = (current.topics + imported.topics).distinct().sorted(),
                terms = (current.terms + imported.terms).distinctBy { it.text.lowercase() }.sortedBy { it.text },
                sources = (current.sources + imported.sources).distinctBy { it.id },
            ),
        )
        _state.value = saved
        scope.launch { refreshDerivedTermsIfNeeded() }
        return saved
    }

    suspend fun refreshDerivedTermsIfNeeded() {
        val current = snapshot()
        val refreshed = extractor.refreshDerivedTerms(current)
        if (refreshed != current) {
            store.save(refreshed)
            _state.value = refreshed
        }
    }

    /** Load from disk on startup (e.g. after factory creates coordinator). */
    fun reloadFromDisk() {
        _state.value = store.load()
    }
}
