import CoreSpotlight
import Foundation
import Testing

// Does Core Spotlight rank this app's donations by MEANING on this runtime?
//
// The Ask recall experiment is only interesting where it does. Nothing the app can do turns
// semantic ranking on — it is an OS capability of the device — so it is checked, not assumed:
// donate two conversations, ask about one in words that appear in neither, see which comes
// back. The same probe sits behind "Check meaning search" on the DEBUG Diagnostics screen.
//
// What this test can and cannot say, measured on 2026-09-18 (Xcode 27.0, iOS 27.0 simulator):
// `AppTests` is a logic bundle with no host app. In that process
// `CSSearchableIndex.isIndexingAvailable()` is true and a donation is accepted, but NO query
// returns it — with or without the domain filter — and the console shows the process is not
// entitled to the linguistic assets Spotlight ranks with. So a `.lexicalMissing` verdict here
// is "not an app", not a defect, and the test reports it and stops. Inside the real app on
// the same simulator the probe returns `.semantic` (see the session log). The one outcome
// this test does fail on is `.filterHidesDonations`, because that would be our own bug.

@Suite("ask recall semantic probe") @MainActor
struct AskRecallSemanticProbeTests {
    #if DEBUG
        @Test func theProbeReportsWhetherMeaningRanksOnThisRuntime() async throws {
            let lines = LineSink()
            let verdict = await AskRecallSemanticProbe.run(log: { lines.append($0) })
            print("[ask recall probe] verdict=\(verdict) — \(verdict.line)")
            for line in lines.lines { print("[ask recall probe] \(line)") }

            switch verdict {
            case .indexUnavailable, .lexicalMissing:
                // Not an app process (see the header): nothing to judge here. The device
                // row and the in-app simulator run are the check.
                return
            case .filterHidesDonations:
                Issue.record(
                    "the domain filter hides this app's own donations: \(verdict.line)")
            case .lexicalOnly, .semanticMisranked:
                // A real query path with no semantic ranking: a fact about the runtime, worth
                // seeing in the run, not a failure of the code.
                withKnownIssue(
                    Comment(
                        rawValue: "semantic ranking is an OS capability; lexical-only is a "
                            + "valid outcome on this runtime"),
                    isIntermittent: true
                ) {
                    #expect(verdict == .semantic, "verdict was \(verdict): \(verdict.line)")
                }
            case .semantic:
                #expect(verdict == .semantic)
            }
        }
    #endif
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}
