import Foundation

/// One VM leased to the account, from `/fetch_vms`. Each lookup also mints a fresh `vmAuthToken`,
/// the bearer for the Noise link.
public struct MuseVM: Sendable, Equatable {
    public let vmURL: String
    public let vmAuthToken: String
    public let vmName: String
    public let vmID: String
    public let isDefault: Bool

    /// What the link's `?vm_id=` carries: the id, or the name when the API gave no id.
    public var linkVMID: String { vmID.isEmpty ? vmName : vmID }
}

/// The Muse device API, as a gadget uses it — a port of Meta's `linux/src/musegadget/muse_api.py`
/// (Apache-2.0): the leased-VM lookup and device-token rotation.
public struct MuseDeviceAPI: Sendable {
    public static let defaultAPIRoot = URL(string: "https://api.muse.ai")!
    public static let defaultNoiseHost = "hatch.metaaivm.com"
    /// Device access tokens live about four hours; Meta's Linux gadget rotates at three.
    public static let tokenRefreshAge: TimeInterval = 3 * 3600

    public enum Failure: Error, Equatable, Sendable {
        /// The server answered with this HTTP status. 401 on refresh means the pairing is gone.
        case http(Int)
        /// The server answered 200 with an error body or without the expected fields.
        case badResponse(String)
        /// No HTTP response at all (worth retrying).
        case transport(String)
    }

    public struct Tokens: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String
    }

    let session: URLSession
    let userAgent: String

    public init(session: URLSession = .shared, userAgent: String = MuseDeviceAPI.defaultUserAgent) {
        self.session = session
        self.userAgent = userAgent
    }

    /// Honest about what this is; Meta's gadgets send `musegadget/<version> (...)`.
    public static let defaultUserAgent = "PebbleAudioMuseLink/0.1 (Pebble watch companion)"

    /// The root API paths are appended to: `api_url_v2`, or the Muse API. `api_url` is ignored
    /// (only older firmware reads it).
    public static func apiRoot(apiURLv2: String) -> URL {
        guard apiURLv2.hasPrefix("https://"), let url = URL(string: apiURLv2.trimmingTrailingSlashes) else {
            return defaultAPIRoot
        }
        return url
    }

    /// Leased VMs for the device token.
    public func fetchVMs(accessToken: String, apiRoot: URL = MuseDeviceAPI.defaultAPIRoot) async throws(Failure) -> [MuseVM] {
        var request = URLRequest(url: apiRoot.appending(path: "fetch_vms"), timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "X-API-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body = try await perform(request)
        guard let object = MuseJSON.parse(body)?.object else { throw .badResponse("not a JSON object") }
        if object["error_title"]?.string?.isEmpty == false || object["backend_error_code"] != nil {
            throw .badResponse("\(object["error_title"]?.string ?? "") \(object["backend_error_code"].map { $0.compactString() } ?? "")")
        }
        guard let list = object["vm_list"]?.array else { throw .badResponse("missing vm_list") }
        return list.compactMap { entry -> MuseVM? in
            guard let url = entry["vm_ws_url"]?.string ?? entry["vm_url"]?.string, !url.isEmpty,
                let token = entry["vm_auth_token"]?.string, !token.isEmpty
            else { return nil }
            return MuseVM(
                vmURL: url, vmAuthToken: token, vmName: entry["vm_name"]?.string ?? "",
                vmID: entry["vm_id"]?.string ?? "", isDefault: entry["default"]?.bool ?? false)
        }
    }

    /// Rotates the device token pair with the refresh token.
    ///
    /// Only the refresh leg is ever presented, as `hatch_refresh:<raw>`: per Meta's gadget, the
    /// server can accept the *access* token here and answer 200 with replacement tokens that every
    /// endpoint then rejects, which would overwrite working credentials.
    public func refreshDeviceToken(
        refreshToken: String, nodeID: String, sdkToken: String?, apiRoot: URL = MuseDeviceAPI.defaultAPIRoot
    ) async throws(Failure) -> Tokens {
        // Apps hand over refresh tokens that may already carry the prefix; doubling it is rejected.
        let raw = refreshToken.split(separator: ":").last.map(String.init) ?? refreshToken
        var body: [String: MuseJSON] = ["device_id": .string(nodeID)]
        if let sdkToken, !sdkToken.isEmpty { body["sdk_token"] = .string(sdkToken) }
        var request = URLRequest(url: apiRoot.appending(path: "device_token/refresh"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = MuseJSON.object(body).compactData()
        request.setValue("Bearer hatch_refresh:\(raw)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await perform(request)
        var parsed = MuseJSON.parse(data)
        if let payload = parsed?["payload"], payload.object != nil { parsed = payload }
        guard let access = parsed?["access_token"]?.string, !access.isEmpty,
            let refresh = parsed?["refresh_token"]?.string, !refresh.isEmpty
        else { throw .badResponse("refresh response missing tokens") }
        return Tokens(accessToken: access, refreshToken: refresh)
    }

    private func perform(_ request: URLRequest) async throws(Failure) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .transport("not HTTP") }
        guard (200..<300).contains(http.statusCode) else { throw .http(http.statusCode) }
        return data
    }
}

extension String {
    fileprivate var trimmingTrailingSlashes: String {
        var text = self
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
