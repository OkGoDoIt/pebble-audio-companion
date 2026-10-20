import AppDB
import AppIntents
import Foundation
import Intelligence
import UserNotifications

// "Notify me when my recap is ready" (Roger, 2026-10-21; off by default).
//
// A recap is rewritten all day as the day goes on, so "ready" means the day is OVER: the
// notification is about the logical day that just ended (5 AM boundary), posted once, with that
// day's headline. It is decided at the one place recaps are written (`DailyRecapStore`'s
// `didWrite`, which also fires when the headline lands), never by polling:
//
//   • a write of yesterday's recap or headline is yesterday becoming ready;
//   • the first write of today's recap is the sign yesterday is finished, which covers the
//     common case where yesterday's last write happened before midnight.
//
// Never twice for one day, never for an empty recap or one that only says nothing was
// recorded, never before the headline has been written (it is the body), and never without
// permission — which is asked for only when the person turns the switch on.

/// What one recap-ready notification says and opens.
struct RecapNotificationContent: Equatable, Sendable {
    var dateKey: String
    /// "Tuesday's recap"
    var title: String
    /// The day's headline.
    var body: String
    /// That day in History.
    var route: Route

    /// One per day at the OS level too: a second post for the day replaces, never adds.
    var identifier: String { "recap-\(dateKey)" }
}

enum RecapNotificationRules {
    /// The day a recap write can make ready: the logical day that just ended.
    static func candidateDay(nowMs: Int64, timeZoneID: String) -> String {
        // Ask's own "yesterday": calendar arithmetic on today's key, so a 23- or 25-hour day
        // cannot shift it.
        askScopeDateKeyRange(.yesterday, nowMs: nowMs, timeZoneID: timeZoneID)?.lowerBound
            ?? LogicalDay.dateKey(forMs: nowMs - 86_400_000, timeZoneID: timeZoneID)
    }

    /// Only a write of the candidate day, or of a later one (today), says anything about it.
    static func writeConcerns(_ writtenKey: String, candidate: String) -> Bool {
        writtenKey >= candidate
    }

    /// Nil when the recap should not notify (yet): it is empty, it only says nothing was
    /// recorded, or its headline is still owed. A brief pass that finished without a usable
    /// headline is not waited on: the condensed recap, or its first sentence, stands in.
    static func content(for recap: DailyRecap, timeZoneID: String) -> RecapNotificationContent? {
        let text = recap.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !saysNothingRecorded(text) else { return nil }
        let headline = recap.headline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: String
        if !headline.isEmpty {
            body = headline
        } else if recap.briefOfHash == RecapCondenser.fingerprint(recap.text) {
            body = fallbackBody(shortText: recap.shortText, text: text)
        } else {
            return nil
        }
        guard !saysNothingRecorded(body) else { return nil }
        return RecapNotificationContent(
            dateKey: recap.dateKey,
            title: Copy.RecapNotification.title(weekday: weekday(of: recap.dateKey, timeZoneID: timeZoneID)),
            body: body,
            route: .history(date: recap.dateKey, level: nil))
    }

    /// A recap the model wrote about a day with nothing in it. Only short texts are read this
    /// way: a long recap that mentions "nothing was recorded about the budget" is a real day.
    static func saysNothingRecorded(_ text: String) -> Bool {
        guard text.count <= 280 else { return false }
        let lowered = text.lowercased()
        return [
            "nothing was recorded", "nothing recorded", "no conversations were recorded",
            "no conversation was recorded", "no conversations", "nothing to recap",
            "nothing was said", "no speech",
        ].contains(where: lowered.contains)
    }

    static func fallbackBody(shortText: String?, text: String) -> String {
        let source = shortText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? text
        let firstSentence = source.split(
            omittingEmptySubsequences: true, whereSeparator: { ".!?\n".contains($0) }
        ).first.map { String($0).trimmingCharacters(in: .whitespaces) + "." } ?? source
        return firstSentence.count <= 140 ? firstSentence : String(firstSentence.prefix(139)) + "…"
    }

    /// "Tuesday" for "2026-10-20", read at midday so no zone puts it on the next day.
    static func weekday(of dateKey: String, timeZoneID: String) -> String {
        let zone = TimeZone(identifier: timeZoneID) ?? .current
        guard let bounds = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone.identifier) else {
            return dateKey
        }
        let midday = Date(timeIntervalSince1970: Double(bounds.startMs) / 1000 + 7 * 3600)
        return midday.formatted(Date.FormatStyle(timeZone: zone).weekday(.wide))
    }
}

/// Posts a recap notification; faked in tests.
protocol RecapNotificationPosting: Sendable {
    /// Whether iOS will show it. Never asks: asking is the Settings switch's job.
    func isAuthorized() async -> Bool
    func post(_ content: RecapNotificationContent) async
}

struct SystemRecapNotificationPoster: RecapNotificationPosting {
    func isAuthorized() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    func post(_ recap: RecapNotificationContent) async {
        let content = UNMutableNotificationContent()
        content.title = recap.title
        content.body = recap.body
        // The same payload key the loss alert uses, so a tap goes through the one router.
        content.userInfo = [UserNotificationLossNotifier.routeUserInfoKey: recap.route.url.absoluteString]
        // News about yesterday, not an alarm: no sound, nothing that lights the screen.
        content.interruptionLevel = .passive
        if #available(iOS 27, *) {
            // So Siri and Apple Intelligence can refer to the recap it is about.
            content.appEntityIdentifiers = [
                EntityIdentifier(
                    for: RecapEntity.self, identifier: RecapEntity.id(dateKey: recap.dateKey))
            ]
        }
        let request = UNNotificationRequest(
            identifier: recap.identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

actor RecapReadyNotifier {
    private static let notifiedKey = "recap_notified_days"
    /// Enough to never repeat a day; old keys only take space.
    private static let rememberedDays = 14

    private let isEnabled: @Sendable () -> Bool
    private let recap: @Sendable (String) async -> DailyRecap?
    private let poster: any RecapNotificationPosting
    private let defaults: UserDefaults
    private let nowMs: @Sendable () -> Int64
    private let timeZoneID: @Sendable () -> String

    init(
        isEnabled: @escaping @Sendable () -> Bool,
        recap: @escaping @Sendable (String) async -> DailyRecap?,
        poster: any RecapNotificationPosting = SystemRecapNotificationPoster(),
        defaultsSuite: String? = nil,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        timeZoneID: @escaping @Sendable () -> String = { TimeZone.current.identifier }
    ) {
        self.isEnabled = isEnabled
        self.recap = recap
        self.poster = poster
        // The app's own defaults (a suite only in tests): which days have notified is this
        // app's business, not the App Group's.
        self.defaults = defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.nowMs = nowMs
        self.timeZoneID = timeZoneID
    }

    /// `DailyRecapStore.didWrite`. Cheap when it has nothing to do: a defaults read when the
    /// switch is off, a set lookup once the day has notified.
    func recapWritten(dateKey: String) async {
        guard isEnabled() else { return }
        let zone = timeZoneID()
        let day = RecapNotificationRules.candidateDay(nowMs: nowMs(), timeZoneID: zone)
        guard RecapNotificationRules.writeConcerns(dateKey, candidate: day) else { return }
        var notified = defaults.stringArray(forKey: Self.notifiedKey) ?? []
        guard !notified.contains(day) else { return }
        guard let stored = await recap(day),
            let content = RecapNotificationRules.content(for: stored, timeZoneID: zone)
        else { return }
        guard await poster.isAuthorized() else { return }
        notified.append(day)
        defaults.set(Array(notified.suffix(Self.rememberedDays)), forKey: Self.notifiedKey)
        await poster.post(content)
        AppRuntimeLog.shared.record("recap notification · day=\(day)")
    }
}
