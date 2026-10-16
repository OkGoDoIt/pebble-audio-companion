import Foundation

extension MuseGadgetCredentials {
    /// The record in Meta's Linux gadget `pairing.json` shape, so a pairing can move between this
    /// code and the stock Linux SDK (`linux/src/musegadget/pair.py`, `_verify_and_save`).
    public func linuxPairingJSON() -> MuseJSON {
        [
            "access_token": .string(accessToken),
            "refresh_token": .string(refreshToken),
            "token_type": "device",
            "username": .string(username),
            "api_url": .string(apiURL),
            "api_url_v2": .string(apiURLv2),
            "noise_host": .string(noiseHost),
            "access_token_saved_at": .number(accessTokenSavedAt.timeIntervalSince1970.rounded(.down)),
        ]
    }

    /// Reads a Linux gadget `pairing.json` (with the `identity.json` it belongs to).
    public init?(identity: MuseGadgetIdentity, linuxPairing record: MuseJSON) {
        guard let access = record["access_token"]?.string, !access.isEmpty,
            let refresh = record["refresh_token"]?.string, !refresh.isEmpty
        else { return nil }
        self.init(
            identity: identity, accessToken: access, refreshToken: refresh,
            username: record["username"]?.string ?? "", apiURL: record["api_url"]?.string ?? "",
            apiURLv2: record["api_url_v2"]?.string ?? "", noiseHost: record["noise_host"]?.string ?? "",
            accessTokenSavedAt: Date(timeIntervalSince1970: record["access_token_saved_at"]?.number ?? 0))
    }

    /// The access token is due for rotation (Meta's Linux gadget rotates at three hours).
    public func isRefreshDue(now: Date = Date()) -> Bool {
        now.timeIntervalSince(accessTokenSavedAt) >= MuseDeviceAPI.tokenRefreshAge
    }

    public func rotated(to tokens: MuseDeviceAPI.Tokens, at now: Date = Date()) -> MuseGadgetCredentials {
        var copy = self
        copy.accessToken = tokens.accessToken
        copy.refreshToken = tokens.refreshToken
        copy.accessTokenSavedAt = now
        return copy
    }
}
