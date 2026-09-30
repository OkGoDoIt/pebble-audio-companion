import AppDB
import Foundation

// The pipeline's `.briefs` stage (plan 7.4, Phase 3 steps 24–25): the short things History's week
// and month pages are made of, written on purpose instead of cut out of something long.
//
//   1. A HEADLINE AND A LINE PER DAY, from the day recap (`DayBrief`). Stored beside the recap and
//      guarded by a fingerprint of its text, like the condensed form (`RecapCondenser`): asked
//      once per recap text — an answer that is refused still stamps the fingerprint, so a recap
//      the model cannot label is left alone — and a regenerated recap invalidates it.
//   2. A BRIEF PER WEEK, from its days' headlines, lines and recaps; then 3. A BRIEF PER MONTH,
//      from its weeks' briefs (`PeriodBriefWriter`), in `period_briefs`. Each is stored with a
//      fingerprint of the input it read, and regenerates only when that changes — and no more
//      often than every three hours for the week being lived, once a day for the month.
//
// Order matters: a week is only briefed once every one of its recapped days has had its
// headline pass, and a month once its weeks have been briefed, so a week brief is never written
// from half its days and then written again an hour later when the rest land.
//
// Cost: nothing, when nothing is owed. The pass decides that (`PipelinePassMemory`): this runs
// when a recap was written, when an earlier run left work, or when a current period's cadence
// comes round — and says which of those applies in `PeriodBriefPassOutcome.nextDueAtMs`. When it
// does run it reads the recaps and briefs tables whole (tens of rows, a few kilobytes), never a
// transcript. The first run on an existing library owes every day, week and month at once — 64
// days on the 2026-09-30 backup — and fills in newest first, at most `maxCallsPerPass` calls a
// pass, so no single pass is held open for minutes.

/// What one run did and what it left.
public struct PeriodBriefPassOutcome: Equatable, Sendable {
    /// AI calls made.
    public var calls: Int
    /// Whether anything History shows was written.
    public var wrote: Bool
    /// When there is next something to do: nil when nothing is owed, now (or earlier) when this
    /// run stopped at its call budget, later for a current period's cadence or a failure backoff.
    public var nextDueAtMs: Int64?
    /// Set when a call failed. The pass records it against the stage, like the recap's.
    public var failure: PeriodBriefFailed?

    public init(calls: Int = 0, wrote: Bool = false, nextDueAtMs: Int64? = nil, failure: PeriodBriefFailed? = nil) {
        self.calls = calls
        self.wrote = wrote
        self.nextDueAtMs = nextDueAtMs
        self.failure = failure
    }

    public static let nothingOwed = PeriodBriefPassOutcome()
}

/// A brief failed: which one, and the CLASSIFIED kind — never the provider's own words (an OpenAI
/// 401 body quotes the request and part of the key; see `RecapGenerationFailed`).
public struct PeriodBriefFailed: Error, Equatable, Sendable, CustomStringConvertible {
    /// `day:2026-09-22`, `week:2026-09-20`, `month:2026-09`.
    public let key: String
    public let kind: AiFailureKind

    public init(key: String, kind: AiFailureKind) {
        self.key = key
        self.kind = kind
    }

    public var description: String { "brief for \(key) failed (\(kind.rawValue))" }
}

public actor PeriodBriefEngine {
    public typealias RunAi = @Sendable (AiRunRequest) async throws -> RoutedAiResult

    /// Calls one run may make. Enough that a day's change reaches its week and month in one run
    /// (one headline, one week, one month) with room to spare; small enough that a first run over
    /// a whole library does not hold the pass open.
    public static let defaultMaxCallsPerPass = 8
    /// The week being lived is rewritten at most this often; each new recap of today would
    /// otherwise rewrite it every half hour.
    public static let currentWeekIntervalMs: Int64 = 3 * 60 * 60_000
    /// The month being lived, at most once a day.
    public static let currentMonthIntervalMs: Int64 = 24 * 60 * 60_000
    /// The first wait after a failed brief; doubles per consecutive failure, to
    /// `maxFailureBackoffMs`. The recap's numbers, for the recap's reasons.
    public static let firstFailureBackoffMs = DailyRecapEngine.firstFailureBackoffMs
    public static let maxFailureBackoffMs = DailyRecapEngine.maxFailureBackoffMs
    /// Bump when a prompt or the reading of its answer changes: every week and month is then
    /// written again (the day headlines are keyed on their recap text; bumping this does not
    /// redo them).
    public static let promptVersion = 1

    private let recaps: DailyRecapStore
    private let briefs: PeriodBriefStore
    /// Nil = no AI configured: nothing is owed, because nothing can be done.
    private let run: RunAi?
    /// Today's logical day, as History's pages date it.
    private let todayKey: @Sendable () -> String
    /// The first day of the week, as History's pages lay weeks out (`Calendar.firstWeekday`).
    private let firstWeekday: @Sendable () -> Int
    private let nowMs: @Sendable () -> Int64
    private let maxCallsPerPass: Int
    private let log: @Sendable (String) -> Void

    /// Days whose headline pass FAILED, and when they may be tried again. In memory, like the
    /// recap's own: a relaunch costs one attempt, not a loop. Periods keep theirs in the table.
    private var dayFailures: [String: Failure] = [:]

    struct Failure: Equatable {
        var count: Int
        var nextAttemptAtMs: Int64
    }

    public init(
        recaps: DailyRecapStore,
        briefs: PeriodBriefStore,
        run: RunAi?,
        todayKey: @escaping @Sendable () -> String,
        firstWeekday: @escaping @Sendable () -> Int = { Calendar.current.firstWeekday },
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        maxCallsPerPass: Int = PeriodBriefEngine.defaultMaxCallsPerPass,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.recaps = recaps
        self.briefs = briefs
        self.run = run
        self.todayKey = todayKey
        self.firstWeekday = firstWeekday
        self.nowMs = nowMs
        self.maxCallsPerPass = maxCallsPerPass
        self.log = log
    }

    static func failureBackoffMs(afterFailures count: Int) -> Int64 {
        min(firstFailureBackoffMs << Int64(min(max(count - 1, 0), 8)), maxFailureBackoffMs)
    }

    /// Every failed brief may be tried again now — the AI configuration changed.
    public func resetFailureBackoff() async {
        dayFailures.removeAll()
        do { try await briefs.clearFailureBackoff() } catch {
            log("briefs: could not clear the failure backoff — \(error.localizedDescription)")
        }
    }

    // MARK: - One run

    /// What a period came to in this run, for the level above it.
    enum PeriodState: Equatable {
        /// Its brief describes its members as they are now (or it has nothing to describe).
        case settled
        /// Its brief is behind its members but may not be rewritten yet (the current period's
        /// cadence). What is there stands in for it.
        case cadence
        /// Behind, and owed a call — or waiting for the level below it. The level above waits.
        case owed
    }

    /// Writes what is owed, newest first, up to `maxCallsPerPass` calls.
    ///
    /// Throws only what the stores throw. A failed AI call is RETURNED (`failure`) after its
    /// backoff has been recorded, so the caller learns when to come back before it reports the
    /// failure; the run stops there, because the periods behind it would ask the same failing
    /// provider the same kind of question.
    public func refresh(onProgress: (@Sendable () -> Void)? = nil) async throws -> PeriodBriefPassOutcome {
        guard let run else { return .nothingOwed }
        let now = nowMs()
        var outcome = PeriodBriefPassOutcome()
        func owe(_ atMs: Int64) {
            outcome.nextDueAtMs = min(outcome.nextDueAtMs ?? atMs, atMs)
        }

        // 1. Days.
        var days = try await recaps.list().sorted { $0.dateKey > $1.dateKey }
        for index in days.indices where DayBrief.needsPass(days[index]) {
            let recap = days[index]
            if let failure = dayFailures[recap.dateKey], now < failure.nextAttemptAtMs {
                owe(failure.nextAttemptAtMs)
                continue
            }
            guard outcome.calls < maxCallsPerPass else {
                owe(now)
                break
            }
            try Task.checkCancellation()
            guard let input = DayBrief.input(recap) else { continue }
            outcome.calls += 1
            let answer: DayBrief.Answer
            do {
                let result = try await call(
                    run, DayBrief.prompt, input: input, requestId: "day-brief-\(recap.dateKey)-\(now)")
                answer = DayBrief.parse(result.text)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = noteDayFailure(recap.dateKey, error)
                owe(failure.nextAttemptAtMs)
                outcome.failure = PeriodBriefFailed(key: "day:\(recap.dateKey)", kind: AiFailure.classify(error).kind)
                return outcome
            }
            onProgress?()
            dayFailures[recap.dateKey] = nil
            try await recaps.saveDayBrief(
                dateKey: recap.dateKey, sourceText: recap.text, headline: answer.headline,
                lineSummary: answer.lineSummary)
            days[index].headline = answer.headline
            days[index].lineSummary = answer.lineSummary
            days[index].briefOfHash = RecapCondenser.fingerprint(recap.text)
            outcome.wrote = true
            log(
                answer.isEmpty
                    ? "briefs: day \(recap.dateKey) — answer unusable, left to the fallbacks"
                    : "briefs: day \(recap.dateKey) — \(answer.headline == nil ? "line only" : "headline")")
        }

        let today = todayKey()
        let weekday = firstWeekday()
        let readable = days.filter { DayBrief.input($0) != nil }
        var stored = Dictionary(uniqueKeysWithValues: try await briefs.all().map { ($0.periodKey, $0) })

        // 2. Weeks, newest first.
        var weekOf: [String: ClosedRange<String>] = [:]
        var membersOf: [String: [DailyRecap]] = [:]
        for recap in readable {
            let week = HistoryCalendar.week(containing: recap.dateKey, firstWeekday: weekday)
            let key = PeriodBriefKey.week(firstDateKey: week.lowerBound)
            weekOf[key] = week
            membersOf[key, default: []].append(recap)
        }
        var weekState: [String: PeriodState] = [:]
        for key in weekOf.keys.sorted(by: >) {
            let week = weekOf[key]!
            let members = (membersOf[key] ?? []).sorted { $0.dateKey < $1.dateKey }
            // A day still owed its headline: the week waits for it.
            if members.contains(where: DayBrief.needsPass) {
                weekState[key] = .owed
                continue
            }
            let input = PeriodBriefWriter.weekInput(
                members.map { recap in
                    let current = DayBrief.current(recap)
                    return PeriodBriefWriter.DayEntry(
                        dateKey: recap.dateKey, headline: current.headline,
                        lineSummary: current.lineSummary, recap: DayBrief.input(recap) ?? "")
                })
            let decision = decide(
                stored[key], sourceHash: Self.sourceHash(input), isCurrent: week.contains(today),
                intervalMs: Self.currentWeekIntervalMs, calls: outcome.calls, now: now)
            weekState[key] = decision.state
            if let dueAt = decision.dueAtMs { owe(dueAt) }
            guard decision.call else { continue }
            try Task.checkCancellation()
            outcome.calls += 1
            switch try await write(
                key, kind: .week, prompt: PeriodBriefWriter.weekPrompt, input: input, previous: stored[key],
                run: run, now: now)
            {
            case .written(let brief):
                stored[key] = brief
                weekState[key] = .settled
                outcome.wrote = true
                onProgress?()
            case .failed(let failure, let nextAttemptAtMs):
                owe(nextAttemptAtMs)
                outcome.failure = failure
                return outcome
            }
        }

        // 3. Months, newest first, from the weeks overlapping them.
        let months = Set(readable.map { PeriodBriefKey.month(containing: $0.dateKey) })

        // A period with nothing left to describe — its recaps went with deleted audio, or the
        // phone's first weekday moved every week's key — loses its brief rather than keeping
        // one about audio that is gone.
        let orphans = stored.keys.filter { weekOf[$0] == nil && !months.contains($0) }
        if !orphans.isEmpty {
            try await briefs.delete(keys: orphans)
            for key in orphans { stored[key] = nil }
            outcome.wrote = true
            log("briefs: removed \(orphans.count) with nothing left to describe")
        }
        for key in months.sorted(by: >) {
            let firstDay = String(key.dropFirst("month:".count)) + "-01"
            let monthRange = HistoryCalendar.month(containing: firstDay)
            let weeks = HistoryCalendar.weeks(inMonthOf: firstDay, firstWeekday: weekday)
                .filter { weekOf[PeriodBriefKey.week(firstDateKey: $0.lowerBound)] != nil }
            let weekKeys = weeks.map { PeriodBriefKey.week(firstDateKey: $0.lowerBound) }
            // A week still owed its brief: the month waits for it.
            if weekKeys.contains(where: { weekState[$0] == .owed }) { continue }
            let entries = weeks.compactMap { week -> PeriodBriefWriter.WeekEntry? in
                guard let brief = stored[PeriodBriefKey.week(firstDateKey: week.lowerBound)], brief.hasContent
                else { return nil }
                return PeriodBriefWriter.WeekEntry(
                    firstDateKey: week.lowerBound, lastDateKey: week.upperBound, headline: brief.headline,
                    lineSummary: brief.lineSummary, text: brief.text)
            }
            guard !entries.isEmpty else { continue }
            let input = PeriodBriefWriter.monthInput(entries)
            // A past month whose last week is the one being lived changes with it; it keeps the
            // month's once-a-day pace rather than being rewritten every time that week is.
            let isCurrent = monthRange.contains(today) || weeks.contains { $0.contains(today) }
            let decision = decide(
                stored[key], sourceHash: Self.sourceHash(input), isCurrent: isCurrent,
                intervalMs: Self.currentMonthIntervalMs, calls: outcome.calls, now: now)
            if let dueAt = decision.dueAtMs { owe(dueAt) }
            guard decision.call else { continue }
            try Task.checkCancellation()
            outcome.calls += 1
            switch try await write(
                key, kind: .month, prompt: PeriodBriefWriter.monthPrompt, input: input, previous: stored[key],
                run: run, now: now)
            {
            case .written(let brief):
                stored[key] = brief
                outcome.wrote = true
                onProgress?()
            case .failed(let failure, let nextAttemptAtMs):
                owe(nextAttemptAtMs)
                outcome.failure = failure
                return outcome
            }
        }
        return outcome
    }

    // MARK: - A period

    struct Decision: Equatable {
        var state: PeriodState
        /// Make the call now.
        var call: Bool
        /// When to come back, if not settled.
        var dueAtMs: Int64?
    }

    /// Whether a period's brief is owed a call now, later, or not at all.
    func decide(
        _ existing: PeriodBrief?, sourceHash: String, isCurrent: Bool, intervalMs: Int64, calls: Int,
        now: Int64
    ) -> Decision {
        if existing?.sourceHash == sourceHash { return Decision(state: .settled, call: false) }
        if let next = existing?.nextAttemptAtMs, now < next {
            return Decision(state: .owed, call: false, dueAtMs: next)
        }
        // The current period, rewritten within its interval: what is there stands in.
        if isCurrent, let existing, existing.sourceHash != nil, now - existing.updatedAtMs < intervalMs {
            return Decision(state: .cadence, call: false, dueAtMs: existing.updatedAtMs + intervalMs)
        }
        guard calls < maxCallsPerPass else { return Decision(state: .owed, call: false, dueAtMs: now) }
        return Decision(state: .owed, call: true)
    }

    enum WriteResult {
        case written(PeriodBrief)
        case failed(PeriodBriefFailed, nextAttemptAtMs: Int64)
    }

    private func write(
        _ key: String, kind: PeriodBriefKind, prompt: AiPromptTemplate, input: String,
        previous: PeriodBrief?, run: RunAi, now: Int64
    ) async throws -> WriteResult {
        let result: RoutedAiResult
        do {
            result = try await call(run, prompt, input: input, requestId: "\(prompt.id)-\(key)-\(now)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let attempts = (previous?.attempts ?? 0) + 1
            let wait = Self.failureBackoffMs(afterFailures: attempts)
            let failureKind = AiFailure.classify(error).kind
            log(
                "briefs: \(key) failed (\(failureKind.rawValue)); next try in \(wait / 60_000) min — "
                    + AiFailureLog.detail(of: error).prefix(200))
            // Recorded where the next run will find it, which also survives a relaunch.
            try await briefs.saveFailure(
                periodKey: key, kind: kind, attempts: attempts, nextAttemptAtMs: now + wait,
                errorKind: failureKind.rawValue)
            return .failed(PeriodBriefFailed(key: key, kind: failureKind), nextAttemptAtMs: now + wait)
        }
        let answer = PeriodBriefWriter.parse(result.text)
        let hash = Self.sourceHash(input)
        try await briefs.saveCompleted(
            periodKey: key, kind: kind, text: answer.text, headline: answer.headline,
            lineSummary: answer.lineSummary, sourceHash: hash, provider: result.providerId,
            model: result.modelUsed, atMs: now)
        log(
            answer.isEmpty
                ? "briefs: \(key) — answer unusable, left to the fallbacks"
                : "briefs: \(key) written (\(answer.text?.count ?? 0) chars)")
        return .written(
            PeriodBrief(
                periodKey: key, kind: kind, text: answer.text, headline: answer.headline,
                lineSummary: answer.lineSummary, sourceHash: hash, provider: result.providerId,
                model: result.modelUsed, updatedAtMs: now))
    }

    // MARK: - Helpers

    /// One call over our own prose, passed through as it is (`prebuilt`: no transcript header
    /// for the model to quote back). A provider that read only part of it is a failure, never an
    /// answer: every brief is stored as describing its whole input.
    private func call(
        _ run: RunAi, _ prompt: AiPromptTemplate, input: String, requestId: String
    ) async throws -> RoutedAiResult {
        let result = try await run(
            AiRunRequest(
                requestId: requestId, prompt: prompt,
                transcripts: [
                    TranscriptExcerpt(
                        segmentId: AiTranscriptFormatting.prebuiltSegmentId, text: input, startTimeMs: nil)
                ]))
        guard !result.inputTruncated else {
            throw AiError.providerFailed("The provider read only part of the \(prompt.title.lowercased()) input")
        }
        return result
    }

    private func noteDayFailure(_ dateKey: String, _ error: Error) -> Failure {
        let count = (dayFailures[dateKey]?.count ?? 0) + 1
        let wait = Self.failureBackoffMs(afterFailures: count)
        let failure = Failure(count: count, nextAttemptAtMs: nowMs() + wait)
        dayFailures[dateKey] = failure
        log(
            "briefs: day \(dateKey) failed (\(AiFailure.classify(error).kind.rawValue)); next try in "
                + "\(wait / 60_000) min — " + AiFailureLog.detail(of: error).prefix(200))
        return failure
    }

    /// What a period's brief was made from: the prompt's version and the exact input — the
    /// members' keys and every word of theirs it read.
    static func sourceHash(_ input: String) -> String {
        RecapCondenser.fingerprint("v\(promptVersion)\n\(input)")
    }
}
