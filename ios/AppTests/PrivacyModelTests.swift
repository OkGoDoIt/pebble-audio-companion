import CompanionRuntime
import Foundation
import Testing

// The Privacy screen is a promise about a microphone, so every sentence on it is derived
// (`PrivacyModel`, `docs/privacy-model.md`) and this suite walks every combination of the six
// destinations — cloud transcription (D1), cloud AI (D2), iCloud (D3), the server (D5), the
// assistants reading it (D6), and Muse (D7) — with the server's paused/clips/edits and Muse's
// spoken questions on top, against provider names that collide (OpenAI for both halves).
// Nothing here may print a false sentence in any of them.

@Suite("privacy model") @MainActor
struct PrivacyModelTests {
    static let now: Int64 = 1_792_576_800_000
    static let host = "pebbleaudio.okgodoit.com"
    static let assistants = [
        PrivacyInputs.Assistant(name: "ChatGPT", canWrite: false, lastUsedAtMs: now - 3_600_000),
        PrivacyInputs.Assistant(name: "Claude", canWrite: true, lastUsedAtMs: nil),
        PrivacyInputs.Assistant(name: "Codex on Mac", canWrite: false, lastUsedAtMs: now - 86_400_000 * 3),
    ]

    struct Case: CustomStringConvertible {
        var inputs: PrivacyInputs
        var label: String
        var description: String { label }
    }

    /// 2^6 destination combinations, each with its server and Muse variants, and two provider
    /// spellings for each cloud half.
    static func cases() -> [Case] {
        var out: [Case] = []
        for bits in 0..<64 {
            let stt = bits & 1 != 0, ai = bits & 2 != 0, cloud = bits & 4 != 0
            let server = bits & 8 != 0, readers = bits & 16 != 0, muse = bits & 32 != 0
            for (sttName, aiName) in [("Soniox", "OpenAI"), ("OpenAI", "OpenAI"), ("Soniox", "Apple Private Cloud Compute")] {
                for paused in server ? [false, true] : [false] {
                    for clips in server ? [false, true] : [false] {
                        for edits in server ? [false, true] : [false] {
                            for spoken in muse ? [false, true] : [false] {
                                var inputs = PrivacyInputs()
                                inputs.transcriptionDestination = stt ? sttName : nil
                                inputs.aiDestination = ai ? aiName : nil
                                inputs.iCloudAgeDays = cloud ? 60 : nil
                                if server {
                                    inputs.server = .init(
                                        host: host, paused: paused, scope: .lastDays(90),
                                        clipsAllowed: clips, editsAllowed: edits,
                                        assistants: readers ? assistants : [])
                                }
                                if muse {
                                    inputs.museState = .init(
                                        spokenQuestions: spoken, watchActions: [], dataSources: [:])
                                }
                                out.append(Case(
                                    inputs: inputs,
                                    label: "bits \(bits) \(sttName)/\(aiName) paused \(paused) clips \(clips) edits \(edits) spoken \(spoken)"))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Every sentence the screen would print for these inputs.
    static func sentences(_ p: PrivacyPresentation) -> [String] {
        var all = [p.headline, p.line] + p.whereItGoesFooters + p.commitments
        all += p.destinations.flatMap { [$0.name, $0.why] + $0.chips.map(\.label) + [$0.meta].compactMap { $0 } }
        all += (p.whoCanRead ?? []).flatMap { [$0.name, $0.lastRead, $0.chip.label] }
        all += [p.whoCanReadFooter].compactMap { $0 }
        return all
    }

    @Test func noCombinationPrintsAFalseSentence() {
        let cases = Self.cases()
        #expect(cases.count > 64)
        for c in cases {
            let inputs = c.inputs
            let p = PrivacyModel.derive(inputs, nowMs: Self.now)
            let text = Self.sentences(p)
            let server = inputs.server
            let readers = server?.assistants ?? []
            let mergedProviders = inputs.transcriptionDestination != nil
                && inputs.transcriptionDestination == inputs.aiDestination
            let expectedPlaces = (inputs.transcriptionDestination != nil ? 1 : 0)
                + (inputs.aiDestination != nil && !mergedProviders ? 1 : 0)
                + (inputs.iCloudAgeDays != nil ? 1 : 0) + (server != nil ? 1 : 0)
                + (inputs.museState != nil ? 1 : 0) + readers.count

            // The blanket claim that cannot be verified, never.
            #expect(!text.contains { $0.localizedCaseInsensitiveContains("nothing else leaves") }, "\(c)")
            // N counts every destination, each assistant included.
            #expect(p.placeCount == expectedPlaces, "\(c)")
            // Local only when nothing at all goes anywhere, and then it says so in green.
            #expect((p.dot == .good) == (expectedPlaces == 0), "\(c)")
            #expect((p.headline == "Everything stays on this phone") == (expectedPlaces == 0), "\(c)")
            if expectedPlaces >= 2 {
                #expect(p.headline == "Your data goes to \(Copy.countWord(expectedPlaces)) places you chose", "\(c)")
                #expect(p.line == "Each is listed below.", "\(c)")
            }
            // "Shared" is only promised when nothing is shared.
            #expect(p.commitments.contains { $0.contains("never sold or shared") } == (expectedPlaces == 0), "\(c)")
            #expect(p.commitments.contains { $0.contains("never sold.") } == (expectedPlaces > 0), "\(c)")
            #expect(p.commitments.contains(PrivacyModel.pebbleAppLine), "\(c)")
            // The server holds a copy, paused or not, and the app never claims no server then.
            if server != nil {
                #expect(p.commitments[0].hasSuffix("Your server holds a copy of the text because you linked it."), "\(c)")
                #expect(!text.contains { $0.contains("no server of its own") }, "\(c)")
            }
            // "Audio stays on this phone" only while no audio goes anywhere.
            if text.contains(where: { $0.contains("Audio stays on this phone") }) {
                #expect(inputs.transcriptionDestination == nil && inputs.iCloudAgeDays == nil, "\(c)")
                #expect(server?.clipsAllowed != true, "\(c)")
            }
            // One row and one branch per destination, in the model's order.
            let order: [PrivacyDestination.Kind] = [.transcriptionAndAI, .transcription, .ai, .iCloud, .server, .muse]
            let kinds = p.destinations.map(\.kind)
            #expect(kinds == order.filter { kinds.contains($0) }, "\(c)")
            #expect(kinds.count == expectedPlaces - readers.count, "\(c)")
            // Who can read: only with a server; the hollow tile when nobody is connected.
            #expect((p.whoCanRead == nil) == (server == nil), "\(c)")
            if let server {
                #expect(p.whoCanRead?.count == readers.count, "\(c)")
                #expect(p.assistantGroups.flatMap(\.names).sorted() == readers.map(\.name).sorted(), "\(c)")
                for row in p.whoCanRead ?? [] {
                    let canWrite = readers.first { $0.name == row.name }?.canWrite ?? false
                    #expect(row.chip.label == Copy.AssistantAccess.mayDo(clips: server.clipsAllowed, add: server.editsAllowed && canWrite), "\(c)")
                }
                let serverRow = p.destinations.first { $0.kind == .server }
                #expect(serverRow?.paused == server.paused, "\(c)")
                if server.paused {
                    #expect(serverRow?.why == "Sync is paused" && serverRow?.chips.isEmpty == true, "\(c)")
                } else {
                    #expect(serverRow?.chips.map(\.label).contains("Clips when asked") == server.clipsAllowed, "\(c)")
                }
                #expect(serverRow?.meta == "\(Self.host) · Last 90 days", "\(c)")
                #expect(p.whereItGoesFooters.contains(Copy.AssistantAccess.rollingLine(90)), "\(c)")
            }
            // Muse: the model's sentences, word for word.
            if let muse = inputs.museState {
                #expect(p.whereItGoesFooters.contains { $0.hasPrefix(muse.spokenQuestions ? PrivacyModel.museSentence : PrivacyModel.museSentenceTyped) }, "\(c)")
                #expect(p.commitments.contains(PrivacyModel.museTrainingLine), "\(c)")
            } else {
                #expect(!text.contains { $0.contains("Muse") }, "\(c)")
            }
            // The vendor line names exactly the vendors, each once, with the Oxford comma.
            let vendors = Copy.uniqueNames(
                [inputs.transcriptionDestination, inputs.aiDestination].compactMap { $0 }
                    + readers.map { BrandMark.vendorName(ofAssistant: $0.name) }
                    + (inputs.museState != nil ? ["Meta"] : []))
            let vendorLine = p.commitments.first { $0.hasPrefix("What ") && $0.contains("governed by") }
            if vendors.isEmpty {
                #expect(vendorLine == nil, "\(c)")
            } else if vendors.count == 1 {
                #expect(vendorLine == "What \(vendors[0]) keeps is governed by \(vendors[0]), not by this app.", "\(c)")
            } else {
                #expect(vendorLine == "What \(Copy.list(vendors)) keep is governed by them, not by this app.", "\(c)")
                if vendors.count >= 3 { #expect(vendorLine?.contains(", and ") == true, "\(c)") }
            }
        }
    }

    // MARK: - The mockups' five states, sentence for sentence

    @Test func theFiveReviewedStatesSayWhatTheMockupsSay() {
        let a = PrivacyModel.derive(PrivacyInputs(), nowMs: Self.now)
        #expect(a.headline == "Everything stays on this phone" && a.dot == .good && !a.hasFlow)
        #expect(a.commitments[1] == "Your recordings and transcripts are never sold or shared. They go only where this screen says they go.")

        var b = PrivacyInputs()
        b.server = .init(host: Self.host, paused: false, scope: .all, clipsAllowed: false, editsAllowed: false, assistants: [])
        let pb = PrivacyModel.derive(b, nowMs: Self.now)
        #expect(pb.headline == "Text syncs to pebbleaudio.okgodoit.com")
        #expect(pb.line == "Your conversations' text goes to your own server. Audio stays on this phone.")
        #expect(pb.assistantGroups.isEmpty && pb.whoCanRead == [])

        var c = b
        c.server?.scope = .lastDays(90)
        c.server?.assistants = Array(Self.assistants.prefix(2)).map { var a = $0; a.canWrite = false; return a }
        let pc = PrivacyModel.derive(c, nowMs: Self.now)
        #expect(pc.headline == "Your data goes to three places you chose")
        #expect(pc.assistantGroups.map(\.names) == [["ChatGPT", "Claude"]])
        #expect(pc.commitments.contains("What ChatGPT and Claude keep is governed by them, not by this app."))

        var d = PrivacyInputs()
        d.transcriptionDestination = "Soniox"
        d.server = .init(host: Self.host, paused: false, scope: .all, clipsAllowed: true, editsAllowed: false,
                         assistants: Self.assistants.map { var a = $0; a.canWrite = false; return a })
        d.museState = .init(spokenQuestions: true, watchActions: [], dataSources: [:])
        let pd = PrivacyModel.derive(d, nowMs: Self.now)
        #expect(pd.headline == "Your data goes to six places you chose")
        #expect(pd.assistantGroups.first?.chip.label == "Can read and ask for clips")
        #expect(pd.commitments.contains("What Soniox, ChatGPT, Claude, Codex, and Meta keep is governed by them, not by this app."))
        #expect(pd.whereItGoesFooters.last == PrivacyModel.museSentence)
        // Roger's review: the Meta row does not repeat the D7 sentence as a sub-line.
        #expect(pd.destinations.last?.meta == nil && pd.destinations.last?.why == "Answers your questions")

        var e = PrivacyInputs()
        e.aiDestination = "OpenAI"
        e.iCloudAgeDays = 60
        e.server = .init(host: Self.host, paused: true, scope: .lastDays(90), clipsAllowed: false, editsAllowed: false,
                         assistants: Array(Self.assistants.prefix(2)).map { var a = $0; a.canWrite = false; return a })
        let pe = PrivacyModel.derive(e, nowMs: Self.now)
        #expect(pe.headline == "Your data goes to five places you chose")
        #expect(pe.destinations.map(\.name) == ["OpenAI", "iCloud Drive", "Your server"])
        #expect(pe.destinations.last?.why == "Sync is paused")
        #expect(pe.commitments.contains("What OpenAI, ChatGPT, and Claude keep is governed by them, not by this app."))
    }

    @Test func aPausedServerAloneIsStillADestination() {
        var inputs = PrivacyInputs()
        inputs.server = .init(host: Self.host, paused: true, scope: .all, clipsAllowed: false, editsAllowed: false, assistants: [])
        let p = PrivacyModel.derive(inputs, nowMs: Self.now)
        #expect(p.headline == "Your server keeps your text" && p.line == "Sync is paused.")
        #expect(PrivacyModel.rowValue(inputs, nowMs: Self.now) != Copy.Settings.Root.privacyLocal)
        #expect(PrivacyModel.rootFooter(inputs) == "Recordings stay on this phone. Your server keeps a copy of their text.")
    }

    // MARK: - What Muse can see (privacy-model.md §3.1, ce7146e6)

    func muse(_ sources: [MuseDataSource: MuseAccess], music: Bool = false) -> PrivacyPresentation {
        var inputs = PrivacyInputs()
        inputs.museState = .init(spokenQuestions: true, watchActions: music ? [.music] : [], dataSources: sources)
        return PrivacyModel.derive(inputs, nowMs: Self.now)
    }

    @Test func museLinesFollowWhatItCanSeeWordForWord() {
        // All off: the D7 sentence alone, one chip, one place.
        let off = muse([:])
        #expect(off.whereItGoesFooters == [PrivacyModel.museSentence])
        // Staying connected to message the watch: the idle claim gives way to what still goes.
        var connected = PrivacyInputs()
        connected.museState = .init(spokenQuestions: true, watchActions: [], dataSources: [:], staysConnected: true)
        let c = PrivacyModel.derive(connected, nowMs: Self.now)
        #expect(c.whereItGoesFooters == [PrivacyModel.museSentenceConnected])
        #expect(!(c.whereItGoesFooters + [c.headline, c.line]).joined().contains("aren't asking"))
        #expect(off.destinations.first?.chips.map(\.label) == ["Your questions"])
        #expect(off.placeCount == 1 && off.headline == "Your questions to Muse go to Meta")

        // One Allowed.
        let calendar = muse([.calendar: .allowed])
        #expect(calendar.whereItGoesFooters == [
            PrivacyModel.museSentence + " When you ask, Muse can also read your calendar to answer. What it reads goes to Meta."
                + " Muse can add events you ask for. It never deletes them."
        ])
        #expect(calendar.destinations.first?.chips.map(\.label) == ["Your questions", "Calendar"])

        // One Ask first: a line, no chip.
        let health = muse([.health: .ask])
        #expect(health.whereItGoesFooters == [PrivacyModel.museSentence + " Muse asks on your watch before it reads your health data."])
        #expect(health.destinations.first?.chips.map(\.label) == ["Your questions"])

        // Conversations Ask first: what other people said.
        let conversations = muse([.conversations: .ask])
        #expect(conversations.whereItGoesFooters.first?.contains("Muse asks on your watch before it reads your conversations.") == true)
        #expect(conversations.whereItGoesFooters.first?.contains("Your conversations can include what other people said.") == true)

        // A mix, in `MuseDataSource` order with the Oxford comma.
        let mix = muse([.conversations: .allowed, .health: .ask, .calendar: .ask, .reminders: .allowed, .followUps: .off])
        let line = mix.whereItGoesFooters.first ?? ""
        #expect(line.contains("When you ask, Muse can also read your conversations and your reminders to answer. What it reads goes to Meta."))
        #expect(line.contains("Muse asks on your watch before it reads your health data and your calendar."))
        #expect(line.contains("Your conversations can include what other people said."))
        #expect(line.contains("Muse can add events and reminders you ask for. It can change or delete reminders too, never events."))
        #expect(!line.contains("before it changes"))
        #expect(mix.destinations.first?.chips.map(\.label) == ["Your questions", "Conversations", "Reminders"])
        #expect(mix.placeCount == 1)

        let three = muse([.calendar: .allowed, .reminders: .allowed, .followUps: .allowed])
        #expect(
            three.whereItGoesFooters.first?.contains(
                "Muse can add events and reminders you ask for. It can change or delete reminders too, never events."
            ) == true)
        #expect(three.whereItGoesFooters.first?.contains("Muse can turn follow-ups into reminders or skip them when you ask.") == true)
        #expect(three.whereItGoesFooters.first?.contains("before it changes") == false)

        // Follow-ups alone, Ask first: nothing to add, only to decide, asked once per question.
        let followUps = muse([.followUps: .ask]).whereItGoesFooters.first ?? ""
        #expect(!followUps.contains("Muse can add"))
        #expect(followUps.hasSuffix(
            "Muse can turn follow-ups into reminders or skip them when you ask. "
                + "Muse asks on your watch before it changes your follow-ups, once per question."))
        let both = muse([.reminders: .ask, .followUps: .ask]).whereItGoesFooters.first ?? ""
        #expect(both.contains("Muse asks on your watch before it changes your reminders or your follow-ups, once per question."))

        // Reminders alone, Ask first: changes are asked about once per question.
        let reminders = muse([.reminders: .ask]).whereItGoesFooters.first ?? ""
        #expect(reminders.contains("Muse can add reminders you ask for. It can change or delete them too."))
        #expect(reminders.hasSuffix("Muse asks on your watch before it changes your reminders, once per question."))

        // Music on or off.
        #expect(muse([:], music: true).whereItGoesFooters.first?.hasSuffix("When you ask what's playing, the song's title and artist go to Meta.") == true)
        #expect(muse([:], music: false).whereItGoesFooters.first?.contains("what's playing") == false)
    }

    // MARK: - Lists

    @Test func listsTheCodeAssemblesCarryTheOxfordComma() {
        #expect(Copy.list([]) == "")
        #expect(Copy.list(["ChatGPT"]) == "ChatGPT")
        #expect(Copy.list(["ChatGPT", "Claude"]) == "ChatGPT and Claude")
        #expect(Copy.list(["ChatGPT", "Claude", "Codex on Mac"]) == "ChatGPT, Claude, and Codex on Mac")
        #expect(Copy.list(["Codex", "Claude Code", "Cursor"], conjunction: "or") == "Codex, Claude Code, or Cursor")
        #expect(Copy.countWord(6) == "six" && Copy.countWord(12) == "12")
        #expect(BrandMark.vendorName(ofAssistant: "Codex on Mac") == "Codex")
        #expect(BrandMark.forAssistant(named: "Claude Code") == .claudeCode)
        #expect(BrandMark.forAssistant(named: "Claude") == .claude)
    }
}

@Suite("universal links")
struct UniversalLinkTests {
    let servers = ["pebbleaudio.okgodoit.com"]

    func parse(_ text: String) -> UniversalLink? {
        URL(string: text).flatMap { UniversalLink.parse($0, servers: servers) }
    }

    @Test func theServersPagesOpenTheScreensTheyNameAndNothingElse() {
        #expect(parse("https://pebbleaudio.okgodoit.com/c/conv-kitchen?t=1260") == .conversation(id: "conv-kitchen", secondsFromStart: 1260))
        #expect(parse("https://pebbleaudio.okgodoit.com/c/conv-kitchen") == .conversation(id: "conv-kitchen", secondsFromStart: nil))
        #expect(parse("https://pebbleaudio.okgodoit.com/c/conv-kitchen?t=abc") == .conversation(id: "conv-kitchen", secondsFromStart: nil))
        #expect(parse("https://pebbleaudio.okgodoit.com/d/2026-10-19")?.route == .history(date: "2026-10-19", level: "day"))
        #expect(parse("https://pebbleaudio.okgodoit.com/b/week/2026-10-11")?.route == .history(date: "2026-10-11", level: "week"))
        #expect(parse("https://pebbleaudio.okgodoit.com/b/month/2026-10")?.route == .history(date: "2026-10-01", level: "month"))
        if case .link(let invitation)? = parse("https://pebbleaudio.okgodoit.com/link?code=K7QM-3XWD") {
            #expect(invitation.code == "K7QM3XWD" && invitation.host == "pebbleaudio.okgodoit.com")
        } else {
            Issue.record("the Link a phone page should open the Link step")
        }
        // Another host, another path, or plain http: not ours.
        #expect(parse("https://example.com/c/conv-kitchen?t=12") == nil)
        #expect(parse("https://pebbleaudio.okgodoit.com/admin") == nil)
        #expect(parse("https://pebbleaudio.okgodoit.com/d/yesterday") == nil)
        #expect(parse("http://pebbleaudio.okgodoit.com/d/2026-10-19") == nil)
    }
}
