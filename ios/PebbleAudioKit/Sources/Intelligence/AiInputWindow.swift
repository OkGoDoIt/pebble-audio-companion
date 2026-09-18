import Foundation

// What a provider can be handed in one call, asked BEFORE any request exists.
//
// `AskBudget.forMode` plans a whole-archive read against the provider that will answer first,
// and it used to plan the on-device case against a constant (`OnDeviceAiProvider
// .defaultMaxInputChars`, 8,000 characters, measured against a 4,096-token window). On iOS 27
// the window is 8,192 and the constant quietly halves what Ask may read; with Private Cloud
// Compute in the remote slot the OpenAI model catalog says nothing useful about the window at
// all. So the providers say, and the router relays — the same seam `AiProvider` is, one level
// out, and optional: a provider that does not conform reports nothing and the caller keeps
// planning the way it does today.

/// A provider that can say how much transcript one prose call may carry.
public protocol AiInputWindowReporting: Sendable {
    /// Characters of transcript one call may be handed, for a provider whose ceiling is a
    /// character budget (the on-device model — `OnDeviceAiProvider.onDeviceInputChars()`).
    /// Nil for a provider whose ceiling is not a character count.
    func inputChars() async -> Int?

    /// The context window in tokens, for a provider that reports one (Apple Private Cloud
    /// Compute). Nil for a provider whose window the model catalog already knows (OpenAI).
    func contextTokens() async -> Int?
}
