namespace PebbleAudio.Server.Data;

/// <summary>
/// An opaque OAuth access token (<c>oat_…</c>) or refresh token (<c>ort_…</c>). Only its SHA-256 hash is stored.
/// </summary>
public sealed class OAuthToken
{
	public Guid Id { get; set; }

	public Guid GrantId { get; set; }

	public OAuthGrant Grant { get; set; } = null!;

	public OAuthTokenKind Kind { get; set; }

	public byte[] TokenHash { get; set; } = [];

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset ExpiresAt { get; set; }

	/// <summary>
	/// When a refresh token was exchanged for a new one. Presenting it again after the short race allowance
	/// disconnects the grant.
	/// </summary>
	public DateTimeOffset? UsedAt { get; set; }
}
