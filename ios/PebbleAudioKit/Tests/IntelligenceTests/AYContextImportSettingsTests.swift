import Foundation
import Testing

@testable import Intelligence

// Per-source import control. Every case here is one where getting it wrong sends more of the
// user's address book or calendar into a cloud prompt than they chose, or silently keeps
// sending data from a source they switched off.

@Suite("AY · import selection")
struct AYContextImportSelectionTests {

    @Test func allFollowsWhateverTheSourceOffers() {
        let selection = ContextImportSelection.all
        #expect(selection.resolved(against: ["a", "b"]) == ["a", "b"])
        // A calendar subscribed to later is included without the user coming back.
        #expect(selection.resolved(against: ["a", "b", "c"]) == ["a", "b", "c"])
        #expect(!selection.selectsNothing)
    }

    /// The one that a nil-means-everything encoding gets backwards.
    @Test func untickingEverythingImportsNothing() {
        let selection = ContextImportSelection.only([])
        #expect(selection.selectsNothing)
        #expect(selection.resolved(against: ["a", "b", "c"]).isEmpty)
        #expect(!selection.includes("a"))
    }

    @Test func onlyKeepsTheSourceOrderAndDropsUnknownIds() {
        let selection = ContextImportSelection.only(["c", "a", "gone"])
        #expect(selection.resolved(against: ["a", "b", "c"]) == ["a", "c"])
    }

    @Test func pruningForgetsIdsTheSourceNoLongerHas() {
        let pruned = ContextImportSelection.only(["a", "deleted"]).pruned(against: ["a", "b"])
        #expect(pruned == .only(["a"]))
        #expect(ContextImportSelection.all.pruned(against: ["a"]) == .all)
    }

    @Test func untickingOneFromAllKeepsTheRest() {
        let selection = ContextImportSelection.all.toggling("b", available: ["a", "b", "c"])
        #expect(selection == .only(["a", "c"]))
    }

    /// Ticking the last one back collapses to `all`, so the "All" row is checked when
    /// everything is checked — and the selection resumes following the source.
    @Test func tickingEverythingBackCollapsesToAll() {
        var selection = ContextImportSelection.only(["a"])
        selection = selection.toggling("b", available: ["a", "b"])
        #expect(selection == .all)
    }

    @Test func togglingIgnoresIdsTheSourceNoLongerHas() {
        let selection = ContextImportSelection.only(["a", "stale"])
            .toggling("b", available: ["a", "b"])
        #expect(selection == .all)
    }

    @Test func togglingWithNothingAvailableCannotBecomeAll() {
        // An empty picker must not turn an explicit empty selection into "import everything".
        let selection = ContextImportSelection.only([]).toggling("x", available: [])
        #expect(selection == .only(["x"]))
    }

    @Test func selectionSurvivesAJsonRoundTrip() throws {
        for selection in [
            ContextImportSelection.all, .only([]), .only(["a", "b"]),
        ] {
            let data = try JSONEncoder().encode(selection)
            let decoded = try JSONDecoder().decode(ContextImportSelection.self, from: data)
            #expect(decoded == selection, "round trip changed \(selection)")
        }
    }
}

@Suite("AY · import settings")
struct AYContextImportSettingsTests {
    private let day: Int64 = 24 * 60 * 60 * 1000

    @Test func defaultsAreOffAndCalendarReachesBothWays() {
        let settings = ContextImportSettings()
        #expect(!settings.contacts.isEnabled)
        #expect(!settings.calendar.isEnabled)
        #expect(settings.calendar.pastDays > 0)
        #expect(settings.calendar.futureDays > 0)
    }

    @Test func subscriptReadsAndWritesTheRightSource() {
        var settings = ContextImportSettings()
        settings[.contacts].isEnabled = true
        #expect(settings.contacts.isEnabled)
        #expect(!settings.calendar.isEnabled)
        #expect(settings[.calendar] == settings.calendar)
    }

    @Test func calendarWindowSpansThePastAndFutureDays() {
        let settings = ContextSourceSettings(pastDays: 30, futureDays: 21)
        let window = settings.calendarWindow(nowMs: 1_000 * day)
        #expect(window.startMs == 970 * day)
        #expect(window.endMs == 1_021 * day)
    }

    @Test func negativeSpansCollapseRatherThanInvert() {
        let settings = ContextSourceSettings(pastDays: -5, futureDays: -5)
        let window = settings.calendarWindow(nowMs: 500 * day)
        #expect(window.startMs == 500 * day)
        #expect(window.endMs == 500 * day)
    }

    @Test func autoRefreshNeverRunsForASourceThatIsOff() {
        let off = ContextSourceSettings(isEnabled: false, lastImportedAtMs: nil)
        #expect(!off.isDueForAutoRefresh(nowMs: 10 * day, staleAfterMs: day))
    }

    @Test func autoRefreshIsDueWhenNothingHasBeenImportedYet() {
        let fresh = ContextSourceSettings(isEnabled: true, lastImportedAtMs: nil)
        #expect(fresh.isDueForAutoRefresh(nowMs: 10 * day, staleAfterMs: day))
    }

    @Test func autoRefreshWaitsOutTheStalenessWindow() {
        let settings = ContextSourceSettings(isEnabled: true, lastImportedAtMs: 9 * day)
        #expect(!settings.isDueForAutoRefresh(nowMs: 9 * day + 1000, staleAfterMs: day))
        #expect(settings.isDueForAutoRefresh(nowMs: 10 * day, staleAfterMs: day))
    }

    @Test func settingsSurviveAJsonRoundTrip() throws {
        var settings = ContextImportSettings()
        settings.contacts = ContextSourceSettings(
            isEnabled: true, selection: .only(["group:1"]), lastImportedAtMs: 42,
            lastFailure: .permissionDenied, importedCount: 7
        )
        settings.calendar = ContextSourceSettings(
            isEnabled: true, selection: .only([]), pastDays: 7, futureDays: 90,
            importedCount: 3, contributedTerms: ["Standup"]
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ContextImportSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func anEmptyFileDecodesToTheDefaults() throws {
        let decoded = try JSONDecoder().decode(
            ContextImportSettings.self, from: Data("{}".utf8))
        #expect(decoded == ContextImportSettings())
    }

    // MARK: Adoption of a pre-per-source import

    /// Upgrading must not show "Off" for sources whose data is still in every prompt.
    @Test func adoptionTurnsAnExistingImportOn() {
        let context = PersonalContext(
            people: [KnownPerson(id: "1", name: "Ada")],
            orgs: ["Board meeting", "Dentist"],
            sources: [
                ContextSource(id: "contacts", kind: .contacts, label: "Contacts", importedAtMs: 5),
                ContextSource(id: "calendar", kind: .calendar, label: "Calendar", importedAtMs: 9),
            ]
        )
        let settings = ContextImportSettings.adopting(context)
        #expect(settings.contacts.isEnabled)
        #expect(settings.contacts.lastImportedAtMs == 5)
        #expect(settings.contacts.importedCount == 1)
        #expect(settings.calendar.isEnabled)
        #expect(settings.calendar.lastImportedAtMs == 9)
        // Claiming the existing orgs is what lets the next refresh replace them instead of
        // piling on top, which is the bug the old import shipped with.
        #expect(settings.calendar.contributedTerms == ["Board meeting", "Dentist"])
    }

    @Test func adoptionClaimsPeopleEvenWithoutAProvenanceRecord() {
        let context = PersonalContext(people: [KnownPerson(id: "1", name: "Ada")])
        let settings = ContextImportSettings.adopting(context)
        #expect(settings.contacts.isEnabled)
        #expect(settings.contacts.lastImportedAtMs == nil)
    }

    @Test func adoptionOfAnEmptyContextLeavesEverythingOff() {
        let settings = ContextImportSettings.adopting(PersonalContext(profileText: "hello"))
        #expect(settings == ContextImportSettings())
    }
}

@Suite("AY · merging an import into the context")
struct AYContextImportMergeTests {

    @Test func termsAreTrimmedDedupedAndCapped() {
        let cleaned = ContextImportMerge.cleanTerms(
            ["  Standup  ", "standup", "", "   ", "Board"], limit: 10)
        #expect(cleaned == ["Standup", "Board"])
        #expect(ContextImportMerge.cleanTerms(["a", "b", "c"], limit: 2) == ["a", "b"])
    }

    /// The accretion bug, stated as a test: a second import must replace the first one's
    /// contribution rather than union with it.
    @Test func reimportingReplacesTheSourcesOwnContribution() {
        let existing = ["Old event", "Older event"]
        let merged = ContextImportMerge.replacing(
            existing, with: ["New event"], in: existing)
        #expect(merged == ["New event"])
    }

    @Test func removingOneSourceLeavesEveryoneElsesEntries() {
        let merged = ContextImportMerge.replacing(
            ["Calendar entry"], with: [], in: ["Riverside Hall", "Calendar entry"])
        #expect(merged == ["Riverside Hall"])
    }

    @Test func replacingIsCaseInsensitiveAndDoesNotDuplicate() {
        let merged = ContextImportMerge.replacing(
            ["standup"], with: ["Standup", "Retro"], in: ["Standup", "Riverside Hall"])
        #expect(merged == ["Riverside Hall", "Standup", "Retro"])
    }

    @Test func recordsAreSingularPerSource() {
        var context = PersonalContext()
        ContextImportMerge.setRecord(.calendar, present: true, atMs: 1, in: &context)
        ContextImportMerge.setRecord(.calendar, present: true, atMs: 2, in: &context)
        #expect(context.sources.count == 1)
        #expect(context.sources.first?.importedAtMs == 2)

        ContextImportMerge.setRecord(.contacts, present: true, atMs: 3, in: &context)
        #expect(context.sources.count == 2)

        ContextImportMerge.setRecord(.calendar, present: false, atMs: 4, in: &context)
        #expect(context.sources.map(\.kind) == [.contacts])
    }
}

@Suite("AY · import settings store")
struct AYContextImportStoreTests {

    @Test func loadReturnsNilBeforeAnythingIsWritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileContextImportSettingsStore(root: root)
        // Nil, not defaults: the caller needs the distinction to know whether to adopt an
        // import made by the old one-shot code.
        #expect(store.load() == nil)
    }

    @Test func savedSettingsComeBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileContextImportSettingsStore(root: root)

        var settings = ContextImportSettings()
        settings.calendar.isEnabled = true
        settings.calendar.selection = .only(["work"])
        try store.save(settings)

        #expect(store.load() == settings)
        try store.clear()
        #expect(store.load() == nil)
    }
}
