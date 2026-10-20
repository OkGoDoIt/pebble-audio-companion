import Foundation

// What Siri says and shows for Pebble Audio: the answers of the Get intents and Ask My Archive,
// and the answer card. Static intent metadata (titles, descriptions, phrases, parameter names)
// cannot live here; `appintentsmetadataprocessor` needs those as inline literals (see
// `CaptureIntents.swift`). Everything decided at run time does.
//
// Siri reads these aloud, so each one has to make sense heard once, with no screen: it names the
// app where the listener would otherwise not know who is talking, and never points at something
// only visible on the card.

extension Copy {
    enum Siri {
        /// The person's own setting, named, rather than an empty answer that looks like a fault.
        static func offForSiri(_ what: String) -> String {
            "Siri & Spotlight can see is set to Off, so \(what) stay in Pebble Audio."
        }

        static func conversationsFound(_ count: Int) -> String {
            switch count {
            case 0: return "No conversations in that period."
            case 1: return "Found 1 conversation."
            default: return "Found \(count) conversations."
            }
        }

        static func followUpsFound(_ count: Int) -> String {
            switch count {
            case 0: return "No follow-ups."
            case 1: return "1 follow-up."
            default: return "\(count) follow-ups."
            }
        }

        // ── Ask My Archive ───────────────────────────────────────────────────

        // A card with no answer on it: a heading (shown above the card) plus at most one line on
        // it, each said once. The spoken dialog below each is the whole of it, for AirPods.
        static let notReadyHeading = "Still starting up"
        static let notReadyLine = "Try again in a moment."
        static let offHeading = "Kept in Pebble Audio"
        static let offLine = "Siri & Spotlight can see is set to Off."
        static let nothingRecordedHeading = "Nothing recorded yet"
        static let tookTooLongHeading = "Taking longer than Siri waits"
        static let tookTooLongLine = "Ask in Pebble Audio for the full answer."
        /// Its line is the AI failure's own sentence, when there is one worth saying.
        static let noAnswerHeading = "No answer this time"
        /// Past Siri's wait, the question carries on in the app.
        static let continuePrompt =
            "That is taking longer than Siri can wait. Continue in Pebble Audio?"
        static let continuingHeading = "Opening in Pebble Audio"
        static let continuingInApp = "Opening Ask in Pebble Audio for the full answer."

        /// A Siri request that raced the app's own start-up.
        static let notReady = "Pebble Audio is still starting up. Try again in a moment."
        static let nothingRecorded =
            "Nothing is recorded yet, so there is nothing to answer from."
        /// Ask is still working when Siri stops waiting. The card's button asks again in the app,
        /// where the answer is shown with its sources.
        static let tookTooLong =
            "That is taking longer than Siri can wait. Ask in Pebble Audio for the full answer."
        /// `reason` is the AI failure's own sentence (`Copy.AiFailure`), which already says
        /// what to do about it; nil when there is nothing more useful to say than this.
        static func couldNotAnswer(_ reason: String?) -> String {
            guard let reason, !reason.isEmpty else { return "Pebble Audio couldn't answer that." }
            return "Pebble Audio couldn't answer that. \(reason)"
        }

        /// The period as it reads inside a sentence.
        static func periodPhrase(_ period: AskArchivePeriod) -> String {
            switch period {
            case .today: return "today"
            case .yesterday: return "yesterday"
            case .last7Days: return "in the last 7 days"
            }
        }

        /// The period as the card's label shows it — the same words as Ask's scope pill.
        static func periodLabel(_ period: AskArchivePeriod) -> String {
            switch period {
            case .today: return Copy.Ask.scopeToday
            case .yesterday: return Copy.Ask.scopeYesterday
            case .last7Days: return Copy.Ask.scopeLast7Days
            }
        }

        /// The heading Siri shows above the card: what the answer was drawn from. No closing
        /// period, like every other card heading; the answer itself is what is read aloud.
        /// `summariesOnly` (Titles and summaries) says so, because that is all that was read.
        static func supporting(
            read: Int?, period: AskArchivePeriod, summariesOnly: Bool = false
        ) -> String {
            let when = periodPhrase(period)
            let of = summariesOnly ? "summaries of " : ""
            switch read {
            case .none:
                return summariesOnly
                    ? "From your conversation summaries \(when)"
                    : "From your conversations \(when)"
            case .some(1): return "From \(of)1 conversation \(when)"
            case .some(let n): return "From \(of)\(n) conversations \(when)"
            }
        }

        /// Said after a partial answer, the spoken twin of Ask's `partialCoverage` footnote.
        static func partiallyRead(
            read: Int, inScope: Int, period: AskArchivePeriod, summariesOnly: Bool = false
        ) -> String {
            let what = summariesOnly ? "the summaries of " : ""
            return "Pebble Audio read \(what)\(read) of the \(inScope) conversations "
                + "\(periodPhrase(period))."
        }

        /// Ask's `partialCoverage` line, for an answer read from summaries alone.
        static func partialSummaries(read: Int, inScope: Int) -> String {
            "Read the summaries of \(read) of \(inScope) conversations — anything not mentioned "
                + "may not have been reached."
        }

        static func moreSources(_ count: Int) -> String { "and \(count) more" }
        static let openInAsk = "Open in Ask"
        static let askInApp = "Ask in Pebble Audio"
    }
}
