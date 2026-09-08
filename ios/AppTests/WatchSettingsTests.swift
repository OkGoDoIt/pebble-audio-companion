import Foundation
import Testing

/// Settings · Watch: the firmware-version unpacking, and the two pieces of copy that exist to
/// stop a misleading label coming back.
@Suite("watch settings") @MainActor
struct WatchSettingsTests {

    // MARK: - Firmware version unpacking

    /// The shared wire fixture, decoded.
    ///
    /// `spec/fixtures/info_streaming.json` carries `"fw_version_packed": 67698690` and describes
    /// it as "fw 4.9.2"; PebbleOS's own `test_audio_companion_protocol.c` builds the same word as
    /// `(4u << 24) | (9u << 16) | 2u`. The app used to shift by 16/8/0 and read that back as
    /// **v9.0.2** — major taken from the minor's byte, and the patch's high byte dropped. No
    /// shipped firmware fills the field, so the wrong answer never reached a screen; this pins
    /// the layout so it cannot be wrong on the first day one does.
    @Test func unpacksTheSharedFixtureVersion() {
        #expect(LiveWatchStatusSource.firmwareLabel(67_698_690) == "v4.9.2")
        #expect(LiveWatchStatusSource.firmwareLabel(0x0409_0002) == "v4.9.2")
    }

    /// A zero word is "the watch did not tell us", not "version 0.0". It has to stay nil, because
    /// nil is what makes `SettingsWatchScreen` leave the row out entirely — the fix for a row
    /// that rendered a permanent em-dash on every install.
    @Test func anUnreportedVersionStaysUnknown() {
        #expect(LiveWatchStatusSource.firmwareLabel(0) == nil)
    }

    /// A `.0` patch is dropped, so a release build reads "v4.9" rather than "v4.9.0".
    @Test func aZeroPatchIsOmitted() {
        #expect(LiveWatchStatusSource.firmwareLabel(0x0409_0000) == "v4.9")
    }

    /// Patch is the low SIXTEEN bits per the contract, not a byte — a three-digit patch must
    /// survive the round trip rather than wrapping.
    @Test func patchUsesTheFullLowHalfWord() {
        #expect(LiveWatchStatusSource.firmwareLabel(0x0409_0101) == "v4.9.257")
    }

    // MARK: - The row that used to say "Find Watch"

    /// `findWatch()` is `CompanionRuntime.reconnect()` → `AudioGattLink.resync()`: it rebuilds
    /// the phone's GATT connection. The audio-companion control channel has no buzz/alert opcode
    /// at all (the complete phone→watch set is AuthRequest, AuthRevoke, Checkpoint,
    /// PauseRequest, ResumeRequest, ReceiverHealth, EnableRequest), so nothing in this app can
    /// make a watch ring. "Find Watch" promised exactly that, and a user asked what it did.
    @Test func theActionRowIsNamedForWhatItActuallyDoes() {
        #expect(Copy.Settings.Watch.reconnect == "Reconnect")
        #expect(Copy.Settings.Watch.reconnect != Copy.Settings.Watch.findWatch)
    }

    /// And the subline says so, because "Reconnect" alone still does not tell you the watch
    /// stays silent.
    @Test func theSublineRulesOutRingingTheWatch() {
        let subtitle = Copy.Settings.Watch.reconnectSub
        #expect(subtitle.contains("Bluetooth"))
        #expect(subtitle.contains("does not ring"))
    }

    /// Forgetting the watch is the largest action on the screen. The confirmation has to say
    /// what is lost — and, more importantly, what is not.
    @Test func theForgetConfirmationSaysRecordingsAreKept() {
        let message = Copy.Settings.Watch.forgetMessage
        #expect(message.contains("no longer authorized"))
        #expect(message.contains("recordings and transcripts are kept"))
    }
}
