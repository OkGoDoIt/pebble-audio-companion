namespace PebbleAudio.Server.Data;

/// <summary>
/// A one-time authorization code, bound to everything the sign-in agreed on. Only its SHA-256 hash is stored.
/// </summary>
public sealed class OAuthAuthorizationCode
{
	public Guid Id { get; set; }

	public byte[] CodeHash { get; set; } = [];

	public Guid OAuthClientId { get; set; }

	public Guid UserId { get; set; }

	/// <summary>The redirect URI exactly as the authorization request sent it; the token request must repeat it.</summary>
	public string RedirectUri { get; set; } = "";

	/// <summary>The PKCE S256 challenge.</summary>
	public string CodeChallenge { get; set; } = "";

	public List<string> Scopes { get; set; } = [];

	public string Resource { get; set; } = "";

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset ExpiresAt { get; set; }

	public DateTimeOffset? RedeemedAt { get; set; }

	/// <summary>The grant the code was exchanged for. A second exchange of the same code deletes it.</summary>
	public Guid? GrantId { get; set; }
}
