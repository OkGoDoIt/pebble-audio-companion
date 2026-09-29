import CryptoKit
import Foundation

// Stops audio going to a cloud provider that has said it will not take any more.
//
// WHY THIS EXISTS (2026-09-29)
//
// A Soniox balance ran dry on 09-23. Every answer after that was HTTP 402 — and every answer
// was paid for in full first. The async API accepts the file upload and only refuses at "create
// transcription", so each attempt FLAC-encoded the whole segment and sent all of it before
// hearing no. The retry ladder did that eight times per segment; a revival hook that fired on
// every charger plug and thermal change gave ~350 dead segments a fresh ladder each time; the
// live socket reconnected into the same 402 five times whenever the app was opened. On the day
// it was found one connection had carried 539 MB up over cellular in two and a half hours, all
// of it refused.
//
// A 402 is not a transient failure and not a property of one recording: it is the account
// telling us, about every recording, that it will refuse. So is a rejected key (401) and a key
// without permission (403). The honest response is to stop sending until something changes that
// could make the answer different:
//
//   • the key is replaced or removed (the hold is bound to the key it was recorded against);
//   • the user picks the other provider (holds are per provider);
//   • a probe succeeds — one second of silence, sent on a backoff from 15 minutes to 6 hours,
//     from the foreground at most every 10 minutes, and whenever the user taps Test Connection;
//   • any real cloud attempt succeeds (an upload already in flight when the account was topped
//     up, say).
//
// While a hold is in force the provider reports itself UNAVAILABLE rather than failing fast.
// The difference matters: an unavailable provider makes the queue park the segment (Disabled)
// at no cost and pick it back up the moment the provider is available again, where a provider
// that fails fast would still have every retry re-decode its segment to be told no. First modes
// fall back to their other engine exactly as they do for any unavailable provider, and the
// fallback disclosure says "not accepted" (see `TranscriptionAvailabilityExplaining`).
//
// Persisted, because the process is relaunched by iOS many times a day and each relaunch would
// otherwise have to rediscover the 402 with a full upload.

public final class CloudAccountHold: @unchecked Sendable {
    public struct Hold: Codable, Equatable, Sendable {
        public var provider: CloudProvider
        /// A digest of the key the refusal was for — never the key. A different key means a
        /// different answer is possible, so the hold no longer applies.
        public var keyFingerprint: String
        public var kind: TranscriptionFailureKind
        public var sinceMs: Int64
        /// Probes that have come back refused since the hold began; drives the backoff.
        public var refusedProbes: Int
        public var lastProbeMs: Int64?
        public var nextProbeAtMs: Int64
    }

    /// The refusals that are about the ACCOUNT, not about one recording or one moment.
    /// `rateLimited` is deliberately absent: busy is not broke, and it passes by itself.
    public static let holdingKinds: Set<TranscriptionFailureKind> = [
        .accountOutOfFunds, .keyRejected, .keyNotPermitted,
    ]

    public static let firstProbeDelayMs: Int64 = 15 * 60_000
    public static let maxProbeDelayMs: Int64 = 6 * 60 * 60_000
    /// Opening the app is the moment a person who just topped up is looking, so a probe is due
    /// then if the last one is at least this old — whatever the backoff says.
    public static let foregroundProbeIntervalMs: Int64 = 10 * 60_000
    /// A probe that could not tell (offline, provider trouble) does not escalate the backoff.
    public static let inconclusiveProbeDelayMs: Int64 = 15 * 60_000

    /// 15 min, 30 min, 1 h, 2 h, 4 h, then 6 h.
    public static func probeDelayMs(afterRefusedProbes refused: Int) -> Int64 {
        let shift = min(max(refused, 0), 5)
        return min(firstProbeDelayMs << shift, maxProbeDelayMs)
    }

    private let fileURL: URL?
    private let apiKey: @Sendable (CloudProvider) -> String?
    private let nowMs: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var holds: [CloudProvider: Hold]
    private var lifted: (@Sendable (CloudProvider) -> Void)?

    /// - Parameters:
    ///   - fileURL: where the holds persist; nil keeps them in memory (tests).
    ///   - apiKey: the provider's current key, read when a hold is consulted.
    public init(
        fileURL: URL?,
        apiKey: @escaping @Sendable (CloudProvider) -> String?,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.fileURL = fileURL
        self.apiKey = apiKey
        self.nowMs = nowMs
        self.log = log
        self.holds = Self.load(fileURL)
    }

    /// Called (outside the lock) whenever a hold is lifted by a success — the moment the work it
    /// parked should be picked back up. Not called when a hold lapses because its key changed:
    /// the key write has its own "configuration changed" path.
    public func onLifted(_ handler: @escaping @Sendable (CloudProvider) -> Void) {
        lock.withLock { lifted = handler }
    }

    /// The hold in force for `provider` and its current key, or nil.
    public func active(for provider: CloudProvider) -> Hold? {
        guard let hold = lock.withLock({ holds[provider] }) else { return nil }
        // The keychain is only read when there is a hold to check it against.
        guard let key = Self.nonBlank(apiKey(provider)), Self.fingerprint(key) == hold.keyFingerprint
        else {
            let dropped: Bool = lock.withLock {
                guard holds[provider] == hold else { return false }
                holds[provider] = nil
                persistLocked()
                return true
            }
            if dropped {
                log("cloud: \(provider.rawValue) hold released — the API key it was for has changed")
            }
            return nil
        }
        return hold
    }

    /// A real cloud attempt failed with `message` (a stored-failure-shaped string). Returns true
    /// when this put `provider` on hold.
    @discardableResult
    public func noteFailure(_ message: String, provider: CloudProvider) -> Bool {
        trip(TranscriptionFailureKind.classify(message), provider: provider)
    }

    /// Puts `provider` on hold for `kind`, when `kind` is about the account. Returns true when a
    /// new hold began (an existing hold for the same key keeps its schedule).
    @discardableResult
    public func trip(_ kind: TranscriptionFailureKind, provider: CloudProvider) -> Bool {
        guard Self.holdingKinds.contains(kind), let key = Self.nonBlank(apiKey(provider)) else {
            return false
        }
        let fingerprint = Self.fingerprint(key)
        let now = nowMs()
        let began: Bool = lock.withLock {
            if var existing = holds[provider], existing.keyFingerprint == fingerprint {
                if existing.kind != kind {
                    existing.kind = kind
                    holds[provider] = existing
                    persistLocked()
                }
                return false
            }
            holds[provider] = Hold(
                provider: provider, keyFingerprint: fingerprint, kind: kind, sinceMs: now,
                refusedProbes: 0, lastProbeMs: nil,
                nextProbeAtMs: now + Self.probeDelayMs(afterRefusedProbes: 0)
            )
            persistLocked()
            return true
        }
        if began {
            log(
                "cloud: \(provider.rawValue) refused the account (\(kind.rawValue)); no audio is "
                    + "sent to it until a check succeeds (first in "
                    + "\(Self.firstProbeDelayMs / 60_000) min), the key changes, or Test Connection"
            )
        }
        return began
    }

    /// A real cloud attempt, or a probe, succeeded. Returns true when that lifted a hold.
    @discardableResult
    public func noteSuccess(provider: CloudProvider) -> Bool {
        let (removed, handler): (Hold?, (@Sendable (CloudProvider) -> Void)?) = lock.withLock {
            guard let hold = holds.removeValue(forKey: provider) else { return (nil, nil) }
            persistLocked()
            return (hold, lifted)
        }
        guard let removed else { return false }
        let heldFor = max(0, nowMs() - removed.sinceMs) / 60_000
        log(
            "cloud: \(provider.rawValue) is accepting work again (held \(heldFor) min for "
                + "\(removed.kind.rawValue)); uploads resume"
        )
        handler?(provider)
        return true
    }

    /// Whether a probe of `provider` should run now.
    public func isProbeDue(provider: CloudProvider, foreground: Bool) -> Bool {
        guard let hold = active(for: provider) else { return false }
        let now = nowMs()
        if now >= hold.nextProbeAtMs { return true }
        guard foreground else { return false }
        return now - (hold.lastProbeMs ?? hold.sinceMs) >= Self.foregroundProbeIntervalMs
    }

    /// A probe came back refused for the same account reason: back off further.
    public func recordRefusedProbe(provider: CloudProvider, kind: TranscriptionFailureKind) {
        let now = nowMs()
        lock.withLock {
            guard var hold = holds[provider] else { return }
            hold.refusedProbes += 1
            hold.kind = Self.holdingKinds.contains(kind) ? kind : hold.kind
            hold.lastProbeMs = now
            hold.nextProbeAtMs = now + Self.probeDelayMs(afterRefusedProbes: hold.refusedProbes)
            holds[provider] = hold
            persistLocked()
        }
    }

    /// A probe could not tell (offline, provider trouble): try again soon, without escalating.
    public func recordInconclusiveProbe(provider: CloudProvider) {
        let now = nowMs()
        lock.withLock {
            guard var hold = holds[provider] else { return }
            hold.lastProbeMs = now
            hold.nextProbeAtMs = now + Self.inconclusiveProbeDelayMs
            holds[provider] = hold
            persistLocked()
        }
    }

    /// What a held provider says instead of sending anything, shaped so that
    /// `TranscriptionFailureKind.classify` reads back the hold's own kind.
    public static func pausedMessage(_ hold: Hold) -> String {
        let name = hold.provider.rawValue
        switch hold.kind {
        case .keyRejected:
            return "\(name) did not accept the API key (401); audio is not sent until it changes"
        case .keyNotPermitted:
            return "\(name) key is not permitted for this API (403); audio is not sent until it changes"
        default:
            return "\(name) is out of credit (402); audio is not sent until the account is topped up"
        }
    }

    // MARK: - Internals

    static func fingerprint(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func nonBlank(_ key: String?) -> String? {
        guard let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func load(_ url: URL?) -> [CloudProvider: Hold] {
        guard let url, let data = try? Data(contentsOf: url),
            let list = try? JSONDecoder().decode([Hold].self, from: data)
        else { return [:] }
        return Dictionary(list.map { ($0.provider, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    private func persistLocked() {
        guard let fileURL else { return }
        if holds.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let list = holds.values.sorted { $0.provider.rawValue < $1.provider.rawValue }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension TranscriptionFailureKind: Codable {}

/// What one probe of a held account found.
public enum CloudAccountProbeOutcome: Equatable, Sendable {
    /// The provider took the audio (or found no speech in it): the account works.
    case accepted
    /// Refused for an account reason again.
    case refused(TranscriptionFailureKind)
    /// Could not tell — offline, provider trouble, no key. The message is for the log.
    case inconclusive(String)
}
