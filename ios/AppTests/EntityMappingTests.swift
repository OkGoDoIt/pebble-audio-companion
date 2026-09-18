import AppDB
import Foundation
import SearchKit
import Testing

// The decisions behind the Siri entities, pinned on both OS versions: the entity types are
// iOS 27-only, the rules about what they say are not.

@Suite("entity mapping")
struct EntityMappingTests {

    // MARK: - Title and content

    @Test func aBlankTitleFallsBackToTheNeutralLabel() {
        #expect(EntityMapping.conversationTitle(nil) == "Conversation")
        #expect(EntityMapping.conversationTitle("   ") == "Conversation")
        #expect(EntityMapping.conversationTitle(" Coffee with Dana ") == "Coffee with Dana")
    }

    /// The transcript is part of the content only under `.full`; the summary always is.
    @Test(arguments: SystemSearchVisibility.allCases)
    func contentCarriesTheTranscriptOnlyWhenTheSettingAllowsText(visibility: SystemSearchVisibility) {
        let content = EntityMapping.conversationContent(
            summary: "Talked about the roadmap.", transcript: "the words", visibility: visibility)
        if visibility.includesText {
            #expect(content == "Talked about the roadmap.\n\nthe words")
        } else {
            #expect(content == "Talked about the roadmap.")
        }
    }

    @Test func contentIsNilWhenThereIsNothingToSay() {
        #expect(EntityMapping.conversationContent(summary: nil, transcript: nil, visibility: .full) == nil)
        #expect(EntityMapping.conversationContent(summary: " ", transcript: nil, visibility: .full) == nil)
        #expect(EntityMapping.conversationContent(summary: nil, transcript: "words", visibility: .full) == "words")
        #expect(EntityMapping.conversationContent(summary: nil, transcript: "words", visibility: .summaries) == nil)
    }

    @Test func theIndexedTranscriptExistsOnlyUnderFull() {
        #expect(EntityMapping.indexedTranscript("words", visibility: .full) == "words")
        #expect(EntityMapping.indexedTranscript("words", visibility: .summaries) == nil)
        #expect(EntityMapping.indexedTranscript("words", visibility: .off) == nil)
        #expect(EntityMapping.indexedTranscript("", visibility: .full) == nil)
    }

    // MARK: - Times

    /// The subtitle's clock time is in the RECORDED zone (Q16): the same instant reads as
    /// different times in Tokyo and New York, and neither depends on the device zone.
    @Test func theSubtitleTimeIsInTheRecordedZone() {
        // 2026-09-18 00:00:00 UTC.
        let ms: Int64 = 1_789_689_600_000
        let tokyo = EntityMapping.time(ms: ms, timeZoneID: "Asia/Tokyo")
        let newYork = EntityMapping.time(ms: ms, timeZoneID: "America/New_York")
        #expect(tokyo != newYork)
        // 09:00 in Tokyo, 20:00 the evening before in New York — spelled by the same style
        // the mapping uses, so the assertion holds in a 12- or 24-hour locale.
        let date = Date(timeIntervalSince1970: 1_789_689_600)
        #expect(tokyo == date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: TimeZone(identifier: "Asia/Tokyo")!)))
        #expect(newYork == date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: TimeZone(identifier: "America/New_York")!)))
    }

    @Test func theSubtitleLeadsWithTheLibraryDayLabel() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let todayKey = LogicalDay.dateKey(forMs: nowMs, timeZoneID: TimeZone.current.identifier)
        let subtitle = EntityMapping.conversationSubtitle(
            startMs: nowMs, dateKey: todayKey, timeZoneID: TimeZone.current.identifier)
        #expect(subtitle.hasPrefix("Today · "))
    }

    @Test func anUnknownZoneFallsBackToTheDeviceZoneRatherThanCrashing() {
        let ms: Int64 = 1_789_689_600_000
        #expect(
            EntityMapping.time(ms: ms, timeZoneID: "Nowhere/Nonsense")
                == EntityMapping.time(ms: ms, timeZoneID: TimeZone.current.identifier))
    }

    // MARK: - Day folders

    @Test func dayFolderNamesAreTodayYesterdayThenTheFullDate() {
        let zone = "UTC"
        let nowMs: Int64 = 1_789_689_600_000 + 12 * 3_600_000  // 2026-09-18 12:00 UTC
        let today = LogicalDay.dateKey(forMs: nowMs, timeZoneID: zone)
        let yesterday = LogicalDay.dateKey(forMs: nowMs - 86_400_000, timeZoneID: zone)
        #expect(EntityMapping.dayFolderName(dateKey: today, nowMs: nowMs, timeZoneID: zone) == "Today")
        #expect(EntityMapping.dayFolderName(dateKey: yesterday, nowMs: nowMs, timeZoneID: zone) == "Yesterday")
        let older = EntityMapping.dayFolderName(dateKey: "2026-08-27", nowMs: nowMs, timeZoneID: zone)
        #expect(older.contains("2026"))
        #expect(older.contains("27"))
    }

    @Test func onlyWellFormedDayKeysAreDays() {
        #expect(EntityMapping.isDayKey("2026-09-18"))
        #expect(!EntityMapping.isDayKey("2026-9-18"))
        #expect(!EntityMapping.isDayKey("conv-abc"))
        #expect(!EntityMapping.isDayKey("2026-13-01"))
        #expect(!EntityMapping.isDayKey(""))
    }

    // MARK: - Reminders

    @Test func dueDatesAreDayGranularInTheDeviceZone() throws {
        let due = try #require(EntityMapping.dueDateComponents(dueAtMs: 1_789_689_600_000 + 15 * 3_600_000))
        #expect(due.year != nil && due.month != nil && due.day != nil)
        #expect(due.hour == nil)
        #expect(EntityMapping.dueDateComponents(dueAtMs: nil) == nil)
    }

    @Test func onlyHighPriorityIsFlagged() {
        #expect(EntityMapping.isFlagged(priority: .high))
        #expect(!EntityMapping.isFlagged(priority: .normal))
        #expect(!EntityMapping.isFlagged(priority: .low))
    }

    @Test func theReminderNoteIsTheWhyOrNothing() {
        #expect(EntityMapping.followUpNote(why: "  ") == nil)
        #expect(EntityMapping.followUpNote(why: nil) == nil)
        #expect(EntityMapping.followUpNote(why: " because Dana asked ") == "because Dana asked")
    }

    // MARK: - Spotlight

    @Test func hiddenFromSpotlightExactlyWhenTheSettingIsOff() {
        #expect(EntityMapping.hideInSpotlight(.off))
        #expect(!EntityMapping.hideInSpotlight(.summaries))
        #expect(!EntityMapping.hideInSpotlight(.full))
    }

    /// The synchronous provider the entities read; installed by the composition, replaceable
    /// here, and defaulting to the fresh-install value.
    @Test func theVisibilityProviderIsReplaceable() {
        EntityVisibility.install { .summaries }
        #expect(EntityVisibility.current() == .summaries)
        EntityVisibility.install { .default }
        #expect(EntityVisibility.current() == .full)
    }

    // MARK: - The catch-up sentence

    @Test func theCatchUpDialogCountsWhatIsWaiting() {
        guard #available(iOS 27, *) else { return }
        #expect(
            ProcessNowIntent.dialog(for: PipelineBacklog(queued: 0, awaitingEnrichment: 0))
                == "Nothing is waiting. Everything recorded so far is done.")
        #expect(
            ProcessNowIntent.dialog(for: PipelineBacklog(queued: 1, awaitingEnrichment: 0))
                == "Catching up: 1 recording to transcribe.")
        #expect(
            ProcessNowIntent.dialog(for: PipelineBacklog(queued: 3, awaitingEnrichment: 2))
                == "Catching up: 3 recordings to transcribe and 2 conversations to summarise.")
        #expect(
            ProcessNowIntent.dialog(for: PipelineBacklog(queued: 0, awaitingEnrichment: 1))
                == "Catching up: 1 conversation to summarise.")
    }
}
