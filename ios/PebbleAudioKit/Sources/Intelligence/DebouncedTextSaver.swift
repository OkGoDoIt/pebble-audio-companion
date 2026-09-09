import Foundation

/// Saving for a text field that has no Save button (AY).
///
/// About You used to be a modal editor with Cancel and Save. Notes does not work that way and
/// neither should this: you tap the text, a caret appears, you type, and it is saved. But
/// "saved as you type" has exactly one failure mode that matters, and it is silent — the person
/// who types a last sentence and immediately swipes the app away, or locks the phone, or walks
/// back to Settings. A debounce alone loses that sentence, every time, with nothing on screen
/// to suggest anything was lost.
///
/// So the contract here is deliberately two-sided:
///
/// - `edited` coalesces keystrokes into one write after `delay`, because writing 1,200 words to
///   disk on every character is the other way to make this screen bad.
/// - `flush` writes immediately, and the caller is expected to call it on EVERY way the text
///   can stop being edited: losing focus, the screen disappearing, and the app backgrounding.
///
/// Both paths converge on one rule: the last text the user typed is what ends up on disk, and
/// it is written exactly once. Re-writing identical text is not harmless here — every write
/// invalidates the derived-terms cache downstream — so a value equal to the last one written is
/// dropped rather than saved again, including the case where someone types a word and deletes
/// it before the debounce fires.
///
/// `sleep` is injected so the timing is testable without a real clock. Nothing else in this
/// type touches time.
@MainActor
public final class DebouncedTextSaver {
    public typealias Sleep = (Duration) async throws -> Void

    /// Long enough to coalesce a sentence, short enough that a crash or a kill loses at most a
    /// few words. Notes-like editors sit in this range.
    /// `nonisolated` so it can be a default argument: a main-actor-isolated static cannot be
    /// read from the nonisolated context a default expression is evaluated in.
    public nonisolated static let defaultDelay = Duration.milliseconds(700)

    public let delay: Duration
    private let sleep: Sleep
    private let write: (String) -> Void

    /// The last value handed to `write`, or the value adopted from storage. Nil means nothing
    /// is known yet, in which case the first edit is always worth writing.
    private var lastWritten: String?
    private var pending: String?
    /// Identifies the scheduled write, so a timer that wakes after being superseded (or after a
    /// flush) knows it is stale. Cancellation alone is not enough: a `sleep` that returns
    /// without observing cancellation would otherwise commit twice.
    private var generation = 0
    private var timer: Task<Void, Never>?

    public init(
        delay: Duration = DebouncedTextSaver.defaultDelay,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        write: @escaping (String) -> Void
    ) {
        self.delay = delay
        self.sleep = sleep
        self.write = write
    }

    /// There is an edit that has not reached `write` yet.
    public var hasPendingEdit: Bool { pending != nil }

    /// Takes the stored value as the baseline without writing it back. Called when the screen
    /// loads the text it is about to show.
    public func adopt(_ text: String) {
        supersede()
        pending = nil
        lastWritten = text
    }

    /// One keystroke's worth of change.
    public func edited(_ text: String) {
        guard text != lastWritten else {
            // Typed and un-typed: there is nothing left to save, and the scheduled write would
            // otherwise re-save a value already on disk.
            supersede()
            pending = nil
            return
        }
        pending = text
        supersede()
        let generation = self.generation
        timer = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(self.delay)
            guard !Task.isCancelled else { return }
            self.commit(generation: generation)
        }
    }

    /// Writes immediately if anything is pending. Safe to call as often as the caller likes —
    /// with nothing pending it does nothing at all.
    public func flush() {
        supersede()
        commit(generation: generation)
    }

    private func commit(generation: Int) {
        guard generation == self.generation, let text = pending else { return }
        pending = nil
        guard text != lastWritten else { return }
        lastWritten = text
        write(text)
    }

    /// Invalidates whatever is scheduled. Bumping the generation is what makes a wake-up from
    /// an already-running timer a no-op.
    private func supersede() {
        generation &+= 1
        timer?.cancel()
        timer = nil
    }
}
