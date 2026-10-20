using System.Security.Cryptography;
using System.Text;

namespace PebbleAudio.Server.Events;

/// <summary>
/// Standard Webhooks symmetric signatures (https://www.standardwebhooks.com, "v1"): the secret is <c>whsec_</c> and
/// base64 of 24 to 64 bytes, and a signature is <c>v1,</c> and base64 of HMAC-SHA256 over
/// <c>{webhook-id}.{webhook-timestamp}.{body}</c>, signed over exactly the bytes that are sent.
/// </summary>
public static class StandardWebhooks
{
	public const string SecretPrefix = "whsec_";

	public const string IdHeader = "webhook-id";

	public const string TimestampHeader = "webhook-timestamp";

	public const string SignatureHeader = "webhook-signature";

	/// <summary>The key bytes of a <c>whsec_</c> secret, or null when it is malformed or not 24 to 64 bytes.</summary>
	public static byte[]? ParseSecret(string? secret)
	{
		if (secret is null || !secret.StartsWith(SecretPrefix, StringComparison.Ordinal))
		{
			return null;
		}

		var encoded = secret[SecretPrefix.Length..];
		var buffer = new byte[encoded.Length];
		return Convert.TryFromBase64String(encoded, buffer, out var length) && length is >= 24 and <= 64
			? buffer[..length]
			: null;
	}

	public static string Sign(byte[] key, string messageId, long timestamp, ReadOnlySpan<byte> body)
	{
		var prefix = Encoding.UTF8.GetBytes($"{messageId}.{timestamp}.");
		var signed = new byte[prefix.Length + body.Length];
		prefix.CopyTo(signed, 0);
		body.CopyTo(signed.AsSpan(prefix.Length));
		return "v1," + Convert.ToBase64String(HMACSHA256.HashData(key, signed));
	}

	/// <summary>The header value: one signature per key, space-separated, so a secret can rotate without a gap.</summary>
	public static string SignatureHeaderValue(IEnumerable<byte[]> keys, string messageId, long timestamp, ReadOnlySpan<byte> body)
	{
		var signatures = new List<string>();
		foreach (var key in keys)
		{
			signatures.Add(Sign(key, messageId, timestamp, body));
		}

		return string.Join(' ', signatures);
	}
}
