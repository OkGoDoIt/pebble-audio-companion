import Foundation
import Testing

// The one defect shape this app keeps shipping:
//
//   a LIVE data-source method is a stub while its MOCK counterpart is complete.
//
// Every screen renders the mock in previews and in `-demo-data`, so the stub is invisible until
// someone uses the app with a watch. Three of them shipped on the same day: `LiveWorld.search`
// accepted a `scope` and ignored it, `LiveTodayDataSource.conversationRow` passed `snippet: nil`
// where `PreviewTodayData` supplies the rolling live line, and `LiveWorld.display` passed
// `momentsLabel: ""` where `MockWorld` builds the real one. A fake-backed test cannot catch any
// of these — it exercises the half that works.
//
// So this suite compares the two implementations of every data-source protocol directly. It
// reads them as SOURCE, because a live source cannot be constructed here at all: each one is
// built from `AppComposition`, which opens the App Group database, the segment spool and Core
// Bluetooth, none of which exists in a test bundle. What can be read off the source is exactly
// the shape of the defect — an argument that is never mentioned, a body that returns a literal,
// a field that is hard-coded where the mock fills it in.
//
// Every gap is either a failure or a line in `exemptions`, and `exemptions` is checked for
// staleness: an entry that is no longer needed fails the suite. Nothing here can be silent.

@Suite("live vs mock conformance")
struct LiveMockConformanceTests {

    // MARK: - What is paired with what

    struct Pair {
        var protocolName: String
        var live: String
        var mock: String
    }

    /// The three files that declare the app's data-source seams.
    static let protocolFiles = [
        "App/Screens/Library/DataSources.swift",
        "App/Screens/Settings/SettingsDataSources.swift",
        "App/Screens/Today/TodayDisplayModels.swift",
    ]

    static let liveFiles = [
        "App/Runtime/LiveLibraryDataSources.swift",
        "App/Runtime/LiveTodayDataSource.swift",
        "App/Runtime/LiveSettingsDataSources.swift",
    ]

    static let mockFiles = [
        "App/Screens/Library/MockDataSources.swift",
        "App/Screens/Settings/SettingsDataSources.swift",
        "App/Screens/Today/PreviewTodayData.swift",
    ]

    /// Every protocol in `protocolFiles`, with the type that implements it for real and the
    /// type that stands in for it. `coversEveryProtocol` below fails if a protocol is added and
    /// not registered here — the pairing is not allowed to be optional.
    static let pairs: [Pair] = [
        Pair(protocolName: "LibraryDataSource", live: "LiveWorld", mock: "MockWorld"),
        Pair(protocolName: "SearchDataSource", live: "LiveWorld", mock: "MockWorld"),
        Pair(protocolName: "ConversationDataSource", live: "LiveWorld", mock: "MockWorld"),
        Pair(protocolName: "AskDataSource", live: "LiveWorld", mock: "MockWorld"),
        Pair(protocolName: "NotesDataSource", live: "LiveWorld", mock: "MockWorld"),
        Pair(protocolName: "TagEditorDataSource", live: "LiveWorld", mock: "MockWorld"),
        Pair(protocolName: "PeopleDataSource", live: "LiveWorld", mock: "MockWorld"),
        Pair(
            protocolName: "TodayDataSource", live: "LiveTodayDataSource",
            mock: "PreviewTodayData"),
        Pair(
            protocolName: "CaptureControlling", live: "LiveTodayDataSource",
            mock: "MockCaptureControl"),
        Pair(
            protocolName: "WatchStatusSource", live: "LiveWatchStatusSource",
            mock: "MockWatchStatusSource"),
        Pair(
            protocolName: "StorageStatsSource", live: "LiveStorageStatsSource",
            mock: "MockStorageStatsSource"),
        Pair(
            protocolName: "LocalModelManaging", live: "LiveLocalModelManager",
            mock: "MockLocalModelManager"),
        Pair(protocolName: "AboutYouSource", live: "LiveAboutYouSource", mock: "MockAboutYouSource"),
        Pair(
            protocolName: "DiagnosticsSource", live: "LiveDiagnosticsSource",
            mock: "MockDiagnosticsSource"),
        Pair(
            protocolName: "CloudHealthSource", live: "LiveCloudHealthSource",
            mock: "MockCloudHealthSource"),
        Pair(protocolName: "ApiKeyChecking", live: "LiveApiKeyChecker", mock: "MockApiKeyChecker"),
        // `ConversationPlayback` is a per-conversation engine handed back by
        // `ConversationDataSource.playback(id:)`, not a source with a mock twin: `MockWorld`
        // deliberately returns nil (it has no audio). Registered so `coversEveryProtocol` can
        // still see that a decision was made about it.
        Pair(protocolName: "ConversationPlayback", live: "", mock: ""),
    ]

    // MARK: - Exemptions

    enum Rule: String {
        /// The live body never mentions a declared parameter.
        case parameterHonoured
        /// The live body is empty, or returns a bare literal, where the mock does real work.
        case notAStub
        /// The live construction hard-codes a field the mock fills in.
        case fieldPopulated
    }

    struct Exemption: Hashable {
        /// `LiveWorld.search(query:scope:)`, or `LiveWorld.NoteDisplay.momentsLabel` for a field.
        var subject: String
        var rule: String
        var reason: String

        init(_ subject: String, _ rule: Rule, _ reason: String) {
            self.subject = subject
            self.rule = rule.rawValue
            self.reason = reason
        }

        var key: String { "\(rule)|\(subject)" }
    }

    /// The gaps that are known, deliberate and cannot be closed here.
    ///
    /// This list is the whole point of the exercise: a live method that genuinely cannot honour
    /// something has to say so out loud, by name, with a reason, in a place a reviewer reads —
    /// rather than passing silently because nobody wrote the test. Adding to it is a conscious
    /// act; `exemptionsAreAllStillNeeded` deletes the option of leaving a stale one behind.
    static let exemptions: [Exemption] = [
        Exemption(
            "LiveWatchStatusSource.batteryPercent", .notAStub,
            "Battery is not part of the audio-companion GATT service, so the watch never "
                + "reports one and the row stays blank. `MockWatchStatusSource` shows 78% only "
                + "so the artboard renders. Closing this needs a firmware characteristic."),
        Exemption(
            "LiveTodayDataSource.recap(_:aiModelName:rows:)", .fieldPopulated,
            "RecapBullet.citations: `DailyRecapEngine` returns prose, not grounded citations, "
                + "so the live recap detail has nothing to cite. The artboard shows chips. "
                + "Real gap, tracked — a fabricated citation would be worse than none."),
    ]

    // MARK: - Loading

    struct World {
        var requirements: [SourceRequirement]
        var live: [SourceMember]
        var mock: [SourceMember]
        var displayStructs: Set<String>

        func members(of type: String, in list: [SourceMember]) -> [SourceMember] {
            list.filter { $0.typeName == type }
        }
    }

    static func load() throws -> World {
        var requirements: [SourceRequirement] = []
        var displayStructs: Set<String> = []
        for file in protocolFiles {
            requirements += try SwiftSource.requirements(inFile: file)
            displayStructs.formUnion(try SwiftSource.structNames(inFile: file))
        }
        var live: [SourceMember] = []
        for file in liveFiles { live += try SwiftSource.members(inFile: file) }
        var mock: [SourceMember] = []
        for file in mockFiles { mock += try SwiftSource.members(inFile: file) }
        return World(
            requirements: requirements, live: live, mock: mock, displayStructs: displayStructs)
    }

    // MARK: - The scanner sees what it should

    /// Guards the suite against silently passing because the reader found nothing. Every check
    /// below is vacuously true on an empty index, so this is the load-bearing assertion.
    @Test func readsTheSourceTree() throws {
        let world = try Self.load()
        #expect(world.requirements.count > 40, "found \(world.requirements.count) requirements")
        #expect(
            world.live.filter { $0.typeName == "LiveWorld" }.count > 30,
            "found \(world.live.filter { $0.typeName == "LiveWorld" }.count) LiveWorld members")
        #expect(world.mock.contains { $0.typeName == "MockWorld" && $0.name == "search" })
        #expect(world.displayStructs.contains("ConversationRowDisplay"))
    }

    /// Every protocol declared in the three files is registered in `pairs`. A new data-source
    /// seam therefore cannot be added without deciding what its live and mock halves are.
    @Test func coversEveryProtocol() throws {
        var declared: Set<String> = []
        for file in Self.protocolFiles {
            let text = SwiftSource.sanitize(try SwiftSource.read(file))
            for (name, _) in SwiftSource.protocolBodies(in: text) where !name.isEmpty {
                declared.insert(name)
            }
        }
        let registered = Set(Self.pairs.map(\.protocolName))
        let unregistered = declared.subtracting(registered).sorted()
        #expect(
            unregistered.isEmpty,
            """
            These protocols have no live/mock pairing registered in `pairs`:
              \(unregistered.joined(separator: "\n  "))
            Add a Pair (live: "", mock: "") with a comment if one genuinely has no live twin.
            """)
    }

    // MARK: - Every requirement has a live implementation

    @Test func everyRequirementIsImplementedLive() throws {
        let world = try Self.load()
        var missing: [String] = []
        for pair in Self.pairs where !pair.live.isEmpty {
            let live = world.members(of: pair.live, in: world.live)
            for requirement in world.requirements
            where requirement.protocolName == pair.protocolName {
                let found = live.contains {
                    $0.name == requirement.name
                        && ($0.kind == .property || $0.labels == requirement.labels)
                }
                if !found {
                    missing.append("\(pair.live).\(requirement.signature)")
                }
            }
        }
        #expect(
            missing.isEmpty,
            Comment(rawValue: "No live implementation found for:\n  " + missing.joined(separator: "\n  ")))
    }

    // MARK: - The recurring shape: an ignored parameter

    /// `LiveWorld.search(query:scope:)` used to take a `scope` and never look at it, so the
    /// pill above the results changed and the results did not. The mock ignored it too, which
    /// is why a fake-backed scope test would have passed against a broken app.
    @Test func liveMethodsHonourEveryParameter() throws {
        try Self.assertNoFindings(Self.parameterFindings(try Self.load()), rule: .parameterHonoured)
    }

    static func parameterFindings(_ world: World) -> [Finding] {
        var findings: [Finding] = []
        for pair in Self.pairs where !pair.live.isEmpty {
            let live = world.members(of: pair.live, in: world.live)
            for requirement in world.requirements
            where requirement.protocolName == pair.protocolName && requirement.kind == .function {
                guard
                    let member = live.first(where: {
                        $0.name == requirement.name && $0.labels == requirement.labels
                    })
                else { continue }
                let subject = "\(pair.live).\(requirement.signature)"
                for name in member.parameterNames
                where !SwiftSource.mentions(name, in: member.body) {
                    findings.append(
                        Finding(subject, "never mentions its `\(name)` parameter"))
                }
            }
        }
        return findings
    }

    // MARK: - The recurring shape: a live stub behind a complete mock

    @Test func liveMethodsAreNotStubsWhereTheMockDoesWork() throws {
        try Self.assertNoFindings(Self.stubFindings(try Self.load()), rule: .notAStub)
    }

    static func stubFindings(_ world: World) -> [Finding] {
        var findings: [Finding] = []
        for pair in Self.pairs where !pair.live.isEmpty && !pair.mock.isEmpty {
            let live = world.members(of: pair.live, in: world.live)
            let mock = world.members(of: pair.mock, in: world.mock)
            for requirement in world.requirements
            where requirement.protocolName == pair.protocolName {
                guard
                    let liveMember = live.first(where: {
                        $0.name == requirement.name
                            && ($0.kind == .property || $0.labels == requirement.labels)
                    }),
                    let mockMember = mock.first(where: {
                        $0.name == requirement.name
                            && ($0.kind == .property || $0.labels == requirement.labels)
                    })
                else { continue }
                let subject = "\(pair.live).\(requirement.signature)"
                // A stored property is "real" when something assigns it; a computed one when
                // its body does more than hand back a literal.
                let liveIsStub =
                    liveMember.kind == .property
                    ? Self.storedPropertyIsNeverWritten(liveMember, in: live)
                    : SwiftSource.isTrivial(liveMember.body)
                let mockIsStub =
                    mockMember.kind == .property
                    ? Self.storedPropertyIsNeverWritten(mockMember, in: mock)
                    : SwiftSource.isTrivial(mockMember.body)
                if liveIsStub && !mockIsStub {
                    findings.append(
                        Finding(
                            subject,
                            "does nothing, while \(pair.mock).\(requirement.signature) does "
                                + "real work"))
                }
            }
        }
        return findings
    }

    /// A stored property with a hollow initial value that no member ever assigns to.
    private static func storedPropertyIsNeverWritten(
        _ member: SourceMember, in siblings: [SourceMember]
    ) -> Bool {
        guard member.isStored else { return false }
        let initial = member.declaration
            .split(separator: "=", maxSplits: 1)
            .dropFirst()
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard SwiftSource.isHollow(initial) || initial.isEmpty else { return false }
        let assignment = "\\b\(NSRegularExpression.escapedPattern(for: member.name))\\s*="
        return !siblings.contains {
            $0.name != member.name
                && $0.body.range(of: assignment, options: .regularExpression) != nil
        }
    }

    // MARK: - The recurring shape: a field the mock fills in and the live hard-codes

    /// `ConversationRowDisplay.snippet` was `nil` at every live construction while
    /// `PreviewTodayData` supplied the rolling line — so the Q6 live preview existed in every
    /// artboard and in no build. Same shape as `NoteDisplay.momentsLabel`.
    @Test func liveConstructionsPopulateEveryFieldTheMockDoes() throws {
        try Self.assertNoFindings(Self.fieldFindings(try Self.load()), rule: .fieldPopulated)
    }

    static func fieldFindings(_ world: World) -> [Finding] {
        var findings: [Finding] = []
        for pair in Self.pairs where !pair.live.isEmpty && !pair.mock.isEmpty {
            let liveMembers = world.members(of: pair.live, in: world.live)
            let mockMembers = world.members(of: pair.mock, in: world.mock)
            let liveBuilds = liveMembers.flatMap {
                SwiftSource.constructions(of: world.displayStructs, in: $0)
            }
            let mockBuilds = mockMembers.flatMap {
                SwiftSource.constructions(of: world.displayStructs, in: $0)
            }
            guard !liveBuilds.isEmpty, !mockBuilds.isEmpty else { continue }

            for structName in Set(liveBuilds.map(\.typeName)) {
                let live = liveBuilds.filter { $0.typeName == structName }
                let mock = mockBuilds.filter { $0.typeName == structName }
                guard !mock.isEmpty else { continue }
                // Only fields the mock actually fills in with something: a field neither side
                // supplies is a default, not a gap.
                let mockFilled = Set(
                    mock.flatMap { build in
                        build.arguments.filter { !SwiftSource.isHollow($0.value) }.keys
                    })
                for field in mockFilled.sorted() {
                    let liveValues = live.compactMap { $0.arguments[field] }
                    guard !liveValues.isEmpty else { continue }
                    guard liveValues.allSatisfy(SwiftSource.isHollow) else { continue }
                    let subject = live.first { $0.arguments[field] != nil }?.inMember ?? pair.live
                    findings.append(
                        Finding(
                            subject,
                            "builds \(structName) with `\(field): \(liveValues[0])` at every "
                                + "site, while \(pair.mock) supplies a real value"))
                }
            }
        }
        return findings
    }

    // MARK: - The exemption list may not rot

    /// An exemption that is no longer needed is a lie about the codebase, so it fails. It is
    /// checked by re-running the very same scan the exemption suppresses: if the finding no
    /// longer occurs, the entry has to go. This is what stops the list from becoming the place
    /// gaps go to be forgotten.
    @Test func exemptionsAreAllStillNeeded() throws {
        let world = try Self.load()
        let live: [Rule: [Finding]] = [
            .parameterHonoured: Self.parameterFindings(world),
            .notAStub: Self.stubFindings(world),
            .fieldPopulated: Self.fieldFindings(world),
        ]
        var stale: [String] = []
        for exemption in Self.exemptions {
            guard let rule = Rule(rawValue: exemption.rule) else {
                stale.append("\(exemption.subject) — unknown rule `\(exemption.rule)`")
                continue
            }
            if !(live[rule] ?? []).contains(where: { $0.subject == exemption.subject }) {
                stale.append("\(exemption.subject) (\(exemption.rule)) — no longer a finding")
            }
        }
        #expect(
            stale.isEmpty,
            Comment(
                rawValue: "These exemptions are stale — delete them from `exemptions`:\n  "
                    + stale.joined(separator: "\n  ")))
    }

    /// Every exemption carries a reason someone can act on, not a shrug.
    @Test func everyExemptionExplainsItself() {
        for exemption in Self.exemptions {
            #expect(
                exemption.reason.count >= 60,
                "\(exemption.subject): the reason has to say why it cannot be closed")
        }
        #expect(
            Set(Self.exemptions.map(\.key)).count == Self.exemptions.count,
            "duplicate exemption entries")
    }

    // MARK: - Helpers

    /// One gap, named by the live member it is in so an exemption can address it.
    struct Finding {
        var subject: String
        var detail: String

        init(_ subject: String, _ detail: String) {
            self.subject = subject
            self.detail = detail
        }
    }

    private static func assertNoFindings(
        _ findings: [Finding], rule: Rule, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let exempt = Set(
            exemptions.filter { $0.rule == rule.rawValue }.map(\.subject))
        let unexplained = findings.filter { !exempt.contains($0.subject) }
        let lines = Set(unexplained.map { "\($0.subject) \($0.detail)" }).sorted()
        #expect(
            lines.isEmpty,
            Comment(rawValue: report(lines, rule: rule)),
            sourceLocation: sourceLocation)
    }

    private static func report(_ findings: [String], rule: Rule) -> String {
        """
        The live implementation is behind its mock (\(rule.rawValue)):
          \(findings.joined(separator: "\n  "))

        Fix the live side. If it genuinely cannot be fixed here — it needs a device, a database
        or firmware that does not exist — add an entry to `exemptions` naming the subject, the
        rule and why, so the gap is visible to the next reader instead of absent.
        """
    }
}
