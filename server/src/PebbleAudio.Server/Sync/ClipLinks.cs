using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Signed, short-lived links to a ready clip: <c>/clips/{clipId}.m4a?exp=…&amp;sig=…</c>. The signature is a Data
/// Protection payload over the clip id and the expiry (authenticated with HMAC-SHA256 under the app's persisted
/// key ring), so there is no extra secret to configure and a link survives restarts and key rotation for as long
/// as it lives. Anyone holding a live link can play that one clip; nothing else.
/// </summary>
public sealed class ClipLinks(
	IDataProtectionProvider dataProtection,
	IOptions<PebbleAudioOptions> options,
	SettingsService settings,
	TimeProvider time)
{
	private const string Purpose = "PebbleAudio.Sync.ClipLinks.v1";

	private readonly IDataProtector _protector = dataProtection.CreateProtector(Purpose);

	/// <summary>A link that works for the <c>ClipLinkMinutes</c> setting.</summary>
	public async Task<ClipLink> CreateAsync(Guid clipId, CancellationToken cancellationToken)
	{
		var lifetime = (await settings.GetAsync(cancellationToken)).ClipLinkLifetime;
		return Create(clipId, time.GetUtcNow() + lifetime);
	}

	public ClipLink Create(Guid clipId, DateTimeOffset expiresAt)
	{
		var exp = expiresAt.ToUnixTimeSeconds();
		var signature = WebEncoders.Base64UrlEncode(_protector.Protect(Signed(clipId, exp)));
		var url = $"{options.Value.PublicOrigin}/clips/{clipId:N}.m4a?exp={exp.ToString(CultureInfo.InvariantCulture)}&sig={signature}";
		return new ClipLink(url, DateTimeOffset.FromUnixTimeSeconds(exp));
	}

	/// <summary>True when <paramref name="signature"/> was made by <see cref="Create"/> for this clip and expiry, and the
	/// expiry has not passed.</summary>
	public bool Verify(Guid clipId, string? exp, string? signature)
	{
		if (!long.TryParse(exp, NumberStyles.None, CultureInfo.InvariantCulture, out var expires) ||
			string.IsNullOrEmpty(signature) ||
			expires <= time.GetUtcNow().ToUnixTimeSeconds())
		{
			return false;
		}

		try
		{
			var unprotected = _protector.Unprotect(WebEncoders.Base64UrlDecode(signature));
			return CryptographicOperations.FixedTimeEquals(unprotected, Signed(clipId, expires));
		}
		catch (Exception ex) when (ex is CryptographicException or FormatException)
		{
			return false;
		}
	}

	private static byte[] Signed(Guid clipId, long exp) =>
		Encoding.UTF8.GetBytes($"{clipId:N}.{exp.ToString(CultureInfo.InvariantCulture)}");
}

/// <param name="Url">The absolute link, ready to hand to an assistant or a widget.</param>
/// <param name="ExpiresAt">When it stops working.</param>
public sealed record ClipLink(string Url, DateTimeOffset ExpiresAt);
