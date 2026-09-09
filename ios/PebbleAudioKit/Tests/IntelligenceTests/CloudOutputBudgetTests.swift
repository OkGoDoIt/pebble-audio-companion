import Testing

@testable import Intelligence

// The ceiling that turns a runaway prompt into a shorter note instead of a note that never
// arrives. These pin the two things that actually caused the failure: that a ceiling is sent at
// all, and that the one measured number keeps real headroom over what the model was observed to
// write. A ceiling that bites a working template is worse than no ceiling.

@Suite("cloud output budget")
struct CloudOutputBudgetTests {

    /// Measured against the real model on a real 1 h 23 m recording.
    private let observedExtendedSummaryTokens = 873

    @Test("extended summary is capped, with headroom over what it was measured to write")
    func extendedSummaryHasHeadroom() {
        let ceiling = CloudOutputBudget.maxOutputTokens(forTemplateId: "extended-summary")
        #expect(ceiling > observedExtendedSummaryTokens)
        // At least 20% clear of the observation, so ordinary variation cannot truncate a note.
        #expect(Double(ceiling) >= Double(observedExtendedSummaryTokens) * 1.2)
    }

    @Test("the cap is well under the 7,089 tokens the old prompt actually produced")
    func extendedSummaryCapsTheRunaway() {
        #expect(CloudOutputBudget.maxOutputTokens(forTemplateId: "extended-summary") < 7_089)
    }

    @Test("an unmeasured template gets the generous backstop, not the measured number")
    func othersGetTheBackstop() {
        for id in ["ask", "meeting-notes", "daily-summary", "follow-up-extraction", "anything"] {
            #expect(CloudOutputBudget.maxOutputTokens(forTemplateId: id) == CloudOutputBudget.backstop)
        }
    }

    /// The on-device numbers are squeezed to fit Apple's 4,096-token window. Reusing them as
    /// cloud ceilings would truncate notes that work today, so the two tables stay apart.
    @Test("the backstop is far above every on-device budget")
    func backstopClearsTheOnDeviceTable() {
        // Spelled as an unbound reference: `OnDeviceTemplateBudget` also has an INSTANCE
        // property called `outputTokens`, which shadows the static in a bare member lookup.
        let onDevice: (String) -> Int = OnDeviceTemplateBudget.outputTokens(forTemplateId:)
        for id in ["extended-summary", "ask", "meeting-notes", "segment-annotation"] {
            #expect(CloudOutputBudget.backstop > onDevice(id))
        }
    }
}
