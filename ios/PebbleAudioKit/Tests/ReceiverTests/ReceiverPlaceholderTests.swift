import Testing

@Suite struct ReceiverPlaceholder {
    @Test func packageBuilds() { #expect(Bool(true)) }
}
