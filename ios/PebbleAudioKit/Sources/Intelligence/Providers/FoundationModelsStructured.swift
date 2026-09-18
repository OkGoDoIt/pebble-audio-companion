import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    // Guided generation for `FoundationModelsLanguageModel`. Split out of the bridge itself so
    // the prose path stays four lines long and this — which is a small pipeline, not an API
    // call — has room to explain itself.
    //
    // The shape of the work and the numbers behind it are in `LocalFollowUpSift`. In one line:
    // this model cannot read a conversation and decide what matters in it, but it can answer one
    // closed question about one sentence, so that is all it is ever asked to do.

    /// A synchronous readiness check. `SystemLanguageModel.availability` is a plain property, so
    /// this needs no await and can answer a computed property on the main actor.
    enum FoundationModelsAvailability {
        static var isReadyNow: Bool {
            if #available(iOS 26.0, macOS 26.0, *) {
                return SystemLanguageModel.default.availability == .available
            }
            return false
        }
    }

    // MARK: - The shapes the model is held to

    /// Stage zero, once per conversation. The worst false positives in every run were sentences
    /// out of a stretch of dictation to a coding assistant, judged one at a time with no idea
    /// that is what they were. One call at the top of the conversation removes the whole class.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct RecordingSetting {
        @Guide(
            description: "What this recording mostly is.",
            .anyOf([
                "people talking to each other",
                "one person dictating notes or instructions to a phone or an AI assistant",
                "a microphone test",
                "television, music or a podcast playing",
                "one side of a phone call",
            ]))
        var kind: String
    }

    /// Stage one: one sentence, three closed questions.
    ///
    /// The option strings are short and symmetric on purpose. An earlier version offered
    /// "yes — a specific thing they still have to do" against "no — vague, already handled, or
    /// it would raise a question", and the model answered "no" to everything including "I will
    /// pick up Oliver from school today": given two options it will follow the longer, more
    /// elaborate one. Likewise `ifForgotten` once carried "write exactly 'nothing much' when
    /// there is no real cost" in its description, and the model then wrote "nothing much" for
    /// every single item in the run.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct SentenceVerdict {
        @Guide(
            description: "Who, judged from the words themselves, will carry the action out.",
            .anyOf([
                "the person wearing the microphone", "somebody else",
                "nobody — it is not an action",
            ]))
        var actor: String

        @Guide(
            description: "What kind of sentence this is.",
            .anyOf([
                "a commitment to do something later",
                "something happening as they speak",
                "a wish, a maybe, or an idea",
                "a status update or a description",
                "words dictated to a phone, an app or an AI assistant",
                "small talk, a question, or a pleasantry",
            ]))
        var kind: String

        @Guide(
            description: "Whether it names something specific they still have to do.",
            .anyOf(["specific", "vague"]))
        var specificity: String
    }

    /// Stage two, only for the few that survive stage one.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct WrittenFollowUp {
        @Guide(
            description:
                "One plain imperative sentence naming the concrete action. Under 14 words. "
                + "No markdown, no 'Owner:', no 'Due:'.")
        var task: String

        @Guide(description: "One short clause naming what goes wrong if it never happens.")
        var ifForgotten: String
    }

    /// Curation, one candidate at a time. Keep or drop, and nothing else — see
    /// `LocalFollowUpSift.curationJSON` for why this pass is not allowed to rewrite anything.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct CurationVerdict {
        @Guide(
            description: "Whether this belongs on the person's follow-up list.",
            .anyOf(["keep", "drop"]))
        var decision: String

        @Guide(description: "The reason, in one short clause.")
        var reason: String
    }

    // MARK: - The bridge

    extension FoundationModelsLanguageModel {
        public var supportsStructuredOutput: Bool { FoundationModelsAvailability.isReadyNow }

        public func generateStructured(
            _ shape: OnDeviceStructuredShape,
            instructions: String,
            prompt: String,
            maxOutputTokens: Int?
        ) async throws -> String {
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw OnDeviceStructuredError.unsupported
            }
            switch shape {
            case .followUps:
                return try await extractFollowUps(from: prompt)
            case .followUpCuration:
                return try await curate(prompt)
            }
        }

        // MARK: Follow-up extraction

        @available(iOS 26.0, macOS 26.0, *)
        func extractFollowUps(from rawBody: String) async throws -> String {
            // `AiTranscriptFormatting.buildUserContent` puts the template's user instruction
            // above the transcript. Drop it: the sift reads the body as a sequence of speaker
            // turns, and one extra line at the top silently shifts the context window of the
            // first candidate by a turn.
            let body = Self.transcriptBody(of: rawBody)
            let candidates = LocalFollowUpSift.candidates(in: body)
            guard !candidates.isEmpty else { return LocalFollowUpSift.extractionJSON([]) }
            let recorded = Self.recordedLine(in: body)
            let setting = await classifySetting(body)

            var items: [LocalFollowUpSift.Item] = []
            var seen = Set<String>()
            var refused = 0
            for candidate in candidates {
                try Task.checkCancellation()
                let framing = """
                    Conversation:
                    \(candidate.context)

                    The sentence to judge: "\(candidate.sentence)"
                    """
                do {
                    let verdict = try await respond(
                        to: framing, instructions: Self.siftInstructions(recorded, setting),
                        generating: SentenceVerdict.self, maxTokens: 96)
                    guard verdict.actor.hasPrefix("the person"),
                        verdict.kind.hasPrefix("a commitment"),
                        verdict.specificity.hasPrefix("specific")
                    else { continue }

                    let written = try await respond(
                        to: framing, instructions: Self.writerInstructions,
                        generating: WrittenFollowUp.self, maxTokens: 96)
                    // Arithmetic, after the judgement — the checks the model cannot be relied
                    // on to make for itself. What gets past here is the local path's answer.
                    guard
                        LocalFollowUpSift.rejection(
                            task: written.task, quote: candidate.sentence) == nil
                    else { continue }
                    let why = written.ifForgotten.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !why.isEmpty else { continue }
                    guard
                        seen.insert(FollowUpQuoteLocator.normalize(written.task)).inserted
                    else { continue }
                    items.append(
                        LocalFollowUpSift.Item(
                            task: written.task, quote: candidate.sentence, ifForgotten: why))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A refused SENTENCE must not cost the conversation its other follow-ups.
                    //
                    // This is not hypothetical tidiness: running the panel through the shipped
                    // path, the third real conversation — somebody dictating a complaint to a
                    // delivery app's support desk — came back `guardrailViolation`, and because
                    // one sentence threw, the whole recording failed and burned one of
                    // `FollowUpWorker.maxAttempts`. An always-on microphone hears arguments,
                    // medication, money and swearing; refusals are ordinary here, and they are
                    // about one sentence.
                    refused += 1
                    continue
                }
            }
            // Unless EVERY sentence was refused. Then we did not read this conversation, and
            // saying "nothing here" would settle it at zero for the life of the database.
            // Failing is honest: the worker records an attempt and comes back to it.
            if items.isEmpty, refused == candidates.count {
                throw OnDeviceStructuredError.unsupportedShape(.followUps)
            }
            return LocalFollowUpSift.extractionJSON(items)
        }

        /// Best effort: a failed setting call is not worth failing the whole conversation over,
        /// it only costs the dictation hint.
        @available(iOS 26.0, macOS 26.0, *)
        func classifySetting(_ body: String) async -> String {
            do {
                return try await respond(
                    // The opening is where the tells are, and it is the part that fits.
                    to: String(body.prefix(3_500)),
                    instructions: """
                        You say what a stretch of audio from an always-on wearable microphone \
                        mostly consists of. Spoken punctuation ("full stop", "question mark", \
                        "new paragraph"), a run of second-person instructions with nobody \
                        answering, or coaching aimed at a worker, all mean somebody was \
                        dictating to a phone or an assistant rather than talking to a person.
                        """,
                    generating: RecordingSetting.self, maxTokens: 48
                ).kind
            } catch {
                return "people talking to each other"
            }
        }

        // MARK: Curation

        @available(iOS 26.0, macOS 26.0, *)
        func curate(_ body: String) async throws -> String {
            let candidates = LocalFollowUpSift.numberedCandidates(in: body)
            guard !candidates.isEmpty else { return LocalFollowUpSift.curationJSON(decisions: []) }
            var decisions: [(index: Int, keep: Bool, reason: String)] = []
            for candidate in candidates {
                try Task.checkCancellation()
                do {
                    let verdict = try await respond(
                        to: candidate.block, instructions: Self.curationInstructions,
                        generating: CurationVerdict.self, maxTokens: 64)
                    decisions.append(
                        (
                            index: candidate.index,
                            keep: verdict.decision.lowercased().hasPrefix("keep"),
                            reason: verdict.reason
                        ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A candidate the pass could not reach is KEPT. This model's only useful
                    // contribution here is subtraction; a failure must not become one.
                    decisions.append(
                        (
                            index: candidate.index, keep: true,
                            reason: "the on-device reader could not weigh this one"
                        ))
                }
            }
            return LocalFollowUpSift.curationJSON(decisions: decisions)
        }

        // MARK: Plumbing

        @available(iOS 26.0, macOS 26.0, *)
        private func respond<Content: Generable>(
            to prompt: String, instructions: String, generating type: Content.Type,
            maxTokens: Int
        ) async throws -> Content {
            // Same content-filter setting as the text path — `AppleModelSessions.onDevice()`
            // opens every session on `companionModel`. Extraction is where a refusal is most
            // invisible: the person just gets no follow-ups from that recording.
            try await AppleModelGeneration.respond(
                .onDevice(), to: prompt, instructions: instructions, generating: type,
                maxTokens: maxTokens)
        }

        /// The rendered conversation with anything above its `Recorded:` header removed.
        /// Returns the input unchanged when there is no header to anchor on.
        static func transcriptBody(of raw: String) -> String {
            guard let range = raw.range(of: "Recorded:"), range.lowerBound != raw.startIndex
            else { return raw }
            return String(raw[range.lowerBound...])
        }

        /// The `Recorded: …` header `FollowUpTranscriptRenderer` writes, if it is there.
        static func recordedLine(in body: String) -> String? {
            for line in body.split(separator: "\n").prefix(4) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Recorded:") {
                    return String(trimmed.dropFirst("Recorded:".count))
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }

        static func siftInstructions(_ recorded: String?, _ setting: String) -> String {
            var out = """
                A person wears a microphone through their whole day. You are shown one sentence \
                out of one of those recordings, with a little of the conversation around it, and \
                you answer three closed questions about that one sentence.

                Almost every sentence you see will fail: the recordings are family talk, \
                television, shops, phone calls with one side missing, dictation to an AI \
                assistant, and narration of whatever the person is doing at that moment. \
                Answering "no" is the normal, expected outcome.

                Judge the sentence, not the conversation. Speaker labels (S1, S2) are assigned \
                automatically and are not proof of who spoke — decide from the words. "I'll get \
                it" said while reaching for something is happening as they speak; "I'll send it \
                over when I get back" happens later. A run of instructions with nobody answering, \
                or spoken punctuation ("full stop", "question mark"), means it was dictated. \
                Anything about another person's health, medication, money or private trouble is \
                never worth reminding them of.
                """
            if let recorded { out += "\n\nThe recording was made on \(recorded)." }
            out += "\n\nSomebody who listened to this whole recording says it is mostly: "
                + setting + ". Weigh that."
            if setting.hasPrefix("one person dictating") {
                out += " Sentences from a stretch of dictation were written down by the app that "
                    + "was listening; they are not things this person still has to do."
            }
            return out
        }

        /// Few-shot, because a 3B model writes a far better line from two examples than from a
        /// paragraph of rules — and because without the first example it reliably inverted
        /// "remind me to pay Owen" into "Remind Owen to pay".
        static let writerInstructions = """
            You turn one sentence somebody said into a line on their own follow-up list. The \
            speaker is the person who has to do it, so write it as an instruction to them.

            Write only what the sentence itself supports: never add a name, a place, a time or a \
            step it does not contain, and never leave a relative time word ("tomorrow", \
            "tonight") in the text — a list is read days later.

            Examples.
            Said: "In five days, remind me to pay Owen what I owe him for the print job."
            Task: Pay Owen what you owe him for the print job
            If forgotten: Owen is still owed the money

            Said: "I'll get the revenue slides done by Wednesday."
            Task: Finish the revenue slides
            If forgotten: the deck goes to the meeting without its numbers

            Said: "She's sending me the information so I can sign up for the waitlist."
            Task: Sign up for the waitlist when she sends the information
            If forgotten: the place on the waitlist is lost
            """

        static let curationInstructions = """
            You are the last check before something appears on a person's follow-up list. You \
            see one candidate and the words it was drawn from, and nothing else. If the \
            candidate does not make sense from its own quote, it will not make sense to the \
            person reading it tomorrow either.

            Answer keep only if all of these hold: the quote plainly shows this person taking \
            the action on, rather than asking somebody else to do it or describing what somebody \
            else will do; the action happens after the recording, somewhere else, not as they \
            speak; it is a specific thing to do rather than a topic, a wish or a status update; \
            and forgetting it would cost something real. Otherwise answer drop.
            """
    }
#endif
