package dev.audiocompanion.app

import dev.audiocompanion.ai.ContextSource
import dev.audiocompanion.ai.KnownPerson
import dev.audiocompanion.ai.VocabTerm

/**
 * User-triggered platform import of Contacts/Calendar facts into Personal Context.
 * Implementations must request/read permissions only from explicit Settings actions.
 */
interface PersonalContextImporter {
    suspend fun importContacts(nowMs: Long): PersonalContextImport
    suspend fun importCalendar(nowMs: Long): PersonalContextImport
}

data class PersonalContextImport(
    val people: List<KnownPerson> = emptyList(),
    val orgs: List<String> = emptyList(),
    val topics: List<String> = emptyList(),
    val terms: List<VocabTerm> = emptyList(),
    val sources: List<ContextSource> = emptyList(),
)

class UnsupportedPersonalContextImporter(
    private val reason: String = "Personal context import is not available on this device.",
) : PersonalContextImporter {
    override suspend fun importContacts(nowMs: Long): PersonalContextImport =
        throw IllegalStateException(reason)

    override suspend fun importCalendar(nowMs: Long): PersonalContextImport =
        throw IllegalStateException(reason)
}
