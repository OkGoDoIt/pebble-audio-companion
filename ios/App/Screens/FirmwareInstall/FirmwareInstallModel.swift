import Firmware
import Foundation
import Observation

// One install of the audio firmware on a watch that does not have it: find the published build,
// download and verify it, hand it to the Pebble app, then wait for the watch.
//
// Shared by onboarding's firmware step and the install sheet that Today and Settings → Watch
// open. The model knows nothing about how either of them decides the watch came back — the
// host watches its own signal (a pairing attempt in onboarding, the receiver's state in the
// sheet) and ends the flow. Design of record: docs/mockups/firmware-onboarding, direction A.

@MainActor
@Observable
final class FirmwareInstallModel {
    /// What the screen is showing.
    enum Stage: Equatable {
        /// Nothing sent yet: the reasons and the button.
        case offer
        /// The iOS menu is up and nothing has been sent before.
        case choosing
        /// The file went to an app; waiting for the watch to come back with the audio service.
        case waiting
    }

    let firmware: FirmwareUpdateModel

    /// The file reached an app at least once. From here on the screen is the waiting one, and
    /// a second send (the Pebble app ignored the first) keeps it.
    private(set) var hasSent = false
    /// The app the file went to was not Pebble — worth one line, not an error.
    private(set) var sentElsewhere = false
    /// The manual path's file is in Files. Said under the button, so the save is not silent.
    private(set) var savedToFiles = false

    var showMenu = false
    var showFilesExport = false
    var showNoOpener = false

    /// What to do once the download in flight is verified.
    @ObservationIgnored private var afterDownload: AfterDownload?
    private enum AfterDownload { case menu, files }

    init(firmware: FirmwareUpdateModel = SettingsFirmwareScreen.makeModel()) {
        self.firmware = firmware
        #if DEBUG
        // Simulator staging for the waiting screen, which otherwise needs a real hand-off.
        if ProcessInfo.processInfo.arguments.contains("-firmwareInstall.sent") { hasSent = true }
        #endif
    }

    var stage: Stage {
        if hasSent { return .waiting }
        return showMenu ? .choosing : .offer
    }

    /// The build this flow installs: the newest published one, whatever the watch was thought
    /// to run. A watch without the audio service needs it even when this app remembers handing
    /// the same build over before — an official update has replaced it since.
    var release: FirmwareRelease? { firmware.availability?.release }

    var isChecking: Bool {
        if case .checking = firmware.check { return true }
        return firmware.availability == nil && firmware.isConfigured && !checkFailed
    }

    var checkFailure: FirmwareFailure? {
        if case .failed(let failure) = firmware.check { return failure }
        return nil
    }

    private var checkFailed: Bool { checkFailure != nil }

    /// Reads the feed once per visit; the cached copy answers offline.
    func prepare() async {
        guard firmware.availability == nil else { return }
        await firmware.refresh()
    }

    func checkAgain() async { await firmware.refresh() }

    /// Install Firmware / Send to Pebble Again: the menu, once the file is verified.
    func install() { obtainFile(then: .menu) }

    /// The manual path's first step.
    func saveToFiles() { obtainFile(then: .files) }

    private func obtainFile(then next: AfterDownload) {
        guard release != nil, !firmware.download.isBusy else { return }
        if case .failed = firmware.download { firmware.discardDownload() }
        if firmware.download.verifiedFile != nil {
            present(next)
            return
        }
        afterDownload = next
        firmware.startDownload()
        // A copy verified on an earlier visit is ready at once.
        downloadChanged()
    }

    /// The host calls this on every change of `firmware.download`.
    func downloadChanged() {
        guard let next = afterDownload else { return }
        if firmware.download.verifiedFile != nil {
            afterDownload = nil
            present(next)
        } else if !firmware.download.isBusy {
            // Failed or cancelled: the screen shows why, and the next tap starts over.
            afterDownload = nil
        }
    }

    private func present(_ next: AfterDownload) {
        switch next {
        case .menu: showMenu = true
        case .files: showFilesExport = true
        }
    }

    func handle(_ outcome: PebbleAppHandoffOutcome) {
        _ = firmware.recordHandoff(outcome)
        switch outcome {
        case .openedIn(let bundleIdentifier):
            hasSent = true
            sentElsewhere = !PebbleAppHandoff.isPebbleApp(bundleIdentifier)
        case .noOpener:
            showNoOpener = true
        case .savedToFiles:
            // The manual path: the person installs it themselves, so there is nothing to
            // wait for here — only the save to confirm.
            savedToFiles = true
        case .dismissed:
            break
        }
    }
}

extension FirmwareRelease {
    /// The GitHub page of this release (`…/releases/tag/<tag>`), derived from its asset URL
    /// (`…/releases/download/<tag>/<file>`). Nil for an asset hosted any other way.
    var releasePageURL: URL? {
        let parts = assetURL.pathComponents
        guard let index = parts.firstIndex(of: "download"), index > 1,
            parts[index - 1] == "releases", index + 1 < parts.count,
            var components = URLComponents(url: assetURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = "/" + (parts[1..<index] + ["tag", parts[index + 1]]).joined(separator: "/")
        components.query = nil
        return components.url
    }
}
