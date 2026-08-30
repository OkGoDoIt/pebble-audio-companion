import Testing

@Suite struct CompanionRuntimePlaceholder {
    @Test func packageBuilds() { #expect(Bool(true)) }
}
