import SwiftUI
import Testing
import UIKit

// `ChapterCardLayout` fits a card's summary with ONE measure: it proposes the summary the height
// left under the card's soft maximum and relies on `Text` answering with the whole lines that
// fit (plan 7.12). If SwiftUI ever answered with its full height instead — or a fraction of a
// line — the card would overflow its band or clip a line in half. These pin the behaviour the
// layout depends on, measured through a real hosting controller.

@Suite("Text under a proposed height")
@MainActor
struct TextHeightProposalTests {

    /// Records what its one child answers for a fixed proposal.
    private struct Probe: Layout {
        var proposal: ProposedViewSize
        var record: Recorder

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let size = child.sizeThatFits(self.proposal)
            record.sizes.append(size)
            return size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: self.proposal)
        }
    }

    final class Recorder {
        var sizes: [CGSize] = []
    }

    private let long = String(
        repeating: "A visit in the rain: the second venue is bigger but farther away. ",
        count: 6)

    private func measure(height: CGFloat?, lineSpacing: CGFloat = 0) -> CGFloat {
        let recorder = Recorder()
        let view = Probe(proposal: ProposedViewSize(width: 280, height: height), record: recorder) {
            Text(long).font(.system(size: 14)).lineSpacing(lineSpacing)
        }
        let host = UIHostingController(rootView: view)
        _ = host.sizeThatFits(in: CGSize(width: 400, height: 2_000))
        return recorder.sizes.last?.height ?? -1
    }

    private func lineHeight() -> CGFloat {
        let recorder = Recorder()
        let view = Probe(proposal: ProposedViewSize(width: 280, height: nil), record: recorder) {
            Text("One line").font(.system(size: 14))
        }
        _ = UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 400, height: 2_000))
        return recorder.sizes.last?.height ?? -1
    }

    @Test func textTruncatesToTheWholeLinesThatFit() {
        let line = lineHeight()
        let full = measure(height: nil)
        #expect(line > 10 && line < 25)
        #expect(full > line * 8, "the probe text should run to many lines (\(full))")

        // Three and a half lines of room: three whole lines, never a partial one.
        let three = measure(height: line * 3.5)
        #expect(abs(three - line * 3) < 1, "three lines: \(three) vs line \(line)")
        #expect(three <= line * 3.5)
    }

    @Test func lessThanOneLineOfRoomStillGetsOneLine() {
        let line = lineHeight()
        let squeezed = measure(height: 4)
        // The layout also floors its proposal at one line; this documents what Text does alone.
        #expect(abs(squeezed - line) < 1, "\(squeezed) vs \(line)")
    }

    /// The card's pre-layout estimate (`ChapterCardMetrics`) uses the same line height SwiftUI
    /// lays a line out at, so the follow-up collapse agrees with the drawn card.
    @Test func theCardMetricsLineHeightIsSwiftUIs() {
        let line = lineHeight()
        #expect(abs(line - ChapterCardMetrics.standard.summaryLine) < 1, "\(line) vs \(ChapterCardMetrics.standard.summaryLine)")
    }

    @Test func lineSpacingIsCountedBetweenLinesOnly() {
        let line = lineHeight()
        let two = measure(height: line * 2 + 3 * 1.5, lineSpacing: 3)
        #expect(abs(two - (line * 2 + 3)) < 1, "\(two) vs \(line)")
    }
}
