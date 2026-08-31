import Foundation
import AppDB
import StatusUI

// The mock world behind `AskLibraryDataSources.current` — carries the EXACT sample data from
// the approved artboards (Library / Search / Conversation / AskSheet / TagEditor / NotesView)
// so every screen replicates its mockup until the runtime wiring swaps in DB-backed sources.
//
// Note: `Sources/SearchKit` is still a placeholder, so the snippet builder and quiet/missing
// display logic live here against the plan (TranscriptFormatting behaviors), flagged for
// replacement when the SearchKit port lands.

extension AskLibraryDataSources {
    static func mocks() -> AskLibraryDataSources {
        let world = MockWorld.shared
        return AskLibraryDataSources(
            library: world, search: world, conversations: world, ask: world,
            notes: world, tagEditor: world, people: world
        )
    }
}

@MainActor
final class MockWorld {
    static let shared = MockWorld()

    struct MockConversation {
        var id: String
        var title: String
        /// One-line Library row summary.
        var summary: String?
        /// Longer detail-header summary (Conversation artboard); falls back to `summary`.
        var detailSummary: String?
        var start: Date
        var end: Date
        var isLive = false
        var tags: [ConversationTag] = []
        var mostlyQuiet = false
        var hasMissingAudio = false
        var lifecycle: LifecycleDisplay = .complete
        var transcript: [TranscriptItem] = []
        var player: PlayerDisplay?
        var provenanceProvider: String?
        var provenanceDate: Date?
        var followUpCount = 0
    }

    var conversations: [MockConversation] = []
    var followUps: [FollowUp] = []
    var askEntries: [AskEntry] = []
    var noteRecords: [NoteDisplay] = []
    var customTemplates: [NoteTemplate] = []
    var peopleRegistry: [Person] = []
    /// Artboard tag counts ("travel 12 · work 8 · family 5 · dining 3") + suggestion tags.
    var extraTagCounts: [String: Int] = [
        "travel": 12, "work": 8, "family": 5, "dining": 3, "budget": 1, "evening": 1,
    ]
    private var deleted: [(index: Int, conversation: MockConversation)] = []
    private var updateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    let hasContent = true

    private init() {
        let cal = Calendar.current
        let now = Date()
        func today(_ hour: Int, _ minute: Int) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
        }
        func yesterday(_ hour: Int, _ minute: Int) -> Date {
            cal.date(byAdding: .day, value: -1, to: today(hour, minute))!
        }

        func turn(_ id: String, _ label: String, _ name: String, _ role: SpeakerRole, _ text: String)
            -> TranscriptItem
        {
            .turn(TranscriptTurn(id: id, speakerLabel: label, name: name, role: role, text: text))
        }

        // ── Conversations (Library + Conversation artboards) ────────────────
        conversations = [
            MockConversation(
                id: "app-redesign",
                title: "App redesign session",
                start: today(12, 4), end: now,
                isLive: true
            ),
            MockConversation(
                id: "coffee-dana",
                title: "Coffee with Dana",
                summary: "Firmware sideload steps, then weekend plans and the ferry schedule.",
                start: today(9, 12), end: today(9, 36),
                tags: [
                    ConversationTag(id: "tag-travel", name: "travel", source: "ai"),
                    ConversationTag(id: "tag-work", name: "work", source: "ai"),
                ],
                transcript: [
                    turn("cd1", "S1", "Roger", .you,
                         "Before any long travel we should book the ferry and sort the theater dates."),
                    turn("cd2", "S2", "Dana", .other,
                         "Ferry Saturday morning, then — I'll check the theater calendar for Tuesday."),
                    .quiet(TranscriptMarker(id: "cd3", text: Copy.Conversation.quietFor("1 min"))),
                    turn("cd4", "S1", "Roger", .you,
                         "Tuesday works. Walkthrough first, then lunch."),
                ],
                player: PlayerDisplay(durationMs: 24 * 60_000),
                provenanceProvider: "Soniox", provenanceDate: today(9, 37),
                followUpCount: 3
            ),
            MockConversation(
                id: "planning-work",
                title: "Planning work for tomorrow",
                summary: "Deciding to stop for the night and plan more work tomorrow.",
                detailSummary: "Deciding whether to keep working; you settle on planning and "
                    + "finishing more tomorrow. Sending money and an ice-cream offer come up.",
                start: yesterday(21, 35), end: yesterday(21, 53),
                tags: [
                    ConversationTag(id: "tag-work", name: "work", source: "ai"),
                    ConversationTag(id: "tag-planning", name: "planning", source: "ai"),
                    ConversationTag(id: "tag-money", name: "money", source: "ai"),
                ],
                hasMissingAudio: true,
                transcript: [
                    turn("pw1", "S1", "Roger", .you,
                         "I'll send the money and the extra piece so it can go faster now."),
                    turn("pw2", "S2", "Sam", .other,
                         "Yeah, I'll just — you can shop. Stay here."),
                    turn("pw3", "S1", "Roger", .you,
                         "Reading. Okay. All right. Have a good night."),
                    .quiet(TranscriptMarker(id: "pw4", text: Copy.Conversation.quietFor("40 sec"))),
                    turn("pw5", "S1", "Roger", .you,
                         "So before you leave — do you want ice cream for lunchtime?"),
                    .missing(TranscriptMarker(id: "pw6", text: Copy.Conversation.missingMarker("2 sec"))),
                    turn("pw7", "S2", "Sam", .other,
                         "No, I like ice cream. Okay — it's not too bad."),
                ],
                player: PlayerDisplay(
                    durationMs: 18 * 60_000 + 12_000,
                    initialPositionMs: 4 * 60_000 + 1_000,
                    missingTickFractions: [0.61]
                ),
                provenanceProvider: "Soniox", provenanceDate: yesterday(21, 54)
            ),
            // Transcribed, but AI has not caught up yet — the state a freshly migrated or
            // recovered library sits in for a while. It must not look like a broken row.
            MockConversation(
                id: "awaiting-summary",
                title: "",
                start: yesterday(20, 48), end: yesterday(21, 6),
                lifecycle: .summaryComing,
                transcript: [
                    turn("as1", "S1", "Speaker 1", .unresolved,
                         "The transcript is finished and saved — this is what a durable "
                            + "transcript looks like before AI has written a title for it."),
                    turn("as2", "S2", "Speaker 2", .unresolved,
                         "Nothing is missing here; the words are final even though nobody has "
                            + "been named yet."),
                ],
                player: PlayerDisplay(durationMs: 18 * 60_000)
            ),
            MockConversation(
                id: "evening-home",
                title: "Evening at home",
                start: yesterday(19, 2), end: yesterday(20, 42),
                mostlyQuiet: true,
                lifecycle: .capturedWaiting(queueLine: Copy.Conversation.queueLine("3rd")),
                player: PlayerDisplay(durationMs: 100 * 60_000)
            ),
            // The worst-case row the artboards never showed: an over-long generated title,
            // a long loss marker, and a summary that fills three lines. Every layout here
            // has to survive this one — the polite artboard data hid a marker that pushed
            // the whole screen wider than the display.
            MockConversation(
                id: "long-day",
                title: "Issues with Apple's AI-powered transcription service, Soniox, and a "
                    + "request for a missing API key",
                summary: "Transcription keeps failing; the API key never arrived.",
                detailSummary: "You worked through repeated failures in the transcription "
                    + "pipeline, compared Apple's on-device service with Soniox, and asked "
                    + "again for the missing API key so the cloud path can be tested.",
                start: today(9, 44), end: today(10, 48),
                tags: [
                    ConversationTag(id: "tag-work", name: "work", source: "ai"),
                    ConversationTag(id: "tag-transcription", name: "transcription", source: "ai"),
                ],
                hasMissingAudio: true,
                transcript: [
                    turn("ld1", "S1", "Roger", .you,
                         "Testing one two three, testing one two three."),
                    .quiet(TranscriptMarker(id: "ld2", text: Copy.Conversation.quietFor("1 min"))),
                    turn("ld3", "S1", "Roger", .you,
                         "Let's do the obvious issues first — onboarding never prompted me "
                         + "to turn transcription on."),
                    .missing(
                        TranscriptMarker(
                            id: "ld4",
                            text: "audio interrupted for 12 sec "
                                + "(watch buffer filled while disconnected)")),
                    turn("ld5", "S1", "Roger", .you,
                         "Today's screen showed the recent conversations, and that was "
                         + "helpful."),
                    turn("ld6", "S1", "Roger", .you,
                         "It spun out too much at first — it comes in, explains itself, and "
                         + "then goes all the way back out again."),
                    turn("ld7", "S2", "Dana", .other,
                         "The streaming ones are worse over that router. Try the TV's own "
                         + "apps instead and see whether it holds."),
                    .quiet(TranscriptMarker(id: "ld8",
                                            text: Copy.Conversation.quietFor("4 min"))),
                    turn("ld9", "S1", "Roger", .you,
                         "Right. And for the remote transcription we still need the key — "
                         + "nothing reaches Soniox without it."),
                    turn("ld10", "S2", "Dana", .other,
                         "I'll send it tonight. Then the cloud path can be tested end to "
                         + "end before the next build goes out."),
                    turn("ld11", "S1", "Roger", .you,
                         "Good. Until then everything stays on-device, which is slower but "
                         + "at least it is honest about what it captured."),
                ],
                player: PlayerDisplay(
                    durationMs: 33 * 60_000 + 12_000, missingTickFractions: [0.42]),
                provenanceProvider: "Soniox", provenanceDate: today(10, 49)
            ),
            MockConversation(
                id: "tv-household",
                title: "TV and household plans",
                summary: "Sorting the week — groceries, the broken hallway light, show queue.",
                start: yesterday(18, 10), end: yesterday(18, 41),
                transcript: [
                    turn("tv1", "S1", "Roger", .you,
                         "Groceries Saturday, and the hallway light is broken again — I'll grab a bulb."),
                    turn("tv2", "S2", "Sam", .other,
                         "Add the show queue too. We're two behind on everything."),
                ],
                player: PlayerDisplay(durationMs: 31 * 60_000),
                provenanceProvider: "Soniox", provenanceDate: yesterday(18, 44)
            ),
        ]

        // ── Follow-ups ──────────────────────────────────────────────────────
        followUps = [
            FollowUp(
                id: "fu-firmware", text: "Send Dana the new firmware build", done: false,
                sourceConversationId: "coffee-dana", sourceSegmentId: nil,
                createdAtMs: ms(today(9, 40))),
            FollowUp(
                id: "fu-walkthrough", text: "Book the theater walkthrough for Tuesday", done: false,
                sourceConversationId: "coffee-dana", sourceSegmentId: nil,
                createdAtMs: ms(today(9, 39))),
            FollowUp(
                id: "fu-ferry", text: "Book the ferry for the travel weekend", done: false,
                sourceConversationId: "coffee-dana", sourceSegmentId: nil,
                createdAtMs: ms(today(9, 38))),
        ]

        // ── Ask history (Q18 — up to 5, newest first) ───────────────────────
        askEntries = [
            AskEntry(
                id: "ask-trip",
                question: "What did we decide about the trip?",
                answerText: "You decided to take the ferry Saturday morning instead of driving [1], "
                    + "and to book the theater walkthrough for Tuesday so the trip doesn't collide "
                    + "with it [2]. Packing was left open — Sam offered to handle it Friday evening [2].",
                citations: [
                    AskCitation(segmentId: "coffee-dana", number: 1),
                    AskCitation(segmentId: "evening-home", number: 2),
                ],
                scopeDescription: Copy.Ask.scopeLastDays(2),
                createdAtMs: ms(now.addingTimeInterval(-2 * 3600))),
            AskEntry(
                id: "ask-walkthrough",
                question: "When is the theater walkthrough?",
                answerText: "Tuesday afternoon — you set it so the ferry weekend stays clear [1].",
                citations: [AskCitation(segmentId: "coffee-dana", number: 1)],
                scopeDescription: Copy.Ask.scopeLast7Days,
                createdAtMs: ms(now.addingTimeInterval(-26 * 3600))),
            AskEntry(
                id: "ask-house",
                question: "Did anything need fixing at home?",
                answerText: "The hallway light is broken; you added a bulb to the weekend list [1].",
                citations: [AskCitation(segmentId: "tv-household", number: 1)],
                scopeDescription: Copy.Ask.scopeEverything,
                createdAtMs: ms(now.addingTimeInterval(-2 * 86_400))),
        ]

        // ── Saved notes (NotesView artboard) ────────────────────────────────
        noteRecords = [
            NoteDisplay(
                id: "meeting-notes",
                conversationId: "planning-work",
                conversationTitle: "Planning work for tomorrow",
                title: Copy.Notes.templateMeetingNotes,
                provenance: Copy.Notes.generatedLine(
                    time: TimeFmt.time(yesterday(21, 54)), model: "GPT-5.6 Luna"),
                body: "Stop for the night; plan and finish the remaining work tomorrow [1].\n"
                    + "Roger sends the money plus the extra piece so it can go faster [2].\n"
                    + "Sam stays in; shopping and the ice-cream run wait for lunchtime [2].",
                momentsLabel: Copy.Ask.moments(
                    2, "\(TimeFmt.time(yesterday(21, 36))), \(TimeFmt.time(yesterday(21, 51)))"),
                citations: [
                    AskCitation(segmentId: "planning-work", number: 1),
                    AskCitation(segmentId: "planning-work", number: 2),
                ]),
        ]

        peopleRegistry = [
            Person(id: "person-sam", name: "Sam"),
            Person(id: "person-dana", name: "Dana"),
        ]
    }

    // MARK: - Internals

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func bump() {
        for continuation in updateContinuations.values { continuation.yield() }
    }

    private func index(of id: String) -> Int? { conversations.firstIndex { $0.id == id } }

    private func listRow(_ conversation: MockConversation) -> LibraryRow {
        let zone = TimeZone.current.identifier
        let startMs = ms(conversation.start)
        let lifecycle: ConversationLifecycle
        switch conversation.lifecycle {
        case .complete: lifecycle = .complete
        case .capturedWaiting: lifecycle = .capturedWaiting
        case .transcribing: lifecycle = .transcribing
        case .failed: lifecycle = .failed
        // Enrichment states are conversation-level only: transcription itself is finished.
        case .summaryComing, .noSummary: lifecycle = .complete
        }
        let total = followUps.filter { $0.sourceConversationId == conversation.id }
        let awaiting: Bool = if case .summaryComing = conversation.lifecycle { true } else { false }
        return LibraryRow(
            id: conversation.id,
            // An empty mock title stands for "AI has not written one yet".
            title: conversation.title.isEmpty ? nil : conversation.title,
            summary: conversation.summary,
            startMs: startMs,
            endMs: ms(conversation.end),
            isLive: conversation.isLive,
            tags: conversation.tags.map(\.name),
            lifecycle: lifecycle,
            mostlyQuiet: conversation.mostlyQuiet,
            hasMissingAudio: conversation.hasMissingAudio,
            followUpCount: max(total.count, conversation.followUpCount),
            dateKey: LogicalDay.dateKey(forMs: startMs, timeZoneID: zone),
            awaitingAnnotation: awaiting
        )
    }

    private func displayModel(_ conversation: MockConversation) -> ConversationDisplay {
        var provenance: String?
        if let provider = conversation.provenanceProvider, let date = conversation.provenanceDate {
            provenance = Copy.Conversation.provenance(
                provider: provider,
                when: "\(TimeFmt.dayLabel(for: date).lowercased()) \(TimeFmt.time(date))")
        }
        var meta = TimeFmt.conversationMeta(start: conversation.start, end: conversation.end)
        if conversation.isLive {
            meta = "\(TimeFmt.time(conversation.start)) · "
                + Formatting.duration(ms(Date()) - ms(conversation.start)) + " so far"
        }
        return ConversationDisplay(
            id: conversation.id,
            title: conversation.title,
            metaLine: meta,
            summary: conversation.detailSummary ?? conversation.summary,
            tags: conversation.tags,
            lifecycle: conversation.lifecycle,
            player: conversation.player,
            transcript: Self.stamped(conversation.transcript, from: conversation.start,
                                     to: conversation.isLive ? Date() : conversation.end),
            provenance: provenance,
            followUps: followUps.filter { $0.sourceConversationId == conversation.id }
        )
    }

    /// The artboard fixtures carry no per-row times, so the mock world spreads them evenly
    /// across the conversation — enough for the stamps beside each speaker to look and behave
    /// like real ones in demo builds and previews.
    private static func stamped(
        _ transcript: [TranscriptItem], from start: Date, to end: Date
    ) -> [TranscriptItem] {
        guard transcript.count > 1, end > start else { return transcript }
        let step = end.timeIntervalSince(start) / Double(transcript.count)
        return transcript.enumerated().map { offset, item in
            let at = start.addingTimeInterval(step * Double(offset))
            switch item {
            case .turn(var turn):
                turn.startedAt = at
                return .turn(turn)
            case .quiet(var marker):
                marker.startedAt = at
                return .quiet(marker)
            case .missing(var marker):
                marker.startedAt = at
                return .missing(marker)
            }
        }
    }

    private func searchableText(_ conversation: MockConversation) -> String {
        var pieces = [conversation.title]
        if let summary = conversation.summary { pieces.append(summary) }
        pieces.append(contentsOf: conversation.tags.map(\.name))
        for item in conversation.transcript {
            if case .turn(let turn) = item { pieces.append(turn.text) }
        }
        return pieces.joined(separator: " ")
    }

    /// Local snippet builder (TranscriptFormatting-style) — replace with SearchKit when ported.
    private func snippet(for query: String, in conversation: MockConversation) -> String? {
        let lowered = query.lowercased()
        for item in conversation.transcript {
            guard case .turn(let turn) = item,
                  let range = turn.text.lowercased().range(of: lowered) else { continue }
            let text = turn.text
            let leadStart = text.index(
                range.lowerBound, offsetBy: -34, limitedBy: text.startIndex) ?? text.startIndex
            let tailEnd = text.index(
                range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
            var core = String(text[leadStart..<tailEnd]).trimmingCharacters(in: .whitespaces)
            if leadStart > text.startIndex { core = "…" + core }
            if tailEnd < text.endIndex { core += "…" }
            return "“\(core)”"
        }
        if let summary = conversation.summary, summary.lowercased().contains(lowered) {
            return "“\(summary)”"
        }
        return nil
    }
}

// MARK: - LibraryDataSource

extension MockWorld: LibraryDataSource {
    func library(filter: LibraryFilter, tag: String?) async throws -> [LibraryDayGroup] {
        let rows = conversations.map(listRow(_:)).filter { row in
            if let tag, !row.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                return false
            }
            switch filter {
            case .all: return true
            case .untranscribed: return row.lifecycle != .complete
            case .withFollowUps: return row.followUpCount > 0
            case .withMissingAudio: return row.hasMissingAudio
            }
        }
        var sections: [String: [LibraryRow]] = [:]
        for row in rows { sections[row.dateKey, default: []].append(row) }
        return sections.keys.sorted(by: >).map { key in
            LibraryDayGroup(
                dateKey: key,
                rows: sections[key]!.sorted { $0.startMs > $1.startMs })
        }
    }

    func tags() async throws -> [TagWithCount] {
        // The artboard counts are the sample truth; conversation tags add any missing names.
        var counts: [String: Int] = extraTagCounts
        for conversation in conversations {
            for tag in conversation.tags where counts[tag.name] == nil {
                counts[tag.name] = conversations.filter {
                    $0.tags.contains { $0.name == tag.name }
                }.count
            }
        }
        return counts
            .map { TagWithCount(id: "tag-\($0.key)", name: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name < rhs.name
            }
    }

    func updates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            updateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.updateContinuations[id] = nil }
            }
        }
    }
}

// MARK: - SearchDataSource

extension MockWorld: SearchDataSource {
    func search(query: String, scope: AskScope) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return SearchResults() }
        let lowered = trimmed.lowercased()

        let allTags = try await tags()
        let tagHits = allTags.filter { $0.name.lowercased().contains(lowered) }

        var conversationHits: [SearchConversationHit] = []
        // The artboard "travel" snippets come from conversations whose transcripts are not in
        // the sample set — surface them verbatim for that query.
        if lowered == "travel" {
            conversationHits = [
                SearchConversationHit(
                    id: "coffee-dana", title: "Coffee with Dana",
                    whenLabel: whenLabel("coffee-dana"),
                    snippet: "“…before any long travel we should book the ferry and sort the theater dates…”"),
                SearchConversationHit(
                    id: "planning-work", title: "Planning work for tomorrow",
                    whenLabel: whenLabel("planning-work"),
                    snippet: "“…finish the app before the travel plans firm up…”"),
            ]
        } else {
            for conversation in conversations where !conversation.isLive {
                guard searchableText(conversation).lowercased().contains(lowered) else { continue }
                conversationHits.append(
                    SearchConversationHit(
                        id: conversation.id, title: conversation.title,
                        whenLabel: whenLabel(conversation.id),
                        snippet: snippet(for: trimmed, in: conversation)
                            ?? "“\(conversation.title)”"))
            }
        }

        let followUpHits = followUps.filter { $0.text.lowercased().contains(lowered) }
        return SearchResults(
            tags: tagHits, conversations: conversationHits, followUps: followUpHits)
    }

    private func whenLabel(_ id: String) -> String {
        guard let index = index(of: id) else { return "" }
        let conversation = conversations[index]
        return "\(TimeFmt.dayLabel(for: conversation.start)) · \(TimeFmt.time(conversation.start))"
    }
}

// MARK: - ConversationDataSource

extension MockWorld: ConversationDataSource {
    func display(id: String) async throws -> ConversationDisplay? {
        guard let index = index(of: id) else { return nil }
        return displayModel(conversations[index])
    }

    /// The mock world holds no audio, so there is nothing to play: the card falls back to its
    /// simulated scrub rather than pretending a decoder is running.
    func playback(id: String) async throws -> (any ConversationPlayback)? { nil }

    func rename(id: String, to title: String) async throws {
        guard let index = index(of: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        conversations[index].title = trimmed
        for noteIndex in noteRecords.indices where noteRecords[noteIndex].conversationId == id {
            noteRecords[noteIndex].conversationTitle = trimmed
        }
        bump()
    }

    func retranscribe(id: String) async throws {
        try await runTranscription(id: id)
    }

    func transcribeNow(id: String) async throws {
        try await runTranscription(id: id)
    }

    func retryNow(id: String) async throws {
        try await runTranscription(id: id)
    }

    /// Mock pipeline: Transcribing… (progress) then complete. "evening-home" gains its
    /// first transcript; others keep theirs.
    private func runTranscription(id: String) async throws {
        guard let start = index(of: id) else { return }
        conversations[start].lifecycle = .transcribing(
            progress: 0.55,
            line: Copy.Conversation.transcribingLine(provider: "Soniox", remaining: "a minute"))
        bump()
        try? await Task.sleep(for: .seconds(3))
        guard let done = index(of: id) else { return }
        var conversation = conversations[done]
        conversation.lifecycle = .complete
        if conversation.transcript.isEmpty, id == "evening-home" {
            conversation.transcript = [
                .turn(TranscriptTurn(
                    id: "eh1", speakerLabel: "S2", name: "Sam", role: .other,
                    text: "Leftovers are in the fridge if you're up late.")),
                .quiet(TranscriptMarker(id: "eh2", text: Copy.Conversation.quietFor("25 min"))),
                .turn(TranscriptTurn(
                    id: "eh3", speakerLabel: "S1", name: "Roger", role: .you,
                    text: "Heading up — lights on a timer tonight.")),
            ]
            conversation.summary = "A quiet evening — dinner logistics before an early night."
            conversation.provenanceProvider = "Soniox"
            conversation.provenanceDate = Date()
        }
        conversations[done] = conversation
        bump()
    }

    func exportAudio(id: String) async throws {
        try? await Task.sleep(for: .seconds(1.2))
    }

    func delete(id: String) async throws {
        guard let index = index(of: id) else { return }
        deleted.append((index, conversations.remove(at: index)))
        bump()
    }

    func undoDelete(id: String) async throws {
        guard let stashIndex = deleted.lastIndex(where: { $0.conversation.id == id }) else { return }
        let entry = deleted.remove(at: stashIndex)
        conversations.insert(entry.conversation, at: min(entry.index, conversations.count))
        bump()
    }

    func toggleFollowUp(id: String) async throws {
        guard let index = followUps.firstIndex(where: { $0.id == id }) else { return }
        followUps[index].done.toggle()
        bump()
    }
}

// MARK: - AskDataSource

extension MockWorld: AskDataSource {
    func recentThreads() async throws -> [AskThread] {
        Array(AskThread.group(askEntries).prefix(5))
    }

    func ask(question: String, thread: AskThread?, scope: AskScope) async throws -> AskEntry {
        try? await Task.sleep(for: .seconds(1.2))
        let lowered = question.lowercased()
        let id = UUID().uuidString
        let threadId = thread?.id
        let entry: AskEntry
        if case .conversation(let conversationId, _) = scope, let index = index(of: conversationId) {
            let conversation = conversations[index]
            entry = AskEntry(
                id: id,
                threadId: threadId,
                question: question,
                answerText: "You decided to stop for the night and finish the plan tomorrow [1]. "
                    + "Roger sends the money so the work can go faster [1].",
                citations: [AskCitation(segmentId: conversation.id, number: 1)],
                scopeDescription: scope.label,
                createdAtMs: ms(Date()))
        } else if lowered.contains("trip") || lowered.contains("ferry") {
            entry = AskEntry(
                id: id,
                threadId: threadId,
                question: question,
                answerText: askEntries.first { $0.id == "ask-trip" }?.answerText
                    ?? "You decided to take the ferry Saturday morning instead of driving [1].",
                citations: [
                    AskCitation(segmentId: "coffee-dana", number: 1),
                    AskCitation(segmentId: "evening-home", number: 2),
                ],
                scopeDescription: scope.label,
                createdAtMs: ms(Date()))
        } else if lowered.contains("travel") {
            entry = AskEntry(
                id: id,
                threadId: threadId,
                question: question,
                answerText: "Travel came up twice: the ferry booking for Saturday [1] and keeping "
                    + "the theater walkthrough clear of the trip [1].",
                citations: [AskCitation(segmentId: "coffee-dana", number: 1)],
                scopeDescription: scope.label,
                createdAtMs: ms(Date()))
        } else if thread != nil {
            // A follow-up the mock has no canned answer for still reads as part of the
            // conversation rather than as a fresh, contextless miss.
            entry = AskEntry(
                id: id,
                threadId: threadId,
                question: question,
                answerText: "Nothing more about that in the recordings for this range.",
                citations: [],
                scopeDescription: scope.label,
                createdAtMs: ms(Date()))
        } else {
            entry = AskEntry(
                id: id,
                threadId: threadId,
                question: question,
                answerText: "Nothing about that in the recordings for this range.",
                citations: [],
                scopeDescription: scope.label,
                createdAtMs: ms(Date()))
        }
        askEntries.insert(entry, at: 0)
        // Trim by conversation, never mid-thread.
        let kept = Set(AskThread.group(askEntries).prefix(5).map(\.id))
        askEntries = askEntries.filter { kept.contains($0.threadId) }
        bump()
        return entry
    }

    func clearHistory() async throws {
        askEntries = []
        bump()
    }

    func conversationTitle(citedId: String) -> String? {
        index(of: citedId).map { conversations[$0].title }
    }
}

// MARK: - NotesDataSource

extension MockWorld: NotesDataSource {
    func notes(conversationId: String) async throws -> [NoteDisplay] {
        noteRecords.filter { $0.conversationId == conversationId }
    }

    func note(id: String) async throws -> NoteDisplay? {
        noteRecords.first { $0.id == id }
    }

    func templates() async throws -> [NoteTemplate] {
        NoteTemplate.builtIns + customTemplates
    }

    func generate(
        conversationId: String, template: NoteTemplate, customPrompt: String?
    ) async throws -> NoteDisplay {
        try? await Task.sleep(for: .seconds(1.5))
        if let existing = noteRecords.first(where: {
            $0.conversationId == conversationId && $0.title == template.title
        }) {
            return existing
        }
        guard let index = index(of: conversationId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let conversation = conversations[index]
        let note = NoteDisplay(
            id: UUID().uuidString.lowercased(),
            conversationId: conversationId,
            conversationTitle: conversation.title,
            title: template.title,
            provenance: Copy.Notes.generatedLine(
                time: TimeFmt.time(Date()), model: "GPT-5.6 Luna"),
            body: (conversation.summary ?? conversation.title) + " [1].",
            momentsLabel: Copy.Ask.moments(1, TimeFmt.time(conversation.start)),
            citations: [AskCitation(segmentId: conversationId, number: 1)])
        noteRecords.append(note)
        bump()
        return note
    }

    func regenerate(noteId: String) async throws -> NoteDisplay {
        try? await Task.sleep(for: .seconds(1.5))
        guard let index = noteRecords.firstIndex(where: { $0.id == noteId }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        noteRecords[index].provenance = Copy.Notes.generatedLine(
            time: TimeFmt.time(Date()), model: "GPT-5.6 Luna")
        bump()
        return noteRecords[index]
    }

    func saveEdit(noteId: String, title: String, body: String) async throws {
        guard let index = noteRecords.firstIndex(where: { $0.id == noteId }) else { return }
        noteRecords[index].title = title
        noteRecords[index].body = body
        bump()
    }

    func saveTemplate(title: String, prompt: String) async throws {
        customTemplates.append(
            NoteTemplate(
                id: UUID().uuidString.lowercased(), title: title, isCustom: true, prompt: prompt))
        bump()
    }

    func deleteTemplate(id: String) async throws {
        customTemplates.removeAll { $0.id == id }
        bump()
    }

    func deleteNote(id: String) async throws {
        noteRecords.removeAll { $0.id == id }
        bump()
    }
}

// MARK: - TagEditorDataSource

extension MockWorld: TagEditorDataSource {
    func tags(forConversation id: String) async throws -> [ConversationTag] {
        guard let index = index(of: id) else { return [] }
        return conversations[index].tags
    }

    func suggestions(forConversation id: String) async throws -> [String] {
        guard let index = index(of: id) else { return [] }
        let present = Set(conversations[index].tags.map { $0.name.lowercased() })
        return ["budget", "evening", "family"].filter { !present.contains($0) }
    }

    func addTag(conversationId: String, name: String) async throws {
        guard let index = index(of: conversationId) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !conversations[index].tags.contains(where: {
                  $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
              })
        else { return }
        conversations[index].tags.append(
            ConversationTag(id: "tag-\(trimmed.lowercased())", name: trimmed, source: "user"))
        bump()
    }

    func removeTag(conversationId: String, tagId: String) async throws {
        guard let index = index(of: conversationId) else { return }
        conversations[index].tags.removeAll { $0.id == tagId }
        bump()
    }

    func renameTag(tagId: String, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Global rename (Q10): every conversation carrying the tag updates.
        for index in conversations.indices {
            for tagIndex in conversations[index].tags.indices
            where conversations[index].tags[tagIndex].id == tagId {
                let old = conversations[index].tags[tagIndex].name
                conversations[index].tags[tagIndex].name = trimmed
                if let count = extraTagCounts.removeValue(forKey: old) {
                    extraTagCounts[trimmed] = count
                }
            }
        }
        bump()
    }
}

// MARK: - PeopleDataSource

extension MockWorld: PeopleDataSource {
    func people() async throws -> [Person] { peopleRegistry }

    func assign(conversationId: String, label: String, personName: String) async throws {
        let trimmed = personName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !peopleRegistry.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            peopleRegistry.append(Person(id: UUID().uuidString.lowercased(), name: trimmed))
        }
        guard let index = index(of: conversationId) else { return }
        conversations[index].transcript = conversations[index].transcript.map { item in
            guard case .turn(var turn) = item, turn.speakerLabel == label else { return item }
            turn.name = trimmed
            if turn.role == .unresolved { turn.role = .other }
            return .turn(turn)
        }
        bump()
    }
}
