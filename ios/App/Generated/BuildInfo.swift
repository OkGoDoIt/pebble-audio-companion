// GENERATED FILE — do not hand-edit.
//
// Overwritten on every build by the "Generate Build Info" script phase (project.yml, App
// target), which runs before Compile Sources and stamps the actual wall-clock time and git
// revision of the build that produced the running binary. This checked-in version is the
// fallback XcodeGen finds on a fresh checkout (a file must exist on disk at `xcodegen generate`
// time to be enumerated as a compiled source at all — see the script phase's comment for why it
// cannot simply create this file itself) and what a test target sees if it compiles this file
// without ever running the App target's own build phase.
//
// Expect this file to show as locally modified after any build through Xcode or `xcodebuild`;
// that is the mechanism working, not a mistake — never commit a build's stamped values over this
// placeholder.
enum BuildInfo {
    /// UTC, ISO 8601. "unknown" means this is the checked-in placeholder, never rebuilt.
    static let builtAtISO8601 = "unknown"
    /// Short git hash, plus `-dirty` when the working tree had uncommitted changes at build
    /// time. "unknown" when the build ran outside a git checkout, or `git` itself was
    /// unavailable to the build script.
    static let gitRevision = "unknown"
}
