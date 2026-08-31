import Foundation
import WireProtocol
import Receiver

// Port of `app/.../ui/StatusUi.kt` — the pure session-state -> status-card copy engine behind
// the redesign's status-card families (plan Part 2-B #18, Part 4.6).
//
// Copy policy (normative): where the approved redesign copy exists for a state (the
// States · Status Card artboard, extraction §2.18/§3, plan Part 6.7), THE NEW COPY WINS over
// the old KMP strings. States the artboards do not draw (watch-side pause causes, watch-side
// off, denied/revoked, individual connect-failure kinds) keep the KMP copy verbatim — it is
// the only approved source for them and the KMP tests pin much of it. No protocol vocabulary
// (GATT, spool, checkpoint, sequence, stream id, …) may ever appear here, and raw platform
// error text is diagnostics-only.
//
// Structural adjustments vs the KMP file (each mirrored in StatusUITests):
// - `AudioCompanionSettings.backgroundReceiverEnabled: Boolean` is replaced by the ported
//   tri-state `CaptureIntent` (plan Part 6.1). The new `.paused` intent maps to the redesign's
//   Paused family even while disconnected (the watch is not capturing, so "Reconnecting…
//   it keeps recording" would be false).
// - `AudioCompanionDiagnostics.pauseRequested` is the single `storagePauseRequested` flag.
// - KMP `StatusSeverity` -> `StatusDot` (plus `.consent`, the artboard's violet dot).
// - KMP `PrimaryAction` -> `StatusAction`; `Reconnect` becomes `.findWatch` (6.7: Find Watch
//   attempts a connection, no capture-intent side effects), Denied's `Troubleshoot` becomes
//   `.tryAgain` (the approved onboarding-branch action), and `.resume` is new for the Paused
//   family. `.stop` stays on the Recording model as the resolving transport semantic even
//   though the drawn card itself shows no button (Today's toolbar/live row renders it).

/// Status-card family (the artboard's six + 6.7's transcripts-off + two kit-level groupings
/// for states the artboard treats as sub-moments).
public enum StatusFamily: Sendable, Equatable {
    /// Green: streaming and storing audio.
    case recording
    /// Capture intentionally not happening (user, watch policy, storage pressure).
    case paused
    /// Link lost or unreachable; the watch buffers.
    case reconnecting
    /// Transitional link/handshake progress (connecting, authorizing, authorized-idle).
    case connecting
    /// Phone-side Bluetooth problems (off / unauthorized / unavailable).
    case bluetoothOff
    /// Capture is off (phone- or watch-side) and needs a deliberate Start.
    case notRecording
    /// A prompt is waiting on the watch (consent or enable).
    case confirmOnWatch
    /// 6.7 first-run family: recording safe, transcription unconfigured.
    case transcriptsOff
    /// Denied / revoked / watch error / stale-link states that need user help.
    case needsAttention
}

/// Status dot color semantic (KMP `StatusSeverity` + the artboard's violet consent dot).
public enum StatusDot: Sendable, Equatable {
    case neutral
    case info
    case active
    case attention
    case problem
    /// Violet: waiting on the person to answer a prompt on the watch.
    case consent
}

/// The one primary action a status card may offer (rule: at most one; filled = resolves,
/// bordered = helper).
public enum StatusAction: Sendable, Equatable {
    case start
    case stop
    case resume
    case findWatch
    case openSettings
    case setUpTranscripts
    case tryAgain
    case troubleshoot
    case setUpAgain

    /// Filled = tapping it resolves the state; bordered = it helps.
    public var isFilled: Bool {
        switch self {
        case .start, .resume, .openSettings, .setUpTranscripts: return true
        case .stop, .findWatch, .tryAgain, .troubleshoot, .setUpAgain: return false
        }
    }

    /// Approved button label, where the catalog defines one (nil = the app surface decides).
    public var defaultLabel: String? {
        switch self {
        case .start: return StatusCopy.startRecording
        case .stop: return StatusCopy.stop
        case .resume: return StatusCopy.resume
        case .findWatch: return StatusCopy.findWatch
        case .openSettings: return StatusCopy.openSettings
        case .setUpTranscripts: return StatusCopy.setUpTranscripts
        case .tryAgain: return StatusCopy.tryAgain
        case .troubleshoot, .setUpAgain: return nil
        }
    }
}

/// One status-card model: dot + headline + ONE calm sentence + at most one action.
public struct StatusModel: Sendable, Equatable {
    public let family: StatusFamily
    public let headline: String
    public let detail: String?
    public let dot: StatusDot
    public let action: StatusAction?

    public init(
        family: StatusFamily,
        headline: String,
        detail: String?,
        dot: StatusDot,
        action: StatusAction?
    ) {
        self.family = family
        self.headline = headline
        self.detail = detail
        self.dot = dot
        self.action = action
    }

    /// 6.7 first-run/"Later" family — shown by the app until a transcription mode is
    /// configured. Not derived from session state, so it is a constant, not part of
    /// `statusModel(...)`.
    public static let transcriptsOff = StatusModel(
        family: .transcriptsOff,
        headline: StatusCopy.transcriptsOff,
        detail: StatusCopy.transcriptsOffLine,
        dot: .neutral,
        action: .setUpTranscripts
    )
}

// MARK: - Copy table

/// The status-family slice of the approved string catalog.
///
/// The kit target cannot import the app target, so the approved status strings are duplicated
/// here from `ios/App/DesignSystem/Copy.swift` (which mirrors the mockup extraction §2.18/§3
/// and plan Part 6.7). `Copy.Status` (and the borrowed onboarding-failure strings) should be
/// swapped to re-export these constants so the catalog stays single-sourced.
public enum StatusCopy {
    // Recording family (green · no card button; transport renders elsewhere).
    public static let recording = "Recording"
    public static func connected(device: String) -> String { "\(device) · connected" }
    /// Detail fallback when no device name is known yet.
    public static let genericDeviceName = "Pebble"

    // Paused family (attention · filled [Resume]).
    public static let paused = "Paused"
    public static let pausedLine =
        "The watch is not capturing. Coverage shows this as paused, not missing."
    public static let resume = "Resume"

    // Reconnecting family (attention · bordered [Find Watch]).
    public static let reconnecting = "Reconnecting…"
    public static let reconnectingLine =
        "Your Pebble is out of range. It keeps recording and buffers a few minutes."
    public static let findWatch = "Find Watch"

    // Bluetooth-off family (red · filled [Open Settings]).
    public static let bluetoothOff = "Bluetooth is off"
    public static let bluetoothOffLine = "Turn on Bluetooth to receive audio from your watch."
    public static let openSettings = "Open Settings"

    // 6.7 Bluetooth-permission branch (red).
    public static let bluetoothDenied = "Bluetooth access is off for this app"
    public static let bluetoothDeniedLine = "Allow Bluetooth in Settings to receive audio."

    // Not-recording family (neutral · filled [Start Recording]).
    public static let notRecording = "Not recording"
    public static let notRecordingLine = "Background audio is off."
    public static let startRecording = "Start Recording"

    // Confirm-on-watch family (violet · no action).
    public static let confirmOnWatch = "Confirm on your watch"
    public static let confirmOnWatchLine =
        "Your Pebble is asking to allow this phone to receive audio."

    // 6.7 first-run family (neutral · filled [Set Up Transcripts]).
    public static let transcriptsOff = "Transcripts are off"
    public static let transcriptsOffLine =
        "Recording is safe on this phone. Choose where transcripts happen."
    public static let setUpTranscripts = "Set Up Transcripts"

    // Approved strings reused from other artboards.
    public static let boundElsewhere = "Authorized to another phone"
    public static let boundElsewhereLine =
        "On the watch: Settings → Audio Companion → Forget Receiver, then try again."
    public static let tryAgain = "Try Again"
    public static let stop = "Stop"

    // KMP-carried sub-state copy (states the artboards do not draw; ported verbatim except
    // "->" -> "→" to match the approved catalog's arrow style).
    public static let watchAudioOff = "Background audio is off on the watch"
    public static let watchAudioOffAskLine =
        "Tap Start Recording when you want to ask your watch to turn it on."
    public static let watchAudioOffRestartLine =
        "Tap Start Recording when you’re ready, then approve the prompt on your watch."
    public static let pausedMicConflict = "Paused: the watch is using its microphone"
    public static let pausedMicConflictLine = "Recording resumes when the watch finishes."
    public static let pausedStorageLow = "Paused: phone storage low"
    public static let pausedStorageLowRecordingLine =
        "Free storage or reduce retention to resume recording."
    public static let pausedStorageLowReceivingLine =
        "Free storage or reduce retention to resume receiving."
    public static let pausedLowBattery = "Paused to protect watch battery"
    public static let pausedLowBatteryLine = "Recording resumes once the watch has charged."
    public static let pausedPowerSave = "Paused while the watch is saving power"
    public static let pausedPowerSaveLine =
        "Recording resumes when the watch wakes or leaves low power mode."
    public static let watchNeedsAttention = "Watch audio needs attention"
    public static let watchNeedsAttentionLine = "Check the watch’s Settings → Audio Companion."
    public static let connecting = "Connecting to your Pebble"
    public static let connectingLine = "This usually takes a few seconds."
    public static let authorizing = "Authorizing receiver"
    public static let pendingEnable = "Turn on Background Audio on your watch"
    public static let pendingEnableLine = "Approve the prompt on your Pebble to start recording."
    public static let deniedGeneric = "Not authorized"
    public static let deniedGenericLine =
        "The watch declined this receiver. Try again to re-request access."
    public static let authorizedIdle = "Authorized and ready"
    public static let authorizedIdleLine = "Waiting for the watch to start streaming."
    public static let revoked = "Receiver access was revoked"
    public static let revokedLine = "The watch no longer allows this app to receive audio."
    public static let bluetoothUnavailable = "Bluetooth isn’t available right now"
    public static let bluetoothUnavailableLine =
        "This device can’t use Bluetooth at the moment. Try again shortly."
    public static let linkRejected = "Your Pebble needs to reconnect"
    public static let linkRejectedLine =
        "Turn Bluetooth off and back on — or re-pair your Pebble in Settings — and it "
        + "will reconnect. This can happen right after updating the watch firmware."
    public static let connectionInterrupted = "Connection interrupted"
    public static let connectionInterruptedLine =
        "Trying to reconnect. If this keeps up, turn Bluetooth off and back on."
}

// MARK: - Mapping

/// Maps receiver/protocol state to the status-card model.
///
/// `watchServiceStateRaw` is the watch's own reported state (Info read + state-change pushes);
/// when the watch says it is paused/disabled, that wins over the session-level view so the
/// phone always matches what the watch’s Settings screen shows.
public func statusModel(
    state: ReceiverSessionState,
    intent: CaptureIntent,
    storagePauseRequested: Bool = false,
    watchServiceStateRaw: Int? = nil,
    deviceName: String? = nil
) -> StatusModel {
    switch state {
    case .streaming, .authorized:
        if let override = watchStatusOverride(
            watchServiceStateRaw, storagePauseRequested: storagePauseRequested
        ) {
            return override
        }
    default:
        break
    }
    return statusForSessionState(
        state,
        intent: intent,
        storagePauseRequested: storagePauseRequested,
        deviceName: deviceName
    )
}

/// Watch-reported states that the phone must mirror (paused, disabled, error).
private func watchStatusOverride(
    _ watchServiceStateRaw: Int?,
    storagePauseRequested: Bool
) -> StatusModel? {
    guard let raw = watchServiceStateRaw, raw >= 0, raw <= Int(UInt8.max),
          let service = ServiceState(rawValue: UInt8(raw))
    else { return nil }
    switch service {
    case .disabled:
        return StatusModel(
            family: .notRecording,
            headline: StatusCopy.watchAudioOff,
            detail: StatusCopy.watchAudioOffAskLine,
            dot: .neutral,
            action: .start
        )
    case .pausedConflict:
        return StatusModel(
            family: .paused,
            headline: StatusCopy.pausedMicConflict,
            detail: StatusCopy.pausedMicConflictLine,
            dot: .info,
            action: nil
        )
    case .pausedPolicy:
        if storagePauseRequested {
            return StatusModel(
                family: .paused,
                headline: StatusCopy.pausedStorageLow,
                detail: StatusCopy.pausedStorageLowRecordingLine,
                dot: .attention,
                action: nil
            )
        }
        // The deliberate pause: the redesign's Paused family, verbatim.
        return StatusModel(
            family: .paused,
            headline: StatusCopy.paused,
            detail: StatusCopy.pausedLine,
            dot: .attention,
            action: .resume
        )
    case .pausedLowBattery:
        return StatusModel(
            family: .paused,
            headline: StatusCopy.pausedLowBattery,
            detail: StatusCopy.pausedLowBatteryLine,
            dot: .attention,
            action: nil
        )
    case .pausedPowerSave:
        return StatusModel(
            family: .paused,
            headline: StatusCopy.pausedPowerSave,
            detail: StatusCopy.pausedPowerSaveLine,
            dot: .info,
            action: nil
        )
    case .error:
        return StatusModel(
            family: .needsAttention,
            headline: StatusCopy.watchNeedsAttention,
            detail: StatusCopy.watchNeedsAttentionLine,
            dot: .attention,
            action: .troubleshoot
        )
    case .idle, .authorizedIdle, .streaming:
        return nil
    }
}

private func statusForSessionState(
    _ state: ReceiverSessionState,
    intent: CaptureIntent,
    storagePauseRequested: Bool,
    deviceName: String?
) -> StatusModel {
    switch state {
    case .disconnected:
        switch intent {
        case .off:
            return StatusModel(
                family: .notRecording,
                headline: StatusCopy.notRecording,
                detail: StatusCopy.notRecordingLine,
                dot: .neutral,
                action: .start
            )
        case .paused:
            // Tri-state addition: while deliberately paused, the watch is not capturing, so
            // "Reconnecting… it keeps recording" would be dishonest. Paused wins.
            return StatusModel(
                family: .paused,
                headline: StatusCopy.paused,
                detail: StatusCopy.pausedLine,
                dot: .attention,
                action: .resume
            )
        case .active:
            return StatusModel(
                family: .reconnecting,
                headline: StatusCopy.reconnecting,
                detail: StatusCopy.reconnectingLine,
                dot: .attention,
                action: .findWatch
            )
        }

    case .connectionFailed(let kind, _):
        return connectionFailedStatus(kind)

    case .connecting:
        return StatusModel(
            family: .connecting,
            headline: StatusCopy.connecting,
            detail: StatusCopy.connectingLine,
            dot: .info,
            action: .findWatch
        )

    case .authorizing:
        return StatusModel(
            family: .connecting,
            headline: StatusCopy.authorizing,
            detail: nil,
            dot: .info,
            action: .findWatch
        )

    case .pendingConsent:
        return StatusModel(
            family: .confirmOnWatch,
            headline: StatusCopy.confirmOnWatch,
            detail: StatusCopy.confirmOnWatchLine,
            dot: .consent,
            action: nil
        )

    case .pendingEnable:
        return StatusModel(
            family: .confirmOnWatch,
            headline: StatusCopy.pendingEnable,
            detail: StatusCopy.pendingEnableLine,
            dot: .consent,
            action: nil
        )

    case .denied:
        switch state.deniedStatus {
        case .deniedMismatch:
            return StatusModel(
                family: .needsAttention,
                headline: StatusCopy.boundElsewhere,
                detail: StatusCopy.boundElsewhereLine,
                dot: .attention,
                action: .tryAgain
            )
        case .deniedDisabled:
            return StatusModel(
                family: .notRecording,
                headline: StatusCopy.watchAudioOff,
                detail: StatusCopy.watchAudioOffRestartLine,
                dot: .attention,
                action: .start
            )
        default:
            return StatusModel(
                family: .needsAttention,
                headline: StatusCopy.deniedGeneric,
                detail: StatusCopy.deniedGenericLine,
                dot: .attention,
                action: .tryAgain
            )
        }

    case .authorized:
        return StatusModel(
            family: .connecting,
            headline: StatusCopy.authorizedIdle,
            detail: StatusCopy.authorizedIdleLine,
            dot: .info,
            action: nil
        )

    case .streaming:
        if storagePauseRequested {
            return StatusModel(
                family: .paused,
                headline: StatusCopy.pausedStorageLow,
                detail: StatusCopy.pausedStorageLowReceivingLine,
                dot: .attention,
                action: nil
            )
        }
        return StatusModel(
            family: .recording,
            headline: StatusCopy.recording,
            detail: StatusCopy.connected(device: deviceName ?? StatusCopy.genericDeviceName),
            dot: .active,
            action: .stop
        )

    case .revoked:
        return StatusModel(
            family: .needsAttention,
            headline: StatusCopy.revoked,
            detail: StatusCopy.revokedLine,
            dot: .problem,
            action: .setUpAgain
        )
    }
}

/// Plain-language, actionable copy for a connection failure. The watch/BLE stack speaks in ATT
/// error codes; the user should never see one. `.linkRejected` in particular is the "stale iOS
/// GATT cache after a firmware update" case — retrying the same cached handles can't fix it, so
/// the copy points at the one thing that does: toggling Bluetooth (or re-pairing).
func connectionFailedStatus(_ kind: ConnectFailureKind) -> StatusModel {
    switch kind {
    case .bluetoothOff:
        return StatusModel(
            family: .bluetoothOff,
            headline: StatusCopy.bluetoothOff,
            detail: StatusCopy.bluetoothOffLine,
            dot: .problem,
            action: .openSettings
        )
    case .bluetoothUnauthorized:
        return StatusModel(
            family: .bluetoothOff,
            headline: StatusCopy.bluetoothDenied,
            detail: StatusCopy.bluetoothDeniedLine,
            dot: .problem,
            action: .openSettings
        )
    case .bluetoothUnavailable:
        return StatusModel(
            family: .bluetoothOff,
            headline: StatusCopy.bluetoothUnavailable,
            detail: StatusCopy.bluetoothUnavailableLine,
            dot: .attention,
            action: .tryAgain
        )
    case .watchUnreachable:
        return StatusModel(
            family: .reconnecting,
            headline: StatusCopy.reconnecting,
            detail: StatusCopy.reconnectingLine,
            dot: .attention,
            action: .findWatch
        )
    case .linkRejected:
        return StatusModel(
            family: .needsAttention,
            headline: StatusCopy.linkRejected,
            detail: StatusCopy.linkRejectedLine,
            dot: .attention,
            action: .findWatch
        )
    case .unknown:
        return StatusModel(
            family: .reconnecting,
            headline: StatusCopy.connectionInterrupted,
            detail: StatusCopy.connectionInterruptedLine,
            dot: .attention,
            action: .findWatch
        )
    }
}

/// Short plain-language label for the watch's reported state (Settings "Watch reports" row).
public func watchServiceStateLabel(_ raw: Int?) -> String {
    guard let raw, raw >= 0, raw <= Int(UInt8.max),
          let service = ServiceState(rawValue: UInt8(raw))
    else { return "Not connected" }
    switch service {
    case .disabled: return "Background audio off"
    case .idle: return "Waiting for this app"
    case .authorizedIdle: return "Authorized, not recording"
    case .streaming: return "Recording"
    case .pausedConflict: return "Paused: microphone in use"
    case .pausedPolicy: return "Paused"
    case .pausedLowBattery: return "Paused: low battery"
    case .pausedPowerSave: return "Paused: power save"
    case .error: return "Needs attention"
    }
}
