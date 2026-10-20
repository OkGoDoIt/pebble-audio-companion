using System.Buffers.Binary;
using System.Buffers.Text;
using System.Formats.Cbor;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// A minimal WebAuthn authenticator (ES256, "none" attestation, user present and verified) so the passkey
/// ceremonies can run against the real Identity handlers without a browser.
/// </summary>
internal sealed class SoftwarePasskey : IDisposable
{
	private const byte UserPresent = 0x01;
	private const byte UserVerified = 0x04;
	private const byte AttestedCredentialData = 0x40;

	private readonly ECDsa _key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
	private readonly byte[] _credentialId = RandomNumberGenerator.GetBytes(16);
	private string? _userHandle;

	/// <summary>
	/// Answers <c>navigator.credentials.create()</c> for the server's creation options.
	/// </summary>
	public string Create(string optionsJson, string origin)
	{
		using var options = JsonDocument.Parse(optionsJson);
		var root = options.RootElement;
		var challenge = root.GetProperty("challenge").GetString()!;
		var rpId = root.GetProperty("rp").GetProperty("id").GetString()!;
		_userHandle = root.GetProperty("user").GetProperty("id").GetString()!;

		var clientData = ClientData("webauthn.create", challenge, origin);
		var parameters = _key.ExportParameters(includePrivateParameters: false);

		var coseKey = new CborWriter(CborConformanceMode.Ctap2Canonical);
		coseKey.WriteStartMap(5);
		coseKey.WriteInt32(1);
		coseKey.WriteInt32(2); // kty: EC2
		coseKey.WriteInt32(3);
		coseKey.WriteInt32(-7); // alg: ES256
		coseKey.WriteInt32(-1);
		coseKey.WriteInt32(1); // crv: P-256
		coseKey.WriteInt32(-2);
		coseKey.WriteByteString(parameters.Q.X!);
		coseKey.WriteInt32(-3);
		coseKey.WriteByteString(parameters.Q.Y!);
		coseKey.WriteEndMap();

		var credentialIdLength = new byte[2];
		BinaryPrimitives.WriteUInt16BigEndian(credentialIdLength, (ushort)_credentialId.Length);
		byte[] authenticatorData =
		[
			.. AuthenticatorDataPrefix(rpId, UserPresent | UserVerified | AttestedCredentialData),
			.. new byte[16], // AAGUID
			.. credentialIdLength,
			.. _credentialId,
			.. coseKey.Encode(),
		];

		var attestation = new CborWriter(CborConformanceMode.Ctap2Canonical);
		attestation.WriteStartMap(3);
		attestation.WriteTextString("fmt");
		attestation.WriteTextString("none");
		attestation.WriteTextString("attStmt");
		attestation.WriteStartMap(0);
		attestation.WriteEndMap();
		attestation.WriteTextString("authData");
		attestation.WriteByteString(authenticatorData);
		attestation.WriteEndMap();

		return JsonSerializer.Serialize(new
		{
			id = Base64Url.EncodeToString(_credentialId),
			rawId = Base64Url.EncodeToString(_credentialId),
			type = "public-key",
			clientExtensionResults = new { },
			response = new
			{
				clientDataJSON = Base64Url.EncodeToString(clientData),
				attestationObject = Base64Url.EncodeToString(attestation.Encode()),
				transports = new[] { "internal" },
			},
		});
	}

	/// <summary>
	/// Answers <c>navigator.credentials.get()</c> for the server's request options.
	/// </summary>
	public string Get(string optionsJson, string origin)
	{
		using var options = JsonDocument.Parse(optionsJson);
		var root = options.RootElement;
		var challenge = root.GetProperty("challenge").GetString()!;
		var rpId = root.GetProperty("rpId").GetString()!;

		var clientData = ClientData("webauthn.get", challenge, origin);
		var authenticatorData = AuthenticatorDataPrefix(rpId, UserPresent | UserVerified);
		byte[] signed = [.. authenticatorData, .. SHA256.HashData(clientData)];
		var signature = _key.SignData(signed, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);

		return JsonSerializer.Serialize(new
		{
			id = Base64Url.EncodeToString(_credentialId),
			rawId = Base64Url.EncodeToString(_credentialId),
			type = "public-key",
			clientExtensionResults = new { },
			response = new
			{
				clientDataJSON = Base64Url.EncodeToString(clientData),
				authenticatorData = Base64Url.EncodeToString(authenticatorData),
				signature = Base64Url.EncodeToString(signature),
				userHandle = _userHandle,
			},
		});
	}

	public void Dispose() => _key.Dispose();

	private static byte[] ClientData(string type, string challenge, string origin) =>
		JsonSerializer.SerializeToUtf8Bytes(new { type, challenge, origin, crossOrigin = false });

	private static byte[] AuthenticatorDataPrefix(string rpId, int flags)
	{
		// rpIdHash, flags, and a zero signature counter (authenticators that do not count send zero).
		return [.. SHA256.HashData(Encoding.UTF8.GetBytes(rpId)), (byte)flags, 0, 0, 0, 0];
	}
}
