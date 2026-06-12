# iOS Lifecycle Validation

This document records the iOS-specific validation required before making reliability claims for
background audio receiving. The native host shell is build-verified, but the radio and restoration
rows require a physical iPhone and Pebble-class watch running firmware with the Audio Companion GATT
service enabled.

## Build Verification

- 2026-06-12: `./gradlew --no-daemon :app:compileKotlinIosSimulatorArm64` passed.
- 2026-06-12: `xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp -configuration Debug
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  CODE_SIGNING_ALLOWED=NO build` passed.

## Host Shell Coverage

- `iosApp/iosApp/Info.plist` declares `UIBackgroundModes` entries for `bluetooth-central` and
  `processing`.
- `NSBluetoothAlwaysUsageDescription` is present; no phone microphone entitlement is declared.
- `AppDelegate` creates the Kotlin receiver runtime at launch via
  `IosAudioCompanionBootstrap.applicationDidFinishLaunching()`.
- Foreground/background lifecycle callbacks forward to the Kotlin runtime.
- BGProcessing is registered for deferred storage/transcription maintenance; BLE notification
  handling remains in the Core Bluetooth callback path and must stay append-and-return fast.

## Hardware Matrix

| Scenario | Expected result | Status |
| --- | --- | --- |
| Foreground with official app connected | Audio app authorizes, receives data, and official app behavior remains normal. | Not run |
| Background, screen on | Notifications continue to append to the frame log; no transcription work runs in BLE callback. | Not run |
| Locked screen | Notifications continue or gaps are recorded honestly. | Not run |
| Suspended and restored by iOS | Core Bluetooth restoration rebuilds the receiver and resumes from persisted checkpoint state. | Not run |
| User force-quit | iOS does not relaunch the receiver; app reports downtime/gap after next manual launch. | Not run |
| Bluetooth toggled off/on | Receiver reconnects and checkpoint resume avoids duplicate durable frames. | Not run |
| Watch out of range then returns | Receiver reconnects and firmware catch-up burst drains without hidden loss. | Not run |
| Official Core Devices app connected throughout | Official notifications, app install, and dictation remain usable while audio app subscribes. | Not run |

## Notes

- The simulator build validates Swift/Kotlin linking and app metadata only; it cannot validate Core
  Bluetooth background delivery.
- The first physical-device pass should capture device model, iOS version, firmware commit, app
  commit, session length, observed gap counts, and whether the official app stayed connected.
