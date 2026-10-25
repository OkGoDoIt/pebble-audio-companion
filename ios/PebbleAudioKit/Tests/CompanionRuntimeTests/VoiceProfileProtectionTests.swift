import CompanionRuntime
import CryptoKit
import Foundation
import Testing

@Suite struct VoiceProfileProtectionTests {
    @Test func databaseEnvelopeHasNoPlaintextAndUsesRandomNonces() throws {
        let cipher = VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256))
        let original = Data("{\"voice_vector\":[0.12345,0.67890]}".utf8)
        let first = try cipher.seal(original), second = try cipher.seal(original)
        #expect(first != second)
        #expect(String(decoding: first, as: UTF8.self).contains("voice_vector") == false)
        #expect(try cipher.open(first) == original)
        #expect(try cipher.open(second) == original)
        #expect(try JSONSerialization.jsonObject(with: first) is [String: Any])
    }
    @Test func anotherDevicesKeyAndChangedCiphertextCannotReadTheSample() throws {
        let cipher = VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256))
        let another = VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256))
        let sealed = try cipher.seal(Data("private vector".utf8))
        #expect(throws: VoiceProfileProtectionError.invalidEnvelope) { try another.open(sealed) }
        var json = try #require(JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        let ciphertext = try #require(json["ciphertext"] as? String)
        var bytes = try #require(Data(base64Encoded: ciphertext))
        bytes[bytes.count - 1] ^= 1
        json["ciphertext"] = bytes.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: VoiceProfileProtectionError.invalidEnvelope) { try cipher.open(tampered) }
    }
    @Test func plainVectorsAndUnknownEnvelopeVersionsAreRejected() throws {
        let cipher = VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256))
        #expect(throws: VoiceProfileProtectionError.invalidEnvelope) { try cipher.open(Data("{\"values\":[1,2]}".utf8)) }
        var json = try #require(JSONSerialization.jsonObject(with: cipher.seal(Data("vector".utf8))) as? [String: Any])
        json["version"] = 999
        #expect(throws: VoiceProfileProtectionError.invalidEnvelope) { try cipher.open(JSONSerialization.data(withJSONObject: json)) }
    }
}
