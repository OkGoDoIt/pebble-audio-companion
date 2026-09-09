import Foundation
import StatusUI
import Testing

// The Diagnostics build stamp. Its whole purpose is to answer "am I running the build I just
// installed?", so the failure that matters is it saying something confident and wrong.
@Suite struct BuildFormattingTests {
    /// 2026-09-09T19:24:00Z.
    private let builtISO = "2026-09-09T19:24:00Z"
    private var builtMs: Int64 { 1_788_981_840_000 }

    @Test func itShowsAbsoluteTimeRevisionAndHowLongAgo() {
        let value = BuildFormatting.describe(
            builtAtISO8601: builtISO, revision: "84ca738", nowMs: builtMs + 12 * 60 * 1000)

        #expect(value.contains("84ca738"))
        #expect(value.contains("12 min ago"))
        // The absolute half is locale-formatted, so assert the parts that cannot move rather
        // than a full string: this test must not fail on a machine set to another region.
        #expect(value.contains("2026"))
    }

    /// The committed placeholder at `App/Generated/BuildInfo.swift`, which is what a checkout
    /// that has never been built through Xcode compiles. Saying "Jan 1, 1970" there would be a
    /// confident lie; saying nothing at all would leave the row looking broken.
    @Test func anUnstampedBuildSaysSoRatherThanInventingADate() {
        let value = BuildFormatting.describe(
            builtAtISO8601: "unknown", revision: "unknown", nowMs: builtMs)

        #expect(value == Copy.Settings.Diagnostics.buildUnknown)
    }

    /// Before the source's first refresh there is no clock reading, and a `nowMs` of 0 would
    /// otherwise render "57 yr ago" against a 2026 build date.
    @Test func withNoClockYetItShowsTheBuildWithoutClaimingAnAge() {
        let value = BuildFormatting.describe(
            builtAtISO8601: builtISO, revision: "84ca738", nowMs: 0)

        #expect(value.contains("84ca738"))
        #expect(!value.contains("ago"))
    }

    /// A build made outside a git checkout still has a real date worth showing; the revision is
    /// the only unknown, and an "unknown ·" segment in the middle reads as a bug.
    @Test func aBuildWithNoRevisionStillShowsItsDate() {
        let value = BuildFormatting.describe(
            builtAtISO8601: builtISO, revision: "unknown", nowMs: builtMs + 60 * 60 * 1000)

        #expect(!value.contains("unknown"))
        #expect(value.contains("1 hr ago"))
    }

    /// Clock skew (a device whose time moved backwards between build and read) must not render
    /// a negative duration.
    @Test func aClockThatWentBackwardsDropsTheRelativeHalf() {
        let value = BuildFormatting.describe(
            builtAtISO8601: builtISO, revision: "84ca738", nowMs: builtMs - 5_000)

        #expect(!value.contains("ago"))
    }
}
