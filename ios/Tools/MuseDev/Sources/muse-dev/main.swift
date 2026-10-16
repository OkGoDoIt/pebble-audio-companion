import Foundation
import MuseLink

// muse-dev — developer tool for the Muse gadget integration (macOS).
//
//   muse-dev pair [--force]   advertise this Mac as a Muse gadget and pair it with the Muse app
//   muse-dev status           show the paired gadget and check its token against Muse's API
//   muse-dev refresh          rotate the device token
//
// State lives in ~/.config/muse-gadget (Meta's Linux gadget file shapes). Tokens are never printed.

let store = GadgetStore()
let api = MuseDeviceAPI()
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

func say(_ line: String) {
    print("[\(timestamp())] \(line)")
    fflush(stdout)
}

/// Rotates the token if it's due (or `force`), saving the result. Returns current credentials.
func freshCredentials(force: Bool = false) async throws -> MuseGadgetCredentials {
    var credentials = try store.loadCredentials()
    guard force || credentials.isRefreshDue() else { return credentials }
    let sdkToken = try? store.sdkToken()
    let tokens = try await api.refreshDeviceToken(
        refreshToken: credentials.refreshToken, nodeID: credentials.identity.nodeID,
        sdkToken: sdkToken, apiRoot: credentials.apiRoot)
    credentials = credentials.rotated(to: tokens)
    try store.save(credentials)
    say("device token rotated")
    return credentials
}

func pair(force: Bool) async throws {
    let sdkToken = try store.sdkToken()
    let identity = try store.loadOrCreateIdentity()
    if !force, (try? store.loadCredentials()) != nil {
        say("Already paired as \(identity.bleName) (\(identity.nodeID)). Use --force to pair again.")
        return
    }

    let (finished, finish) = AsyncStream.makeStream(of: Bool.self)
    let peripheral = MacSetupPeripheral(localName: identity.bleName)
    peripheral.onEvent = { say($0) }
    let controller = MuseSetupController(
        identity: identity, firmwareVersion: "0.1.0", sdkToken: sdkToken,
        transport: peripheral, network: MuseHTTPSReachability(),
        verify: { credentials throws(MuseProvisionFailure) in
            do {
                let vms = try await api.fetchVMs(accessToken: credentials.accessToken, apiRoot: credentials.apiRoot)
                say("device token works: \(vms.count) VM(s) leased")
                if vms.isEmpty { throw MuseProvisionFailure("auth_failed") }
            } catch let failure as MuseProvisionFailure {
                throw failure
            } catch {
                say("device token check failed: \(error)")
                throw MuseProvisionFailure("auth_failed")
            }
        },
        onPaired: { credentials in
            do {
                try store.save(credentials)
                say("pairing saved to \(store.pairingURL.path)")
                finish.yield(true)
                return true
            } catch {
                say("couldn't save the pairing: \(error)")
                return false
            }
        },
        trace: { say("setup: \($0)") })
    peripheral.controller = controller
    let runner = Task { await controller.run() }

    say("Setup is open for 10 minutes. On your iPhone, in the Muse app:")
    say("  Settings › Devices › Developer mode (on), then Add Device (+) and choose \(identity.bleName).")
    say("  (macOS may ask to allow Bluetooth for this tool first.)")

    let timeout = Task {
        try await Task.sleep(for: .seconds(600))
        finish.yield(false)
    }
    var paired = false
    for await result in finished {
        paired = result
        break
    }
    timeout.cancel()
    // Let auth_ok reach the app before tearing the service down.
    try? await Task.sleep(for: .milliseconds(1500))
    await controller.stop()
    peripheral.stop()
    _ = await runner.value
    if paired {
        say("Paired as \(identity.bleName) (\(identity.nodeID)). Next: muse-dev status")
    } else {
        fail("Setup window closed without pairing.")
    }
}

func status() async throws {
    let credentials = try await freshCredentials()
    let identity = credentials.identity
    say("gadget \(identity.bleName)  node \(identity.nodeID)")
    let age = Int(Date().timeIntervalSince(credentials.accessTokenSavedAt) / 60)
    say("token age \(age) min, API \(credentials.apiRoot.absoluteString), noise host \(credentials.noiseHost.isEmpty ? MuseDeviceAPI.defaultNoiseHost + " (default)" : credentials.noiseHost)")
    do {
        let vms = try await api.fetchVMs(accessToken: credentials.accessToken, apiRoot: credentials.apiRoot)
        for vm in vms {
            say("VM \(vm.vmName.isEmpty ? "(unnamed)" : vm.vmName)  id \(vm.vmID)\(vm.isDefault ? "  [default]" : "")  url \(vm.vmURL)")
        }
        if vms.isEmpty { say("no VMs leased to this device") }
    } catch .http(401) {
        fail("The API rejected the device token (401). Try `muse-dev refresh`; if that is also rejected, pair again.")
    }
}

do {
    switch arguments.first {
    case "pair": try await pair(force: arguments.contains("--force"))
    case "status": try await status()
    case "refresh": _ = try await freshCredentials(force: true)
    default:
        print("usage: muse-dev pair [--force] | status | refresh")
        exit(2)
    }
} catch {
    fail("\(error)")
}
