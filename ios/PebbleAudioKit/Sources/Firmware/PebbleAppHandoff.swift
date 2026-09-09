import Foundation

/// What we established about handing a `.pbz` to the official Pebble app, and the small number
/// of constants that follow from it. This file is the research; the rest of the feature is built
/// on top of it, so if any of this turns out to be wrong, this is the place it is wrong.
///
/// ## The question
///
/// Can this app push firmware straight into the official Pebble app, with no picker?
///
/// **No.** Not "not easily" — there is no such API on iOS.
///
/// - `UIApplication.open(_:options:completionHandler:)` dispatches on the URL *scheme* and has
///   no target-app parameter. Its documented parameter list covers `http`, `https`, `tel`,
///   `facetime`, `mailto` and custom app schemes; `file` is not among them, and the only two
///   options it accepts (`universalLinksOnly`, `eventAttribution`) name no app. Apple DTS states
///   flatly that opening URLs is the only way one app can launch another.
///   <https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:)>
/// - Even if it launched, the receiving app has no sandbox extension for a path inside our
///   container. The document-interaction and share paths exist precisely because they perform
///   the copy or grant the security-scoped access.
///
/// ## What does work
///
/// The official app takes firmware as an **opened document**. Its `Info.plist` declares a
/// `CFBundleDocumentTypes` entry for `coredevices.coreapp.PebbleFirmware` with
/// `LSHandlerRank = Owner`, and a `UTImportedTypeDeclarations` entry mapping that identifier to
/// the `pbz` filename extension. The file arrives at SwiftUI's `.onOpenURL`, is forwarded to
/// `IOSDelegate.handleOpenUrl`, and lands in `RealPebbleDeepLinkHandler.handle(uri:)`.
///
/// Two consequences, both load-bearing:
///
/// 1. **The routing is by file name.** `handle(uri:)` reaches `handleFirmware()` only through
///    `uri.lastPathSegment?.endsWith(".pbz")`. A file handed over under any other name is
///    silently ignored — no error in their app, nothing on the watch. Hence
///    `FirmwareRelease.suggestedFileName` asserting the suffix rather than trusting the asset
///    URL's own path.
/// 2. **A link is not a file.** `handle(uri:)` matches on scheme first, and the `https`/`http`
///    branch handles exactly one thing (a GitHub OAuth callback) and otherwise returns false —
///    *before* the `.pbz` suffix test is ever reached. So handing the Pebble app an
///    `https://…/firmware.pbz` URL does nothing at all. The download has to happen here.
///
/// There is also no firmware URL scheme to aim at. The app registers `pebble` and `pebblejs`,
/// and the `pebble` hosts it implements are `custom-boot-config-url`, `appstore`, `navbar`,
/// `show-watches` and the Index companion registration. None of them install firmware.
///
/// ## And what happens next, in their app
///
/// `handleFirmware()` copies the file and calls `sideloadFirmware(path:)` on every connected
/// watch, which goes straight to `beginFirmwareUpdate` — **there is no confirmation step in the
/// Pebble app.** Choosing Pebble from the Open In menu starts the flash. That is why the consent
/// in this app is placed immediately before the menu is presented, and why it says the watch
/// will restart.
///
/// The one real safety net is theirs: `FirmwareUpdater.performSafetyChecks` throws
/// `SafetyCheckFailed` when `watchPlatform != firmware.hwRev`, so a `.pbz` built for the wrong
/// board is refused before anything is written.
///
/// (Sources: `mobileapp/iosApp/iosApp/Info.plist`, `iOSApp.swift`,
/// `composeApp/src/iosMain/.../IOSDelegate.kt`,
/// `pebble/src/commonMain/.../PebbleDeepLinkHandler.kt`,
/// `libpebble3/src/commonMain/.../endpointmanager/FirmwareUpdater.kt`. Read-only reference
/// checkout; nothing there is modified by this project.)
public enum PebbleAppHandoff {
    /// The official app's bundle id (`mobileapp/iosApp/Configuration/Config.xcconfig`:
    /// `BUNDLE_ID=coredevices.coreapp`).
    ///
    /// Used **only to recognise** the app the person picked, via
    /// `UIDocumentInteractionControllerDelegate.documentInteractionController(_:willBeginSendingToApplication:)`,
    /// which reports the chosen bundle id. It is not, and cannot be, used to target the app.
    public static let bundleIdentifier = "coredevices.coreapp"

    /// A development build of the official app installs under its own id. Recognised too, so a
    /// hand-off to it is not reported as "sent somewhere else".
    public static let alternateBundleIdentifiers = ["coredevices.coreapp.dev"]

    /// Whether the app the person chose is the Pebble app.
    public static func isPebbleApp(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == Self.bundleIdentifier
            || alternateBundleIdentifiers.contains(bundleIdentifier)
    }

    /// The uniform type identifier the official app declares for `.pbz`.
    ///
    /// Recorded here for reference, and deliberately **not** declared in this app's own
    /// `Info.plist`. Its declaration is an *imported* one (nobody exports this type), so a second
    /// imported declaration from us would be a competing, unowned claim about a type we do not
    /// define — and it would buy nothing: the mapping already exists whenever the Pebble app is
    /// installed, which is the only situation in which handing it a `.pbz` means anything. Note
    /// also that their declaration conforms the type to `public.text`, which a ZIP archive is
    /// not; copying that would be copying a mistake.
    public static let firmwareTypeIdentifier = "coredevices.coreapp.PebbleFirmware"
}
