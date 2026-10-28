import Firmware
import SwiftUI
import UIKit

// The hand-off itself: getting a file out of this app and into the Pebble app. Firmware (a
// verified `.pbz`) and the Pebble Audio plugin (the bundled `.pbw`) both go this way; only the
// file, and whether the type is named, differ.
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
// That signal is weaker than documented: on the iOS 27 simulator with no Pebble app installed
// (2026-10-28), the menu still appears, offering only Save to Files and More, and the call returns
// `true`. So `.noOpener` is what iOS says when it says it, never proof that the Pebble app is here.
//
// A general share sheet would work on a good day, but Apple has been deliberately narrowing
// file→app hand-off since iOS 16 (a share extension can suppress an app's Open In row; iOS 17
// stopped AirDrop handing files straight to declared handlers, which DTS confirmed is
// intentional). The Open In menu is the documented path, so it is the primary one, with
// Save to Files as the fallback that has survived every one of those changes.
//
// <https://developer.apple.com/documentation/uikit/uidocumentinteractioncontroller/presentopeninmenu(from:in:animated:)>

/// What the person did with the file.
enum PebbleAppHandoffOutcome: Equatable {
    /// An app was chosen. The bundle id is what iOS reported through
    /// `willBeginSendingToApplication` — the one thing it does tell us.
    case openedIn(bundleIdentifier: String?)
    /// Saved through the Files exporter.
    case savedToFiles
    /// The menu closed with nothing chosen.
    case dismissed
    /// Nothing installed can open the file. No menu was shown.
    case noOpener
}

extension FirmwareUpdateModel {
    /// Records what the person did with the file and returns the one line that reports it, so
    /// the record and the sentence can never disagree. Nil when there is nothing to record: a
    /// dismissal (they changed their mind) or `.noOpener`, which the caller shows as an alert.
    func recordHandoff(_ outcome: PebbleAppHandoffOutcome) -> String? {
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
    ///
    /// `typeIdentifier` nil leaves the type to be inferred from the file's extension; a value
    /// names it on the interaction (`UIDocumentInteractionController.uti`), which changes only
    /// which apps the menu lists.
    func pebbleAppOpenInMenu(
        isPresented: Binding<Bool>,
        fileURL: URL?,
        typeIdentifier: String? = nil,
        onOutcome: @escaping (PebbleAppHandoffOutcome) -> Void
    ) -> some View {
        overlay {
            PebbleAppOpenInAnchor(
                isPresented: isPresented, fileURL: fileURL, typeIdentifier: typeIdentifier,
                onOutcome: onOutcome
            )
            .allowsHitTesting(false)
        }
    }

    /// The firmware's `.pbz`, its type inferred from the extension (see `present` below).
    func firmwareOpenInMenu(
        isPresented: Binding<Bool>,
        fileURL: URL?,
        onOutcome: @escaping (PebbleAppHandoffOutcome) -> Void
    ) -> some View {
        pebbleAppOpenInMenu(isPresented: isPresented, fileURL: fileURL, onOutcome: onOutcome)
    }
}

private struct PebbleAppOpenInAnchor: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let fileURL: URL?
    let typeIdentifier: String?
    let onOutcome: (PebbleAppHandoffOutcome) -> Void

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
        var parent: PebbleAppOpenInAnchor
        private(set) var isShowing = false
        /// Held for the life of the menu: `UIDocumentInteractionController` is not retained by
        /// the presentation, and a released one takes its menu down with it.
        private var interaction: UIDocumentInteractionController?
        private var chosenApplication: String?

        init(_ parent: PebbleAppOpenInAnchor) { self.parent = parent }

        func present(from controller: UIViewController, fileURL: URL) {
            let interaction = UIDocumentInteractionController(url: fileURL)
            // Firmware leaves the UTI to be inferred from the `.pbz` extension. The Pebble app's
            // own imported type declaration supplies that mapping system-wide whenever it is
            // installed — which is the only case in which this menu is useful — so asserting a
            // type identifier we do not own would add a competing claim and buy nothing. The
            // plugin names its type (`PebbleAppHandoff.appTypeIdentifier` says why); naming it
            // here is a hint to this one menu, never a declaration.
            if let typeIdentifier = parent.typeIdentifier { interaction.uti = typeIdentifier }
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

        private func finish(_ outcome: PebbleAppHandoffOutcome) {
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
        onOutcome: @escaping (PebbleAppHandoffOutcome) -> Void
    ) -> some View {
        modifier(FirmwareFilesExport(isPresented: isPresented, fileURL: fileURL, onOutcome: onOutcome))
    }
}

private struct FirmwareFilesExport: ViewModifier {
    @Binding var isPresented: Bool
    let fileURL: URL?
    let onOutcome: (PebbleAppHandoffOutcome) -> Void

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
    let onOutcome: (PebbleAppHandoffOutcome) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOutcome: onOutcome) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onOutcome: (PebbleAppHandoffOutcome) -> Void

        init(onOutcome: @escaping (PebbleAppHandoffOutcome) -> Void) { self.onOutcome = onOutcome }

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
