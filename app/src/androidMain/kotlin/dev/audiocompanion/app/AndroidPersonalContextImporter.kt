package dev.audiocompanion.app

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import android.provider.ContactsContract
import androidx.core.content.ContextCompat
import dev.audiocompanion.ai.ContextSource
import dev.audiocompanion.ai.ContextSourceKind
import dev.audiocompanion.ai.KnownPerson
import dev.audiocompanion.ai.VocabTerm
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Android Contacts/Calendar importer for M5 Personal Context. */
class AndroidPersonalContextImporter(
    private val context: Context,
) : PersonalContextImporter {
    override suspend fun importContacts(nowMs: Long): PersonalContextImport =
        withContext(Dispatchers.IO) {
            requirePermission(Manifest.permission.READ_CONTACTS)
            val people = readContacts()
            val orgs = readContactOrganizations()
            PersonalContextImport(
                people = people,
                orgs = orgs,
                terms = people.map { VocabTerm(it.name) } + orgs.map { VocabTerm(it) },
                sources = listOf(
                    ContextSource(
                        id = "android-contacts-$nowMs",
                        kind = ContextSourceKind.Contacts,
                        label = "Android contacts (${people.size} people)",
                        importedAtMs = nowMs,
                    ),
                ),
            )
        }

    override suspend fun importCalendar(nowMs: Long): PersonalContextImport =
        withContext(Dispatchers.IO) {
            requirePermission(Manifest.permission.READ_CALENDAR)
            val imported = readCalendar(nowMs)
            imported.copy(
                sources = listOf(
                    ContextSource(
                        id = "android-calendar-$nowMs",
                        kind = ContextSourceKind.Calendar,
                        label = "Android calendar (${imported.topics.size} events)",
                        importedAtMs = nowMs,
                    ),
                ),
            )
        }

    private fun requirePermission(permission: String) {
        check(ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) {
            "Permission not granted: $permission"
        }
    }

    private fun readContacts(): List<KnownPerson> {
        val projection = arrayOf(
            ContactsContract.Contacts._ID,
            ContactsContract.Contacts.LOOKUP_KEY,
            ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
        )
        return context.contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            projection,
            null,
            null,
            "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} ASC",
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(ContactsContract.Contacts._ID)
            val lookupIdx = cursor.getColumnIndexOrThrow(ContactsContract.Contacts.LOOKUP_KEY)
            val nameIdx = cursor.getColumnIndexOrThrow(ContactsContract.Contacts.DISPLAY_NAME_PRIMARY)
            buildList {
                while (cursor.moveToNext() && size < MAX_CONTACTS) {
                    val name = cursor.getString(nameIdx)?.trim().orEmpty()
                    if (name.isBlank()) continue
                    val lookup = cursor.getString(lookupIdx)?.trim().orEmpty()
                    val id = cursor.getLong(idIdx).toString()
                    add(
                        KnownPerson(
                            id = "contact-${lookup.ifBlank { id }}",
                            name = name,
                        ),
                    )
                }
            }
        }.orEmpty()
    }

    private fun readContactOrganizations(): List<String> {
        val projection = arrayOf(ContactsContract.CommonDataKinds.Organization.COMPANY)
        val selection = "${ContactsContract.Data.MIMETYPE} = ?"
        val args = arrayOf(ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE)
        return context.contentResolver.query(
            ContactsContract.Data.CONTENT_URI,
            projection,
            selection,
            args,
            null,
        )?.use { cursor ->
            val companyIdx = cursor.getColumnIndexOrThrow(
                ContactsContract.CommonDataKinds.Organization.COMPANY,
            )
            buildSet {
                while (cursor.moveToNext() && size < MAX_ORGS) {
                    cursor.getString(companyIdx)?.trim()?.takeIf { it.isNotBlank() }?.let(::add)
                }
            }.toList().sorted()
        }.orEmpty()
    }

    private fun readCalendar(nowMs: Long): PersonalContextImport {
        val begin = nowMs - THIRTY_DAYS_MS
        val end = nowMs + SIXTY_DAYS_MS
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also { builder ->
            ContentUris.appendId(builder, begin)
            ContentUris.appendId(builder, end)
        }.build()
        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
        )
        val eventTitles = LinkedHashMap<Long, String>()
        context.contentResolver.query(
            uri,
            projection,
            null,
            null,
            "${CalendarContract.Instances.BEGIN} ASC",
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(CalendarContract.Instances.EVENT_ID)
            val titleIdx = cursor.getColumnIndexOrThrow(CalendarContract.Instances.TITLE)
            while (cursor.moveToNext() && eventTitles.size < MAX_EVENTS) {
                val title = cursor.getString(titleIdx)?.trim().orEmpty()
                if (title.isBlank()) continue
                eventTitles[cursor.getLong(idIdx)] = title
            }
        }
        val attendees = eventTitles.keys.flatMap { eventId -> readAttendees(eventId) }.distinct()
        return PersonalContextImport(
            people = attendees.map { KnownPerson(id = "calendar-attendee-${it.hashCode()}", name = it) },
            topics = eventTitles.values.distinct(),
            terms = (eventTitles.values + attendees).distinct().map { VocabTerm(it) },
        )
    }

    private fun readAttendees(eventId: Long): List<String> {
        val projection = arrayOf(CalendarContract.Attendees.ATTENDEE_NAME)
        return CalendarContract.Attendees.query(context.contentResolver, eventId, projection)
            ?.use { cursor ->
                val nameIdx = cursor.getColumnIndexOrThrow(CalendarContract.Attendees.ATTENDEE_NAME)
                buildList {
                    while (cursor.moveToNext() && size < MAX_ATTENDEES_PER_EVENT) {
                        cursor.getString(nameIdx)?.trim()?.takeIf { it.isNotBlank() }?.let(::add)
                    }
                }
            }.orEmpty()
    }

    companion object {
        private const val MAX_CONTACTS = 500
        private const val MAX_ORGS = 100
        private const val MAX_EVENTS = 120
        private const val MAX_ATTENDEES_PER_EVENT = 20
        private const val THIRTY_DAYS_MS = 30L * 24 * 60 * 60 * 1000
        private const val SIXTY_DAYS_MS = 60L * 24 * 60 * 60 * 1000
    }
}
