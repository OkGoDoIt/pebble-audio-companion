import AppDB
import Foundation
import SearchKit

// The decisions behind the iOS 27 entities, as pure functions over the snapshots. The entity
// types themselves are `@available(iOS 27, *)` and can only be exercised on that OS; every
// rule about WHAT they say — the title fallback, what "content" holds at each visibility, the
// subtitle's wording, the reminder mapping — lives here so `EntityMappingTests` pins it on
// both simulators, and so the four entities cannot each drift into their own version of it.

enum EntityMapping {
    /// Never a raw id as a user-visible title; the same neutral label the Library row and the
    /// Spotlight donation use.
    static let untitledConversation = "Conversation"

    static func conversationTitle(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? untitledConversation : trimmed
    }

    /// The note-schema `content` of a conversation: the summary, and — only when the setting
    /// lets text out — the transcript under it. The snapshot already carries a nil transcript
    /// under `.summaries`/`.off`; the check here is belt-and-braces so a caller that built a
    /// snapshot by hand cannot leak a transcript past the setting.
    static func conversationContent(
        summary: String?, transcript: String?, visibility: SystemSearchVisibility
    ) -> String? {
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = visibility.includesText ? transcript : nil
        switch (summary?.isEmpty == false ? summary : nil, transcript) {
        case (nil, nil): return nil
        case (let s?, nil): return s
        case (nil, let t?): return t
        case (let s?, let t?): return s + "\n\n" + t
        }
    }

    /// The transcript as an indexed property: present only under `.full`.
    static func indexedTranscript(_ transcript: String?, visibility: SystemSearchVisibility)
        -> String?
    {
        guard visibility.includesText, let transcript, !transcript.isEmpty else { return nil }
        return transcript
    }

    /// "Today · 9:12 AM" — the day in the same words the Library uses for its section headers,
    /// the time in the RECORDED zone (Q16), so a conversation from a trip reads as the time it
    /// happened, not the time it would be here.
    static func conversationSubtitle(startMs: Int64, dateKey: String, timeZoneID: String)
        -> String
    {
        "\(TimeFmt.dayLabel(dateKey: dateKey)) · \(time(ms: startMs, timeZoneID: timeZoneID))"
    }

    /// Short clock time in a named zone; falls back to the device zone for an unknown id.
    static func time(ms: Int64, timeZoneID: String) -> String {
        let zone = TimeZone(identifier: timeZoneID) ?? .current
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }

    /// A recap's name: the day, in the Library's words ("Today", "Yesterday", "September 17").
    static func recapTitle(dateKey: String) -> String {
        TimeFmt.dayLabel(dateKey: dateKey)
    }

    /// A day folder's name. "Today"/"Yesterday" while they are that; otherwise the full date
    /// with its year, because a folder named "August 27" is ambiguous a year on and the
    /// Library's section header, which drops the year, is read in a list that has one.
    static func dayFolderName(dateKey: String, nowMs: Int64, timeZoneID: String) -> String {
        if dateKey == LogicalDay.dateKey(forMs: nowMs, timeZoneID: timeZoneID) { return "Today" }
        if dateKey == LogicalDay.dateKey(forMs: nowMs - 86_400_000, timeZoneID: timeZoneID) {
            return "Yesterday"
        }
        guard let bounds = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: timeZoneID) else {
            return dateKey
        }
        return date(ms: bounds.startMs).formatted(
            Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: timeZoneID) ?? .current)
        )
    }

    /// A day key is `YYYY-MM-DD` and nothing else resolves to a day folder.
    static func isDayKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }
        return year > 0 && (1...12).contains(month) && (1...31).contains(day)
    }

    /// The reminder schema's due date is `DateComponents`; a follow-up stores a millisecond
    /// instant. Day granularity in the device zone, because the app's own due-date picker is a
    /// day picker and a reminder due "at 00:00" would be a fiction.
    static func dueDateComponents(dueAtMs: Int64?) -> DateComponents? {
        guard let dueAtMs else { return nil }
        let date = Date(timeIntervalSince1970: Double(dueAtMs) / 1000)
        return Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    /// `isFlagged` is the only priority the reminder schema has; only "high" earns it.
    static func isFlagged(priority: FollowUpPriority) -> Bool { priority == .high }

    /// A follow-up's reminder note: the "why" the extractor recorded, when there is one.
    static func followUpNote(why: String?) -> String? {
        let trimmed = why?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The single list every follow-up belongs to: the reminder schema requires one.
    static let followUpListId = "follow-ups"
    static let followUpListName = "Follow-ups"

    /// Whether the entity may appear in Spotlight at all — `IndexedEntity.hideInSpotlight`.
    static func hideInSpotlight(_ visibility: SystemSearchVisibility) -> Bool {
        !visibility.donates
    }

    static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func optionalDate(ms: Int64?) -> Date? { ms.map(date(ms:)) }
}
