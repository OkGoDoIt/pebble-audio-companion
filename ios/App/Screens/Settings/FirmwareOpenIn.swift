import Firmware
import SwiftUI
import UIKit

// The hand-off itself: getting a verified `.pbz` out of this app and into the Pebble app.
//
// **There is no way to push it directly, and this is not a limitation we can engineer around.**
// `UIApplication.open(_:options:completionHandler:)` dispatches on the URL *scheme* and takes no
// target app; Apple's own parameter documentation lists `http`, `https`, `tel`, `facetime`,
// `mailto` and custom app schemes, and `file` is not among them. Even if it launched something,
// the receiving app holds no sandbox extension for a path inside our container. Apple DTS states
// plainly that opening a URL is the only way one app can launch another. The document-open and
// share paths exist precisely because they perform the copy the sandbox otherwise forbids.
//
// So the person chooses the destination, and the only design question left is *which chooser*.
//
// **`UIDocumentInteractionController.presentOpenInMenu` over the share sheet.** Apple documents
// it as presenting "a menu restricted to a list of apps capable of opening the current document"
// — resolved from the file's UTI against installed apps' `CFBundleDocumentTypes`. That is
// exactly the set we want: the Pebble app declares `coredevices.coreapp.PebbleFirmware` with
// `LSHandlerRank = Owner` for the `pbz` extension, so it is in that menu and almost nothing else
// is. It also returns `false` when nothing installed can open the document, which is the only
// honest "is the Pebble app here?" signal iOS offers for a document type — `canOpenURL` answers
// about URL *schemes*, needs an `LSApplicationQueriesSchemes` entry to answer at all, and is
// deprecated in iOS 27, so this app does not use it and declares no query schemes.
//
// A general share sheet would work on a good day, but Apple has been deliberately narrowing
// file→app hand-off since iOS 16 (a share extension can suppress an app's Open In row; iOS 17
// stopped AirDrop handing files straight to declared handlers, which DTS confirmed is
// intentional). The Open In menu is the documented path, so it is the primary one, with
// Save to Files as the fallback that has survived every one of those changes.
//
// <https://developer.apple.com/documentation/uikit/uidocumentinteractioncontroller/presentopeninmenu(from:in:animated:)>

/// What the person did with the file.
enum FirmwareHandoffOutcome: Equatable {
    /// An app was chosen. The bundle id is what iOS reported through
    /// `willBeginSendingToApplication` — the one thing it does tell us.
    case openedIn(bundleIdentifier: String?)
    /// Saved through the Files exporter.
    case savedToFiles
    /// The menu closed with nothing chosen.
    case dismissed
    /// Nothing installed can open a `.pbz`. No menu was shown.
    case noOpener
}

extension FirmwareUpdateModel {
    /// Records what the person did with the file and returns the one line that reports it, so
    /// the record and the sentence can never disagree. Nil when there is nothing to record: a
    /// dismissal (they changed their mind) or `.noOpener`, which the caller shows as an alert.
    func recordHandoff(_ outcome: FirmwareHandoffOutcome) -> String? {
        guard let release = availability?.release else { return nil }
        switch outcome {
        case .openedIn(let bundleIdentifier):
            recordHandoff(of: release, destination: .openedInApp, openedIn: bundleIdentifier)
            return PebbleAppHandoff.isPebbleApp(bundleIdentifier)
                ? Copy.Firmware.sentToPebble
                : Copy.Firmware.sentElsewhere
        case .savedToFiles:
            recordHandoff(of: release, destination: .savedToFiles)
            return Copy.Firmware.savedToFiles
        case .dismissed, .noOpener:
            return nil
        }
    }
}

extension View {
    /// Presents the Open In menu for `fileURL`, anchored to this view.
    ///
    /// Anchored to the button rather than to a zero-size probe so the iPad popover has somewhere
    /// sensible to point; on iPhone the menu is a sheet and the rect is ignored.
    func firmwareOpenInMenu(
        isPresented: Binding<Bool>,
        fileURL: URL?,
        onOutcome: @escaping (FirmwareHandoffOutcome) -> Void
    ) -> some View {
        overlay {
            FirmwareOpenInAnchor(
                isPresented: isPresented, fileURL: fileURL, onOutcome: onOutcome
            )
            .allowsHitTesting(false)
        }
    }
}

private struct FirmwareOpenInAnchor: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let fileURL: URL?
    let onOutcome: (FirmwareHandoffOutcome) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, let fileURL, !context.coordinator.isShowing else { return }
        context.coordinator.present(from: controller, fileURL: fileURL)
    }

    // An isolated conformance: UIKit has not marked this delegate protocol main-actor, but it
    // only ever calls it there, and the coordinator's state is main-actor state.
    @MainActor
    final class Coordinator: NSObject, @MainActor UIDocumentInteractionControllerDelegate {
        var parent: FirmwareOpenInAnchor
        private(set) var isShowing = false
        /// Held for the life of the menu: `UIDocumentInteractionController` is not retained by
        /// the presentation, and a released one takes its menu down with it.
        private var interaction: UIDocumentInteractionController?
        private var chosenApplication: String?

        init(_ parent: FirmwareOpenInAnchor) { self.parent = parent }

        func present(from controller: UIViewController, fileURL: URL) {
            let interaction = UIDocumentInteractionController(url: fileURL)
            // The UTI is left to be inferred from the `.pbz` extension. The Pebble app's own
            // imported type declaration supplies that mapping system-wide whenever it is
            // installed — which is the only case in which this menu is useful — so asserting a
            // type identifier we do not own would add a competing claim and buy nothing.
            interaction.delegate = self
            self.interaction = interaction
            chosenApplication = nil

            let shown = interaction.presentOpenInMenu(
                from: controller.view.bounds, in: controller.view, animated: true
            )
            if shown {
                isShowing = true
            } else {
                // Documented: no menu is presented when no installed app can open the document.
                self.interaction = nil
                finish(.noOpener)
            }
        }

        func documentInteractionController(
            _ controller: UIDocumentInteractionController,
            willBeginSendingToApplication application: String?
        ) {
            chosenApplication = application
        }

        func documentInteractionControllerDidDismissOpenInMenu(
            _ controller: UIDocumentInteractionController
        ) {
            // Fires for a cancel AND for a pick. `chosenApplication` is what separates them:
            // it is only set when the file is actually on its way somewhere.
            isShowing = false
            interaction = nil
            if let chosenApplication {
                finish(.openedIn(bundleIdentifier: chosenApplication))
            } else {
                finish(.dismissed)
            }
        }

        private func finish(_ outcome: FirmwareHandoffOutcome) {
            parent.isPresented = false
            parent.onOutcome(outcome)
        }
    }
}

// MARK: - Save to Files

extension View {
    /// The fallback: write the `.pbz` somewhere in Files, to be opened from there.
    ///
    /// `UIDocumentPickerViewController(forExporting:asCopy:)` with `asCopy: true` — a copy, so
    /// the verified file stays in staging and a retry does not need a second download.
    func firmwareFilesExport(
        isPresented: Binding<Bool>,
        fileURL: URL?,
        onOutcome: @escaping (FirmwareHandoffOutcome) -> Void
    ) -> some View {
        modifier(FirmwareFilesExport(isPresented: isPresented, fileURL: fileURL, onOutcome: onOutcome))
    }
}

private struct FirmwareFilesExport: ViewModifier {
    @Binding var isPresented: Bool
    let fileURL: URL?
    let onOutcome: (FirmwareHandoffOutcome) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let fileURL {
                FirmwareExportPicker(fileURL: fileURL) { outcome in
                    isPresented = false
                    onOutcome(outcome)
                }
                .ignoresSafeArea()
            }
        }
    }
}

private struct FirmwareExportPicker: UIViewControllerRepresentable {
    let fileURL: URL
    let onOutcome: (FirmwareHandoffOutcome) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOutcome: onOutcome) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onOutcome: (FirmwareHandoffOutcome) -> Void

        init(onOutcome: @escaping (FirmwareHandoffOutcome) -> Void) { self.onOutcome = onOutcome }

        func documentPicker(
            _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
        ) {
            onOutcome(.savedToFiles)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onOutcome(.dismissed)
        }
    }
}
