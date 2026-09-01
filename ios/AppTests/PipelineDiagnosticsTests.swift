import CompanionRuntime
import Foundation
import Testing

/// What the Diagnostics screen says about the processing pass.
///
/// Until now a step of the pass that threw on every pass was visible nowhere but the detailed
/// log — and because one failing step used to abandon the whole pass, "invisible" meant the
/// live transcript and the conversation grouping had stopped too, with every screen still
/// saying Recording.
@Suite("pipeline diagnostics") @MainActor
struct PipelineDiagnosticsTests {

    private func health(_ build: (PipelineHealthMonitor) -> Void) -> PipelineHealth {
        let monitor = PipelineHealthMonitor(nowMs: { 1_000_000 }, backoffMs: { _ in 40_000 })
        build(monitor)
        return monitor.health
    }

    @Test func aHealthyPassIsOneRowAndNoList() {
        let value = health { monitor in
            monitor.passStarted()
            monitor.succeeded(.drainQueue)
            monitor.passCompleted()
        }
        let display = LiveDiagnosticsSource.pipeline(value, nowMs: 1_002_000)

        #expect(display.summary == "working · last pass 2 sec ago")
        // Thirteen rows saying "fine" is how a screen teaches people to stop reading it.
        #expect(display.failing.isEmpty)
    }

    @Test func aFailingStepIsNamedInPlainLanguageWithItsRetry() {
        let value = health { monitor in
            monitor.passStarted()
            monitor.failed(.drainQueue, TestError.disk)
            monitor.passCompleted()
        }
        let display = LiveDiagnosticsSource.pipeline(value, nowMs: 1_000_000)

        #expect(display.summary == "1 step failing")
        #expect(display.failing.count == 1)
        let stage = display.failing[0]
        // The kit's stage name never reaches the screen.
        #expect(stage.title == "Transcribe recordings")
        #expect(stage.detail == "1 try · next in 40 sec")
        // The raw error IS the row's value here: there is no classified vocabulary for "the
        // grouping threw", and inventing a reassuring sentence for an unknown fault would be
        // worse than showing the fault. Diagnostics-only, like the detailed log.
        #expect(stage.reason?.contains("disk") == true)
    }

    @Test func theRetryCountdownRunsDown() {
        let value = health { monitor in monitor.failed(.enrich, TestError.disk) }
        // 40 s backoff from t=1_000_000.
        #expect(
            LiveDiagnosticsSource.pipeline(value, nowMs: 1_030_000).failing[0].detail
                == "1 try · next in 10 sec")
        // Past it: due now, not a negative countdown.
        #expect(
            LiveDiagnosticsSource.pipeline(value, nowMs: 1_060_000).failing[0].detail
                == "1 try · retrying now")
    }

    @Test func aWedgedLoopOutranksEverythingElseOnTheRow() {
        // A pass that started and never finished: the supervisor is about to restart the loop,
        // and until it does this is the single most important thing this screen can say.
        let value = health { monitor in
            monitor.failed(.recap, TestError.disk)
            monitor.passStarted()
        }
        let display = LiveDiagnosticsSource.pipeline(
            value, nowMs: 1_000_000 + PipelineHealth.passStallMs + 1)

        #expect(display.summary == "not responding · restarting")
        // ...and the failing step is still listed underneath it.
        #expect(display.failing.map(\.id) == ["recap"])
    }

    @Test func aLoopThatHadToBeRestartedSaysSoEvenOnceItIsWellAgain() {
        let value = health { monitor in
            monitor.passStarted()
            monitor.passCompleted()
            monitor.loopRestarted()
        }
        let display = LiveDiagnosticsSource.pipeline(value, nowMs: 1_000_000)

        #expect(display.summary == "working · last pass 0 sec ago · recovered once")
        #expect(display.loopRestarts == 1)
    }

    @Test func beforeTheFirstPassItSaysStartingRatherThanWorking() {
        let display = LiveDiagnosticsSource.pipeline(PipelineHealth(), nowMs: 1_000_000)
        #expect(display.summary == "starting")
    }

    @Test func theSupportReportCarriesTheFailingSteps() {
        let value = health { monitor in monitor.failed(.regroup, TestError.disk) }
        let display = LiveDiagnosticsSource.pipeline(value, nowMs: 1_000_000)
        let block = SupportReportText.pipeline(display)

        #expect(block.contains("Group into conversations"))
        #expect(block.contains("disk"))
        #expect(block.hasSuffix("\n"))
        // Nothing wrong, nothing said.
        #expect(SupportReportText.pipeline(DiagnosticPipeline(summary: "working")).isEmpty)
    }
}

private enum TestError: Error {
    case disk
}
