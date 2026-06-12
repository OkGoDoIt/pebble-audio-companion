package dev.audiocompanion.app.ui

import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.number
import kotlinx.datetime.toLocalDateTime
import kotlin.time.Instant

/** Plain-language time/duration formatting for timeline rows and detail views. */
object Formatting {

    fun localDateTime(epochMs: Long, zone: TimeZone = TimeZone.currentSystemDefault()): LocalDateTime =
        Instant.fromEpochMilliseconds(epochMs).toLocalDateTime(zone)

    /** "9:12 AM" */
    fun timeOfDay(epochMs: Long): String {
        val time = localDateTime(epochMs)
        val hour12 = when (val h = time.hour % 12) {
            0 -> 12
            else -> h
        }
        val minute = time.minute.toString().padStart(2, '0')
        val amPm = if (time.hour < 12) "AM" else "PM"
        return "$hour12:$minute $amPm"
    }

    /** "Jun 11" (adds ", 2026" when not the current year). */
    fun shortDate(epochMs: Long, nowMs: Long): String {
        val date = localDateTime(epochMs).date
        val nowDate = localDateTime(nowMs).date
        val month = MONTHS[date.month.number - 1]
        return if (date.year == nowDate.year) "$month ${date.day}" else "$month ${date.day}, ${date.year}"
    }

    /** "38 sec", "5 min", "1 hr 12 min" */
    fun duration(durationMs: Long): String {
        val totalSeconds = durationMs / 1000
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return when {
            hours > 0 && minutes > 0 -> "$hours hr $minutes min"
            hours > 0 -> "$hours hr"
            minutes > 0 -> "$minutes min"
            else -> "$seconds sec"
        }
    }

    /** "just now", "8 sec ago", "5 min ago", "2 hr ago", or a short date. */
    fun relativeTime(epochMs: Long, nowMs: Long): String {
        val deltaMs = nowMs - epochMs
        return when {
            deltaMs < 5_000 -> "just now"
            deltaMs < 60_000 -> "${deltaMs / 1000} sec ago"
            deltaMs < 3_600_000 -> "${deltaMs / 60_000} min ago"
            deltaMs < 24 * 3_600_000 -> "${deltaMs / 3_600_000} hr ago"
            else -> shortDate(epochMs, nowMs)
        }
    }

    /** True when both timestamps fall on the same local calendar day. */
    fun isSameLocalDay(aMs: Long, bMs: Long): Boolean =
        localDateTime(aMs).date == localDateTime(bMs).date

    /** "1.6 GB", "320 MB", "12 KB" */
    fun storageSize(bytes: Long): String = when {
        bytes >= 1L shl 30 -> "${formatOneDecimal(bytes.toDouble() / (1L shl 30))} GB"
        bytes >= 1L shl 20 -> "${(bytes / (1L shl 20))} MB"
        else -> "${(bytes / 1024).coerceAtLeast(0)} KB"
    }

    private fun formatOneDecimal(value: Double): String {
        val tenths = (value * 10).toInt()
        return "${tenths / 10}.${tenths % 10}"
    }

    private val MONTHS = listOf(
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    )
}
