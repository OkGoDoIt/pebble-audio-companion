import Foundation
import Testing

@testable import Intelligence

// The About You editor has no Save button, so every one of these cases is a way a sentence
// could be lost with nothing on screen to say so. That is the whole reason this logic lives in
// the kit rather than inside the view.

/// A `sleep` that never returns until the test says so, so debounce timing is exact rather
/// than raced. `wake()` releases everything currently waiting.
@MainActor
private final class ManualSleeper {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var isWaiting: Bool { !waiting.isEmpty }

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { waiting.append($0) }
    }

    func wake() {
        let resuming = waiting
        waiting = []
        for continuation in resuming { continuation.resume() }
    }

    /// Lets the debounce task actually reach its `sleep` before the test drives it. The saver
    /// schedules on the main actor, so a handful of yields is always enough; the bound turns a
    /// regression into a failure instead of a hang.
    func settle() async {
        for _ in 0..<100 where !isWaiting {
            await Task.yield()
        }
    }
}

@MainActor
private final class Recorder {
    private(set) var writes: [String] = []
    func write(_ text: String) { writes.append(text) }
}

@Suite("AY · debounced saving")
@MainActor
struct AYDebouncedTextSaverTests {

    private func makeSaver(
        _ sleeper: ManualSleeper, _ recorder: Recorder
    ) -> DebouncedTextSaver {
        DebouncedTextSaver(
            delay: .milliseconds(700),
            sleep: { try await sleeper.sleep($0) },
            write: { recorder.write($0) }
        )
    }

    @Test func keystrokesCoalesceIntoOneWrite() async {
        let sleeper = ManualSleeper()
        let recorder = Recorder()
        let saver = makeSaver(sleeper, recorder)
        saver.adopt("")

        saver.edited("H")
        saver.edited("He")
        saver.edited("Hel")
        saver.edited("Hello")
        await sleeper.settle()
        sleeper.wake()
        await Task.yield()

        #expect(recorder.writes == ["Hello"])
    }

    /// The reason this type exists: type a sentence, swipe the app away. `flush` is what the
    /// screen calls on disappear / background, and it must not wait for the debounce.
    @Test func flushWritesImmediately() async {
        let sleeper = ManualSleeper()
        let recorder = Recorder()
        let saver = makeSaver(sleeper, recorder)
        saver.adopt("")

        saver.edited("one last sentence")
        #expect(recorder.writes.isEmpty, "nothing should be written before the debounce")
        saver.flush()

        #expect(recorder.writes == ["one last sentence"])
    }

    /// The double-write shape: a flush, and then the timer it superseded waking up anyway.
    @Test func flushedTextIsNotWrittenAgainWhenTheTimerFires() async {
        let sleeper = ManualSleeper()
        let recorder = Recorder()
        let saver = makeSaver(sleeper, recorder)
        saver.adopt("")

        saver.edited("done")
        await sleeper.settle()
        saver.flush()
        sleeper.wake()
        await Task.yield()

        #expect(recorder.writes == ["done"])
    }

    @Test func flushWithNothingPendingWritesNothing() async {
        let sleeper = ManualSleeper()
        let recorder = Recorder()
        let saver = makeSaver(sleeper, recorder)
        saver.adopt("stored text")

        saver.flush()
        saver.flush()

        #expect(recorder.writes.isEmpty)
    }

    /// Opening the screen must not write the text back: every write invalidates the derived
    /// term cache downstream, and merely looking at the bio is not an edit.
    @Test func adoptingStoredTextIsNotAnEdit() async {
        let sleeper = ManualSleeper()
        let recorder = Recorder()
        let saver = makeSaver(sleeper, recorder)

        saver.adopt("stored text")
        saver.edited("stored text")
        saver.flush()

        #expect(recorder.writes.isEmpty)
        #expect(!saver.hasPendingEdit)
    }

    @Test func typingAndUndoingLeavesNothingToSave() async {
        let sleeper = ManualSleeper()
        let recorder = Recorder()
        let saver = makeSaver(sleeper, recorder)
        saver.adopt("bio")

        saver.edited("bio!")
        #expect(saver.hasPendingEdit)
        saver.edited("bio")
        #expect(!saver.hasPendingEdit)

        await sleeper.settle()
        sleeper.wake()
        await Task.yield()
        saver.flush()

        #expect(recorder.writes.isEmpty)
    }

    /// Editing after a debounce has already committed starts a fresh cycle — the saver is used
    /// for the whole life of the screen, not once.
    @Test func editingAgainAfterAWriteSavesTheNewText() async {
        let sleeper = ManualSleeper()
        let recorder = Recorder()
        let saver = makeSaver(sleeper, recorder)
        saver.adopt("")

        saver.edited("first")
        await sleeper.settle()
        sleeper.wake()
        await Task.yield()

        saver.edited("first and second")
        await sleeper.settle()
        sleeper.wake()
        await Task.yield()

        #expect(recorder.writes == ["first", "first and second"])
    }

    /// A long document is the case the user actually has (1,000+ words): the text is passed
    /// through whole, and only the final value reaches disk.
    @Test func longDocumentIsWrittenWhole() async {
        let sleeper = ManualSleeper()
        let recorder = Recorder()
        let saver = makeSaver(sleeper, recorder)
        saver.adopt("")

        let paragraph = String(repeating: "word ", count: 1200)
        saver.edited(String(paragraph.dropLast(200)))
        saver.edited(paragraph)
        saver.flush()

        #expect(recorder.writes.count == 1)
        #expect(recorder.writes.first == paragraph)
    }
}
