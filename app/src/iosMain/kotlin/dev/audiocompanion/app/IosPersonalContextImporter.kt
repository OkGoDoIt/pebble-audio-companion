package dev.audiocompanion.app

import dev.audiocompanion.ai.ContextSource
import dev.audiocompanion.ai.ContextSourceKind
import dev.audiocompanion.ai.KnownPerson
import dev.audiocompanion.ai.VocabTerm
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

interface IosPersonalContextImportBridge {
    fun importContacts(callback: (names: List<String>, orgs: List<String>, error: String?) -> Unit)
    fun importCalendar(callback: (eventTitles: List<String>, attendees: List<String>, error: String?) -> Unit)
}

object IosPersonalContextImportRegistry {
    var bridge: IosPersonalContextImportBridge? = null
}

class IosPersonalContextImporter : PersonalContextImporter {
    override suspend fun importContacts(nowMs: Long): PersonalContextImport {
        val bridge = IosPersonalContextImportRegistry.bridge
            ?: throw IllegalStateException("iOS personal context import bridge is not registered")
        return suspendCoroutine { cont ->
            bridge.importContacts { names, orgs, error ->
                if (error != null) {
                    cont.resumeWithException(IllegalStateException(error))
                } else {
                    cont.resume(
                        PersonalContextImport(
                            people = names.distinct().map {
                                KnownPerson(id = "ios-contact-${it.hashCode()}", name = it)
                            },
                            orgs = orgs.distinct().sorted(),
                            terms = (names + orgs).distinct().map { VocabTerm(it) },
                            sources = listOf(
                                ContextSource(
                                    id = "ios-contacts-$nowMs",
                                    kind = ContextSourceKind.Contacts,
                                    label = "iOS contacts (${names.distinct().size} people)",
                                    importedAtMs = nowMs,
                                ),
                            ),
                        ),
                    )
                }
            }
        }
    }

    override suspend fun importCalendar(nowMs: Long): PersonalContextImport {
        val bridge = IosPersonalContextImportRegistry.bridge
            ?: throw IllegalStateException("iOS personal context import bridge is not registered")
        return suspendCoroutine { cont ->
            bridge.importCalendar { eventTitles, attendees, error ->
                if (error != null) {
                    cont.resumeWithException(IllegalStateException(error))
                } else {
                    val people = attendees.distinct().map {
                        KnownPerson(id = "ios-calendar-attendee-${it.hashCode()}", name = it)
                    }
                    val topics = eventTitles.distinct()
                    cont.resume(
                        PersonalContextImport(
                            people = people,
                            topics = topics,
                            terms = (attendees + eventTitles).distinct().map { VocabTerm(it) },
                            sources = listOf(
                                ContextSource(
                                    id = "ios-calendar-$nowMs",
                                    kind = ContextSourceKind.Calendar,
                                    label = "iOS calendar (${topics.size} events)",
                                    importedAtMs = nowMs,
                                ),
                            ),
                        ),
                    )
                }
            }
        }
    }
}
