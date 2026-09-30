import Foundation
import SegmentStore
import Testing
import WireProtocol

// The one gap classifier the day strip (`CoverageComputer`) and every gap-status surface
// (`StatusUI.GapVisibility`) share. Each rule here used to be true on one side only.
@Suite struct GapClassifierTests {
    private func watch(_ reason: GapReason?, sequence: UInt32 = 100, frames: UInt32 = 50) -> GapMeta {
        GapMeta(
            firstMissingSequence: sequence, missingFrameCount: frames,
            firstMissingSampleIndex: UInt64(sequence) * 320, origin: GapMeta.originWatch,
            reasonRaw: reason.map { Int($0.rawValue) })
    }

    private func skip(sequence: UInt32, frames: UInt32, reasonRaw: Int? = nil) -> GapMeta {
        GapMeta(
            firstMissingSequence: sequence, missingFrameCount: frames,
            firstMissingSampleIndex: UInt64(sequence) * 320, origin: GapMeta.originSequenceSkip,
            reasonRaw: reasonRaw)
    }

    @Test("the watch's power-save pause is a pause, never loss and never quiet")
    func powerSaveIsAPause() {
        let gap = watch(.powerSave)
        let classifier = GapClassifier([gap])
        #expect(classifier.classify(gap) == .watchPause)
        #expect(!classifier.isVisibleLoss(gap))
    }

    @Test("suppressed silence is quiet")
    func silenceIsQuiet() {
        let gap = watch(.silenceSuppressed)
        #expect(GapClassifier([gap]).classify(gap) == .quiet)
    }

    @Test(
        "every other watch reason is loss — user-disabled included, until that is decided",
        arguments: [
            GapReason.spoolOverflow, .micConflict, .userDisabled, .lowBattery, .codecError,
            .transportReset,
        ])
    func otherReasonsAreLoss(reason: GapReason) {
        let gap = watch(reason)
        #expect(GapClassifier([gap]).classify(gap) == .loss)
    }

    @Test("an absent or undecodable reason fails closed to loss")
    func unknownReasonsAreLoss() {
        let absent = watch(nil)
        var undecodable = watch(nil)
        undecodable.reasonRaw = 0x7F
        var negative = watch(nil)
        negative.reasonRaw = -1
        var foreignOrigin = watch(.micConflict)
        foreignOrigin.origin = "something_new"
        let classifier = GapClassifier([absent, undecodable, negative, foreignOrigin])
        for gap in [absent, undecodable, negative, foreignOrigin] {
            #expect(classifier.classify(gap) == .loss, "\(gap)")
        }
    }

    @Test("a sequence skip wholly inside one silence record is quiet")
    func skipInsideSilenceIsQuiet() {
        let silence = watch(.silenceSuppressed, sequence: 100, frames: 5_000)
        let exact = skip(sequence: 100, frames: 5_000)
        let inside = skip(sequence: 200, frames: 10)
        let classifier = GapClassifier([silence, exact, inside])
        #expect(classifier.classify(exact) == .quiet)
        #expect(classifier.classify(inside) == .quiet)
    }

    @Test("a sequence skip that no SINGLE silence record covers is loss")
    func uncoveredSkipIsLoss() {
        let first = watch(.silenceSuppressed, sequence: 100, frames: 100)  // 100..<200
        let second = watch(.silenceSuppressed, sequence: 200, frames: 100)  // 200..<300
        let straddling = skip(sequence: 150, frames: 100)  // 150..<250: two records, not one
        let overhanging = skip(sequence: 250, frames: 100)  // runs past the second
        let before = skip(sequence: 10, frames: 5)
        let classifier = GapClassifier([first, second, straddling, overhanging, before])
        #expect(classifier.classify(straddling) == .loss)
        #expect(classifier.classify(overhanging) == .loss)
        #expect(classifier.classify(before) == .loss)
    }

    @Test("a sequence skip is loss whatever reason it carries, and is never cover for another")
    func aSkipsOwnReasonIsIgnored() {
        // The receiver never sets a reason on a skip. A stray one must not turn it into quiet or
        // a pause, nor let it excuse a second skip.
        let silentSkip = skip(sequence: 100, frames: 100, reasonRaw: Int(GapReason.silenceSuppressed.rawValue))
        let pauseSkip = skip(sequence: 300, frames: 10, reasonRaw: Int(GapReason.powerSave.rawValue))
        let inner = skip(sequence: 120, frames: 10)
        let classifier = GapClassifier([silentSkip, pauseSkip, inner])
        #expect(classifier.classify(silentSkip) == .loss)
        #expect(classifier.classify(pauseSkip) == .loss)
        #expect(classifier.classify(inner) == .loss)
    }

    @Test("a power-save record is not silence cover")
    func powerSaveDoesNotExcuseASkip() {
        let pause = watch(.powerSave, sequence: 100, frames: 5_000)
        let inside = skip(sequence: 200, frames: 10)
        #expect(GapClassifier([pause, inside]).classify(inside) == .loss)
    }

    @Test("the indexed cover agrees with a brute-force scan on a large varied input")
    func matchesBruteForce() {
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            // Deterministic xorshift so a failure reproduces.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        let reasons: [GapReason?] = [nil, .silenceSuppressed, .powerSave, .transportReset, .userDisabled]
        let gaps = (0..<2_000).map { _ -> GapMeta in
            let sequence = UInt32(next(5_000))
            let frames = UInt32(1 + next(400))
            if next(3) == 0 { return skip(sequence: sequence, frames: frames) }
            return watch(reasons[next(reasons.count)], sequence: sequence, frames: frames)
        }
        func brute(_ gap: GapMeta) -> GapClass {
            if gap.origin == GapMeta.originSequenceSkip {
                let start = UInt64(gap.firstMissingSequence)
                let end = start + UInt64(gap.missingFrameCount)
                let covered = gaps.contains { c in
                    c.origin != GapMeta.originSequenceSkip && gapReason(of: c) == .silenceSuppressed
                        && UInt64(c.firstMissingSequence) <= start
                        && UInt64(c.firstMissingSequence) + UInt64(c.missingFrameCount) >= end
                }
                return covered ? .quiet : .loss
            }
            switch gapReason(of: gap) {
            case .silenceSuppressed?: return .quiet
            case .powerSave?: return .watchPause
            default: return .loss
            }
        }
        let classifier = GapClassifier(gaps)
        #expect(gaps.map(classifier.classify) == gaps.map(brute))
    }
}
