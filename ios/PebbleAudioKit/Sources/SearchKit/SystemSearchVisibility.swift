import Foundation

/// How much of a recording the OS search index (Core Spotlight, and through it Siri's semantic
/// index on iOS 27) is allowed to see. The app's own FTS index is never gated by this — search
/// inside the app always has the full text; this is about what leaves the app's sandbox for
/// the system's index.
///
/// `full` is the historical behaviour (plan 4.7 "ported, not regressed"), so an existing
/// install keeps exactly what it had. The two smaller settings exist because a transcript of
/// every conversation someone had is a different thing to hand the system than a note title.
public enum SystemSearchVisibility: String, CaseIterable, Sendable, Codable {
    /// Nothing is donated; anything previously donated is removed on the next pass.
    case off
    /// Titles, summaries, tags and dates — never transcript text or note bodies.
    case summaries
    /// Everything, including transcript text, so Spotlight and Siri can match what was said.
    case full

    public static let `default`: SystemSearchVisibility = .full

    /// Whether any donation at all should happen.
    public var donates: Bool { self != .off }
    /// Whether transcript / body text may be part of a donation.
    public var includesText: Bool { self == .full }
}
