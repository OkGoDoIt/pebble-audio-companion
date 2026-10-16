import Foundation
import MuseLink

/// The developer gadget's state, in `~/.config/muse-gadget/`, in the same file shapes Meta's
/// Linux gadget uses (`identity.json`, `pairing.json`, `sdk_token`), so a pairing made here can be
/// inspected with the stock tools and later imported into the app. Files are created 0600 and the
/// tokens in them are never printed.
struct GadgetStore {
    let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/muse-gadget", directoryHint: .isDirectory))
    {
        self.directory = directory
    }

    var sdkTokenURL: URL { directory.appending(path: "sdk_token") }
    var identityURL: URL { directory.appending(path: "identity.json") }
    var pairingURL: URL { directory.appending(path: "pairing.json") }

    enum Problem: Error, CustomStringConvertible {
        case missingSDKToken(URL)
        case malformedSDKToken
        case notPaired

        var description: String {
            switch self {
            case .missingSDKToken(let url):
                "No SDK token at \(url.path). Create one at https://gadgets.muse.ai/settings/sdk-tokens, copy it, then run:\n"
                    + "  mkdir -p ~/.config/muse-gadget && pbpaste | tr -d '[:space:]' > ~/.config/muse-gadget/sdk_token && chmod 600 ~/.config/muse-gadget/sdk_token"
            case .malformedSDKToken:
                "The SDK token file doesn't hold an mgst_… token."
            case .notPaired:
                "Not paired yet. Run `muse-dev pair` first."
            }
        }
    }

    func sdkToken() throws -> String {
        guard let raw = try? String(contentsOf: sdkTokenURL, encoding: .utf8) else {
            throw Problem.missingSDKToken(sdkTokenURL)
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("mgst_"), token.count > 8, !token.contains(where: \.isWhitespace) else {
            throw Problem.malformedSDKToken
        }
        return token
    }

    func loadOrCreateIdentity() throws -> MuseGadgetIdentity {
        if let data = try? Data(contentsOf: identityURL),
            let identity = try? JSONDecoder().decode(MuseGadgetIdentity.self, from: data)
        {
            return identity
        }
        let identity = MuseGadgetIdentity.generate()
        try write(MuseJSON.object(["mac": .string(identity.mac)]).compactData(), to: identityURL)
        return identity
    }

    func loadCredentials() throws -> MuseGadgetCredentials {
        guard let identityData = try? Data(contentsOf: identityURL),
            let identity = try? JSONDecoder().decode(MuseGadgetIdentity.self, from: identityData),
            let record = (try? Data(contentsOf: pairingURL)).flatMap(MuseJSON.parse),
            let credentials = MuseGadgetCredentials(identity: identity, linuxPairing: record)
        else { throw Problem.notPaired }
        return credentials
    }

    func save(_ credentials: MuseGadgetCredentials) throws {
        try write(credentials.linuxPairingJSON().compactData(), to: pairingURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
