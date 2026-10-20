namespace PebbleAudio.Server.Data;

/// <summary>
/// One connection: the person allowed an app, and the app exchanged the code. Every token issued from that code
/// (the refresh-token family) belongs to it, so deleting the grant disconnects the app at once.
/// </summary>
public sealed class OAuthGrant
{
	public Guid Id { get; set; }

	public Guid UserId { get; set; }

	public Guid OAuthClientId { get; set; }

	public OAuthClient Client { get; set; } = null!;

	/// <summary>The granted scopes, for example <c>archive:read</c> and <c>archive:write</c>.</summary>
	public List<string> Scopes { get; set; } = [];

	/// <summary>The resource (RFC 8707) the tokens are for: their audience, always the server's <c>/mcp</c> URL.</summary>
	public string Resource { get; set; } = "";

	/// <summary>The redirect URI the sign-in used, so the admin area can show where the app lives.</summary>
	public string RedirectUri { get; set; } = "";

	public DateTimeOffset CreatedAt { get; set; }

	/// <summary>When an access token from this grant last opened <c>/mcp</c>, noted at most once a minute.</summary>
	public DateTimeOffset? LastUsedAt { get; set; }

	/// <summary>
	/// When the newest refresh token runs out. Each refresh moves it on (sliding); past it the app has to sign in
	/// again and the grant no longer counts as connected.
	/// </summary>
	public DateTimeOffset ExpiresAt { get; set; }

	public List<OAuthToken> Tokens { get; set; } = [];
}
