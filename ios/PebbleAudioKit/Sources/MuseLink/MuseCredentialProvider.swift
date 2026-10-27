/// One owner of a gadget's rotating credentials, shared by chat, voice and message listening.
public protocol MuseCredentialProvider: Sendable {
    func current() async throws -> MuseGadgetCredentials
    /// Refresh only if these are still the current tokens. A concurrent caller may already have
    /// replaced them while the rejected request was in flight.
    func refresh(rejected: MuseGadgetCredentials) async throws -> MuseGadgetCredentials
    func rejected(_ credentials: MuseGadgetCredentials) async
}
