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

/// The watch-side commands registered with `--register`, for seeing whether and how Muse calls a
/// gadget's commands. Here they only print; in the app they reach the watch.
let watchCommands: MuseJSON = [
    "watch.show": [
        "description": "Show a short message on the user's Pebble smartwatch screen. Keep it under 200 characters.",
        "required": [
            "title": ["type": "string", "description": "A few words, shown in bold."],
            "body": ["type": "string", "description": "The message text."],
        ],
        "optional": [:],
    ],
    "watch.vibrate": [
        "description": "Vibrate the user's Pebble smartwatch to get their attention.",
        "required": [:],
        "optional": [
            "pattern": ["type": "string", "description": "short, long or double. Default short."],
        ],
    ],
]

/// Thread-safe holder for the turn being followed, shared by the event reader and the poller.
actor TurnBox {
    var turn: MuseTurn
    var firstStatusAt: ContinuousClock.Instant?
    var firstTextAt: ContinuousClock.Instant?
    var printed: [String: Int] = [:]

    init(_ turn: MuseTurn) { self.turn = turn }

    func apply(_ events: [MuseTurn.Event]) {
        for event in events {
            switch event {
            case .status(let status):
                if firstStatusAt == nil { firstStatusAt = .now }
                say("status: \(status.activityCode ?? "-")\(status.activityText.map { " — \($0)" } ?? "")")
            case .reply(let reply):
                // Print only what's new since the last delta of this message.
                let shown = printed[reply.messageID] ?? 0
                if reply.streamed.count > shown {
                    if firstTextAt == nil { firstTextAt = .now }
                    let delta = String(reply.streamed.dropFirst(shown))
                    print(delta, terminator: "")
                    fflush(stdout)
                    printed[reply.messageID] = reply.streamed.count
                }
                if reply.done {
                    if firstTextAt == nil, !reply.text.isEmpty { firstTextAt = .now }
                    print("")
                    say("reply \(reply.messageID) done\(reply.bound ? "" : " (unbound)"): \(reply.text)")
                }
            case .taskFinished:
                say("task finished")
            }
        }
    }

    func feed(_ event: MuseJSON) throws {
        apply(try turn.feed(event))
    }

    func acknowledge(_ response: MuseJSON?) throws {
        apply(try turn.acknowledge(response))
    }

    func isComplete() -> Bool { turn.isComplete() }
}

func turn(message: String, sessionID: String?, register: Bool, voicePath: String?, rawEvents: Bool) async throws {
    let clock = ContinuousClock()
    let started = clock.now
    func elapsed() -> String { "\((clock.now - started).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))" }

    var credentials = try await freshCredentials()
    var vms: [MuseVM]
    do {
        vms = try await api.fetchVMs(accessToken: credentials.accessToken, apiRoot: credentials.apiRoot)
    } catch .http(401) {
        say("device token rejected; rotating")
        credentials = try await freshCredentials(force: true)
        vms = try await api.fetchVMs(accessToken: credentials.accessToken, apiRoot: credentials.apiRoot)
    }
    guard let vm = vms.first(where: \.isDefault) ?? vms.first else { fail("No VM leased to this gadget.") }
    say("VM \(vm.vmName.isEmpty ? vm.vmID : vm.vmName) (fetched in \(elapsed()))")

    let device = MuseLinkSession.Device(
        nodeID: credentials.identity.nodeID, displayName: "Pebble watch (muse-dev)", version: "0.1.0",
        commands: watchCommands)
    let session = try MuseLinkSession(
        noiseHost: credentials.noiseHost, vmID: vm.linkVMID, vmAuthToken: vm.vmAuthToken,
        device: register ? device : nil,
        commandHandler: { command, params, _ in
            say("Muse called \(command) \(params.compactString())")
            return ["ok": true, "payload": ["shown": true]]
        },
        trace: { say("link: \($0)") })
    try await session.connect()
    say("connected in \(elapsed())")
    if register {
        try await session.waitUntilRegistered()
        say("registered in \(elapsed())")
    }

    let events = try await session.subscribeChat(sessionID: sessionID)
    let box = TurnBox(MuseTurn(sessionID: sessionID))
    let reader = Task {
        do {
            for try await event in events {
                if rawEvents { say("event: \(event.compactString())") }
                try await box.feed(event)
            }
        } catch {
            say("event stream ended: \(error)")
        }
    }

    let ack: MuseLinkSession.ChatAck
    if let voicePath {
        let wav = try Data(contentsOf: URL(fileURLWithPath: voicePath))
        ack = try await session.sendVoice(wav: wav, sessionID: sessionID, message: message)
    } else {
        ack = try await session.sendChat(message, sessionID: sessionID)
    }
    say("acknowledged in \(elapsed()): HTTP \(ack.status) \(ack.response?.compactString() ?? "")")
    guard ack.ok else {
        await session.close()
        fail("Muse refused the message.")
    }
    try await box.acknowledge(ack.response)

    let deadline = clock.now + .seconds(180)
    while !(await box.isComplete()) && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(200))
    }
    reader.cancel()
    let first = await box.firstStatusAt.map { "\(($0 - started).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))" } ?? "—"
    let text = await box.firstTextAt.map { "\(($0 - started).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))" } ?? "—"
    say("done in \(elapsed()); first status \(first), first text \(text)")
    if !(await box.isComplete()) { say("(gave up waiting after 180 s)") }
    await session.close()
}

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

do {
    switch arguments.first {
    case "pair": try await pair(force: arguments.contains("--force"))
    case "status": try await status()
    case "refresh": _ = try await freshCredentials(force: true)
    case "turn":
        let flagsWithValues: Set<String> = ["--session-id", "--voice"]
        var words: [String] = []
        var skip = false
        for argument in arguments.dropFirst() {
            if skip { skip = false; continue }
            if flagsWithValues.contains(argument) { skip = true; continue }
            if argument.hasPrefix("--") { continue }
            words.append(argument)
        }
        let message = words.joined(separator: " ")
        guard !message.isEmpty || value(after: "--voice") != nil else {
            fail("usage: muse-dev turn \"message\" [--session-id ID] [--register] [--voice file.wav] [--raw]")
        }
        try await turn(
            message: message, sessionID: value(after: "--session-id"), register: arguments.contains("--register"),
            voicePath: value(after: "--voice"), rawEvents: arguments.contains("--raw"))
    default:
        print("""
            usage: muse-dev pair [--force]
                   muse-dev status
                   muse-dev refresh
                   muse-dev turn "message" [--session-id ID] [--register] [--voice file.wav] [--raw]
            """)
        exit(2)
    }
} catch {
    fail("\(error)")
}
