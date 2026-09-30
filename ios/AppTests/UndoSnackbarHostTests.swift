import Foundation
import Testing

// The undo snackbar is hosted once, by `RootView`, over whichever tab is showing. It used to be
// hosted by the Library screen alone, so a conversation deleted from Today popped back to a screen
// with no Undo on it; and Today and Follow-ups kept snackbars of their own, which a second host
// in the same tab would have drawn on top of.

@Suite("undo snackbar host")
struct UndoSnackbarHostTests {
    /// Every screen posts to `UndoCenter.shared`; none presents a snackbar of its own. Read from
    /// source because the failure is structural — a second `.snackbar(item:)` on a screen draws
    /// two at once — and a view cannot be rendered in this bundle to see it.
    @Test func noScreenHostsASnackbarOfItsOwn() throws {
        let screens = SwiftSource.iosRoot.appending(path: "App/Screens")
        let files = try #require(
            FileManager.default.enumerator(at: screens, includingPropertiesForKeys: nil))
        var hosts: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".snackbar(item:") || text.contains("SnackbarSlot(") {
                hosts.append(url.lastPathComponent)
            }
        }
        #expect(scanned > 20, "scanned \(scanned) screen files")
        #expect(hosts.isEmpty, "screens hosting their own snackbar: \(hosts)")

        let root = try SwiftSource.read("App/RootView.swift")
        #expect(root.components(separatedBy: ".undoSnackbarHost(isShowing:").count - 1 == 5)
    }

    /// Posting the same message twice is two snackbars with two clocks: the second must not be
    /// dismissed by the first one's timer.
    @Test @MainActor func twoPostsOfOneMessageAreDistinct() async throws {
        let first = SnackbarItem(message: "Conversation deleted", actionTitle: "Undo")
        try await Task.sleep(for: .milliseconds(2))
        let second = SnackbarItem(message: "Conversation deleted", actionTitle: "Undo")
        #expect(first != second)
        #expect(first == first)
        #expect(SnackbarItem.lifetime == .seconds(5))
    }
}
