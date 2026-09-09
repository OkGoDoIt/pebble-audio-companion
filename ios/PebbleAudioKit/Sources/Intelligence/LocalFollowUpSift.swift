import Foundation

// The model-free half of on-device follow-up extraction.
//
// WHY THIS EXISTS AT ALL. The cloud path hands a whole conversation to a large model and asks
// it to exercise judgement over the lot. Apple's on-device model cannot do that, and the
// failure is not subtle. Measured against twenty real conversations from this user's own
// recordings (149,343 characters, hand-labelled: eight genuine follow-ups), a straight guided
// extraction over chunks of the transcript returned **111 items, seven of them right** —
// precision 0.07. It is not a prompting problem: minimal prompts, the compressed cloud prompt,
// a screening schema whose fields force the tests to be answered before the task is written,
// per-item verification, and a budgeted "at most two of these" comparison pass all landed
// between 0.00 and 0.19. The model says yes to anything commitment-shaped.
//
// WHAT IT CAN DO is answer one closed question about one sentence. So the work is divided:
//
//   • this file finds the few sentences that could possibly be a commitment, deterministically;
//   • the model judges them one at a time, and writes the ones that survive
//     (`FoundationModelsStructured.swift`);
//   • this file then throws away anything whose written form fails a check arithmetic can make.
//
// On the same twenty conversations that pipeline returns FOUR items: three of the eight
// labelled follow-ups, one defensible, and nothing plainly wrong. Recall 0.38, and no false
// positive on this panel — which is emphatically not a claim that it never produces one, on a
// sample of four. It judged 84 of the panel's 3,852 sentences (2.2%) and took 149 seconds of
// wall clock for 149,343 characters on an M-series Mac.
//
// That is the honest shape of the local path — it misses most of what the cloud reader finds,
// and it never proposes a date, because every date the model produced was the recording's own
// day stamped on everything. `Copy.LocalFollowUps` says exactly that on screen.
//
// Everything here is pure and synchronous so it can be pinned by tests on a machine with no
// Apple Intelligence at all.

public enum LocalFollowUpSift {
    // MARK: - Tuning, all of it earned on the panel

    /// Turns of conversation shown either side of a candidate. "I'll do it tomorrow" cannot be
    /// judged alone and is obvious with one line around it.
    public static let contextTurns = 2

    /// A candidate sentence must be at least this many words. Below it the model is judging
    /// fragments — "But we'll see", "We'll need the key somewhere" — and every one of those that
    /// survived to the list was wrong.
    public static let minimumCandidateWords = 9

    /// The most sentences one conversation may cost. A four-hour recording produced 105
    /// candidates; each is a model call, and this runs in the background on a phone.
    public static let maxCandidatesPerConversation = 40

    /// A written task shorter than this is not a thing anybody can act on: the model returns
    /// "finish", "make reservation" and "pay" freely.
    public static let minimumTaskWords = 4
    public static let maximumTaskWords = 18

    // MARK: - Finding candidate sentences

    /// Explicit first-person undertakings. Deliberately narrower than the phrasings a person
    /// actually uses: "I can", "I should", "I want to", "let's", "we'll" and "make sure" are how
    /// people think out loud, and admitting them roughly doubled the false positives while
    /// adding nothing this pipeline could keep. It costs real recall — three of the eight
    /// labelled follow-ups are phrased that way and this filter cannot see them — and that
    /// trade is the whole reason the local path is described to the user as the cautious one.
    static let cuePattern: NSRegularExpression = {
        let alternatives = [
            "i'?ll", "i will", "i'?m going to", "i'?m gonna",
            "i need to", "i have to", "i'?ve got to", "i got to", "i gotta",
            // Present progressive standing in for a future: "I'm sending that over to you".
            "i'?m (bringing|sending|getting|taking|picking|dropping|calling|buying|booking"
                + "|paying|meeting)",
            "we need to", "we have to", "we'?ve got to", "we got to", "we gotta",
            "remind me", "don'?t forget",
        ]
        // Force-try: the pattern is a literal, and a typo in it must fail the first test run
        // rather than silently disable extraction on every device.
        return try! NSRegularExpression(
            pattern: "\\b(" + alternatives.joined(separator: "|") + ")\\b",
            options: [.caseInsensitive])
    }()

    /// Openings that mean the sentence is aimed at somebody else, whatever cue follows.
    static let requestPattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^\s*(please\b|can you\b|could you\b|would you\b|do you\b|did you\b"#
            + #"|are you\b|will you\b)"#,
        options: [.caseInsensitive])

    /// One sentence worth judging, with enough of the conversation around it to judge by.
    public struct Candidate: Equatable, Sendable {
        public let sentence: String
        public let context: String

        public init(sentence: String, context: String) {
            self.sentence = sentence
            self.context = context
        }
    }

    /// Candidate sentences from a rendered conversation (`FollowUpTranscriptRenderer.render`).
    public static func candidates(in rendered: String) -> [Candidate] {
        let turns = rendered.split(separator: "\n").map(String.init).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("---")
                && !trimmed.hasPrefix("Recorded:") && !trimmed.hasPrefix("Conversation:")
                && !trimmed.hasPrefix("Summary so far:")
        }
        var out: [Candidate] = []
        var seen = Set<String>()
        for (index, turn) in turns.enumerated() {
            let body = turn.replacingOccurrences(
                of: #"^S[^:]{0,4}:\s*"#, with: "", options: .regularExpression)
            for sentence in sentences(in: body) {
                guard out.count < maxCandidatesPerConversation else { return out }
                guard isCandidate(sentence) else { continue }
                let key = FollowUpQuoteLocator.normalize(sentence)
                guard key.count >= 12, seen.insert(key).inserted else { continue }
                let lower = max(0, index - contextTurns)
                let upper = min(turns.count - 1, index + contextTurns)
                out.append(
                    Candidate(
                        sentence: sentence,
                        context: turns[lower...upper].joined(separator: "\n")))
            }
        }
        return out
    }

    /// Whether one sentence is worth a model call.
    public static func isCandidate(_ sentence: String) -> Bool {
        guard words(sentence).count >= minimumCandidateWords else { return false }
        // A question is somebody asking, not somebody undertaking.
        guard !sentence.contains("?") else { return false }
        guard !matches(requestPattern, sentence) else { return false }
        return matches(cuePattern, sentence)
    }

    /// Sentence split that tolerates the transcriber's punctuation, which is approximate.
    public static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 1 { out.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 1 { out.append(trimmed) }
        return out
    }

    // MARK: - Judging what came back

    /// The verbs an errand is made of. An obligation somebody is still carrying tomorrow is
    /// almost always one transitive verb and an object; thinking aloud is not, and neither is
    /// narration. Requiring one in BOTH the written task and the quote it came from is the
    /// single most effective filter measured — on the panel it took the sift's precision from
    /// 0.16 to 0.62 in one step, without dropping a single correct item, because it is also a
    /// cheap entailment check: a task whose verb appears nowhere in its own quote was invented
    /// rather than read.
    ///
    /// "take", "get", "make" and "move" are deliberately NOT here. They are verbs of doing
    /// anything at all, and every remaining false positive on the panel came in through one of
    /// them — "Take a look at the draft" out of "if it's a good fit, I'll take a look". No
    /// labelled follow-up needs them.
    static let errandVerbs = [
        "pay", "send", "call", "email", "text", "book", "bring", "pick up", "drop off", "buy",
        "order", "cancel", "renew", "sign", "submit", "return", "collect", "fill", "fill out",
        "update", "schedule", "meet", "deliver", "print", "register", "sign up",
        "apply", "reserve", "confirm", "reply", "respond", "post", "mail", "ship", "pack",
        "clean", "fix", "repair", "install", "export", "upload", "download", "check out",
        "hand in", "write", "finish", "arrange", "set up", "enable", "transfer",
    ]

    static let errandVerbPattern: NSRegularExpression = try! NSRegularExpression(
        pattern: "\\b(" + errandVerbs.joined(separator: "|") + ")\\b",
        options: [.caseInsensitive])

    /// The task has to OPEN with one, because a task is an imperative sentence and an
    /// imperative starts with its verb. This is what separates "Pay Owen what you owe him" from
    /// "Show up in the text message group", where the only errand word in sight is the noun
    /// "text". Anchoring the verb rather than lengthening the stop-list is the rule that made
    /// the panel's remaining false positives go away without touching a correct item.
    static let errandVerbOpeningPattern: NSRegularExpression = try! NSRegularExpression(
        pattern: "^\\W*(" + errandVerbs.joined(separator: "|") + ")\\b",
        options: [.caseInsensitive])

    /// A diarizer label the model copied into the task as if it were somebody's name.
    static let speakerLabelPattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"\bS[1-9]\b"#)

    /// A task that says it happens now is, by definition, not a follow-up.
    static let presentTensePattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"\b(right now|now|currently|as we speak)\b"#, options: [.caseInsensitive])

    /// Wreckage a damaged transcript leaves behind. A quote holding it is not a sentence
    /// anybody can act on tomorrow.
    static let garblePattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"(—\s*$)|(\.\.\.$)|(\b(uh|um|er)\b.{0,40}\b(uh|um|er)\b)"#,
        options: [.caseInsensitive])

    /// Why a written item was thrown away, or nil when it may ship. Named rather than boolean
    /// so a rejection can be logged and argued with.
    public static func rejection(task: String, quote: String) -> String? {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTask.isEmpty { return "task is empty" }
        if trimmedTask.contains("**") || trimmedTask.contains("`") {
            return "task carries markdown"
        }
        if trimmedTask.range(of: #"(?i)\b(owner|due)\s*:"#, options: .regularExpression) != nil {
            return "task carries a field label"
        }
        let taskWords = words(trimmedTask)
        if taskWords.count < minimumTaskWords { return "task is too short to act on" }
        if taskWords.count > maximumTaskWords { return "task is too long to be one action" }
        if matches(speakerLabelPattern, trimmedTask) { return "task names a speaker label" }
        if matches(presentTensePattern, trimmedTask) { return "task happens now" }
        if !matches(errandVerbOpeningPattern, trimmedTask) {
            return "task does not open with a concrete action"
        }
        if !matches(errandVerbPattern, quote) { return "the quote does not contain the action" }
        if matches(garblePattern, quote) { return "the quote is too damaged to be sure of" }
        return nil
    }

    // MARK: - Assembling the answer the existing parsers already read

    /// One item as the on-device path produces it. Deliberately fewer fields than the cloud
    /// schema: no due date, because the model stamped the recording's own date on every item it
    /// returned, and a valid-looking wrong date is worse than none; and confidence is always
    /// `low`, which is the truth and is what `FollowUpCurator` is shown.
    public struct Item: Equatable, Sendable {
        public var task: String
        public var quote: String
        public var ifForgotten: String

        public init(task: String, quote: String, ifForgotten: String) {
            self.task = task
            self.quote = quote
            self.ifForgotten = ifForgotten
        }
    }

    /// The `follow_ups` JSON body `FollowUpExtractionParser.parse` already consumes, so nothing
    /// downstream of the provider seam knows or cares which model produced it.
    public static func extractionJSON(_ items: [Item]) -> String {
        let payload = ExtractedFollowUps(
            items: items.map {
                ExtractedFollowUp(
                    task: $0.task, quote: $0.quote, ifForgotten: $0.ifForgotten,
                    dueDate: "", confidence: "low")
            })
        guard let data = try? JSONEncoder().encode(payload),
            let text = String(data: data, encoding: .utf8)
        else { return #"{"items":[]}"# }
        return text
    }

    /// The `follow_up_curation` JSON body `FollowUpCurationParser.parse` already consumes.
    ///
    /// Curation on-device is DROP-ONLY: it never rewrites the task, never sets a priority other
    /// than normal, and never proposes a date. Measured, a second opinion from this model is
    /// worth roughly nothing — a per-item verification pass changed the panel's precision by
    /// 0.00, and a "which two of these belong?" comparison pass made it worse (0.18 → 0.00 on
    /// the looser candidate set, because its ranking is anti-correlated with the truth). What it
    /// can still do safely is throw things away: in the same runs it never once dropped a
    /// correct item. So it is allowed to subtract and nothing else.
    public static func curationJSON(decisions: [(index: Int, keep: Bool, reason: String)])
        -> String
    {
        let payload = CurationDecisions(
            decisions: decisions.map {
                CurationDecision(
                    index: $0.index, decision: $0.keep ? "keep" : "drop",
                    reason: $0.reason.isEmpty
                        ? ($0.keep ? "kept by the on-device reader"
                            : "dropped by the on-device reader")
                        : $0.reason,
                    task: "", priority: "normal", dueDate: "")
            })
        guard let data = try? JSONEncoder().encode(payload),
            let text = String(data: data, encoding: .utf8)
        else { return #"{"decisions":[]}"# }
        return text
    }

    /// The numbered candidate blocks out of a curation prompt body — the `1. <task>` line plus
    /// the indented `heard:` / `if forgotten:` / `recorded:` lines under it. Reading them back
    /// out of the prompt keeps the provider seam a string, so `FollowUpCurator` does not have to
    /// hand the on-device path a second, parallel representation of the same batch.
    public struct NumberedCandidate: Equatable, Sendable {
        public let index: Int
        public let block: String

        public init(index: Int, block: String) {
            self.index = index
            self.block = block
        }
    }

    public static func numberedCandidates(in promptBody: String) -> [NumberedCandidate] {
        var out: [NumberedCandidate] = []
        var current: (index: Int, lines: [String])?
        func flush() {
            guard let open = current, !open.lines.isEmpty else { return }
            out.append(
                NumberedCandidate(index: open.index, block: open.lines.joined(separator: "\n")))
            current = nil
        }
        for raw in promptBody.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")
            if !isIndented, let dot = trimmed.firstIndex(of: "."),
                let number = Int(trimmed[trimmed.startIndex..<dot]), number >= 1,
                !trimmed[trimmed.index(after: dot)...]
                    .trimmingCharacters(in: .whitespaces).isEmpty
            {
                flush()
                current = (
                    number,
                    [
                        trimmed[trimmed.index(after: dot)...]
                            .trimmingCharacters(in: .whitespaces)
                    ]
                )
                continue
            }
            if current != nil, isIndented, !trimmed.isEmpty {
                current?.lines.append(trimmed)
                continue
            }
            if current != nil, trimmed.isEmpty { continue }
            if current != nil, !isIndented { flush() }
        }
        flush()
        return out
    }

    // MARK: - Small shared helpers

    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
