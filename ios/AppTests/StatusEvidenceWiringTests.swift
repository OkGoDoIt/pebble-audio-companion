import Foundation
import Testing

// The status engine can only be as honest as the arguments it is handed.
//
// `statusModel(...)` weighs the `.streaming` latch against `streamVerdict`, and names the watch
// from `deviceName`. Both parameters have defaults — `.unchecked` and `nil` — so that previews,
// artboard fixtures and unit cases about some other axis need not pretend to a liveness signal
// they do not have. Those same defaults are exactly how the defect comes back: a production call
// site that omits `streamVerdict` silently returns to asserting "Recording" from a latch nobody
// has rechecked, and one that omits `deviceName` returns to printing the constant "Pebble ·
// connected" for every install.
//
// There are only two production call sites — the Today card and the widget snapshot — and they
// must never disagree, because the card and every native surface are meant to be one derivation.
// This is read as SOURCE for the same reason `LiveMockConformanceTests` is: both call sites live
// on `AppComposition`, which opens the App Group database, the segment spool and Core Bluetooth,
// none of which exists in a test bundle. The defect shape is "an argument that is not passed",
// and that is legible in the source.

@Suite("status evidence wiring")
struct StatusEvidenceWiringTests {

    /// Every file that is allowed to derive a status card, and what it derives it for.
    static let callSites = [
        ("App/Runtime/LiveTodayDataSource.swift", "the Today status card"),
        ("App/Runtime/AppComposition.swift", "the widget and Control Center snapshot"),
    ]

    /// The `statusModel(` calls in `source`, each as the text between its parentheses.
    private func statusModelCalls(in source: String) -> [String] {
        let sanitized = SwiftSource.sanitize(source)
        var calls: [String] = []
        var searchStart = sanitized.startIndex
        while let range = sanitized.range(
            of: "statusModel(", range: searchStart..<sanitized.endIndex)
        {
            var depth = 1
            var index = range.upperBound
            var body = ""
            while index < sanitized.endIndex, depth > 0 {
                let character = sanitized[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(character)
                index = sanitized.index(after: index)
            }
            calls.append(body)
            searchStart = index < sanitized.endIndex ? sanitized.index(after: index) : sanitized.endIndex
        }
        return calls
    }

    @Test func everyProductionStatusCallWeighsTheStreamingLatch() throws {
        for (path, surface) in Self.callSites {
            let calls = statusModelCalls(in: try SwiftSource.read(path))
            #expect(!calls.isEmpty, "\(path) should still derive a status for \(surface)")
            for call in calls {
                #expect(
                    call.contains("streamVerdict:"),
                    """
                    \(path) derives \(surface) without `streamVerdict:`, so it falls back to \
                    `.unchecked` and takes the `.streaming` latch at face value — which is the \
                    defect where the card says "Recording" with no live conversation anywhere.
                    """
                )
                #expect(
                    call.contains("deviceName:"),
                    """
                    \(path) derives \(surface) without `deviceName:`, so the sub-line falls back \
                    to naming no device — the watch's advertised name is published and should be \
                    used rather than dropped.
                    """
                )
            }
        }
    }

    /// The verdict has to be computed against the CURRENT time. A verdict weighed against a
    /// stored timestamp would answer a question about a moment that has passed, which is the
    /// whole class of bug this exists to close.
    @Test func theVerdictIsWeighedAgainstNow() throws {
        for (path, surface) in Self.callSites {
            for call in statusModelCalls(in: try SwiftSource.read(path)) {
                guard let verdictRange = call.range(of: "streamVerdict:") else { continue }
                let argument = call[verdictRange.upperBound...]
                #expect(
                    argument.contains("streamEvidence"),
                    "\(surface) must weigh the receiver's published evidence, not a local guess")
                #expect(
                    argument.contains("nowMs: clock.nowMs")
                        || argument.contains("nowMs: composition.clock.nowMs"),
                    "\(surface) must weigh the evidence against the clock, not a stored instant")
            }
        }
    }
}
