namespace PebbleAudio.Server.Data;

/// <summary>
/// A bearer token for an assistant or command-line tool (<c>pat_…</c>), created and revoked in the admin area.
/// Only its SHA-256 hash is stored.
/// </summary>
public sealed class ApiToken
{
	public Guid Id { get; set; }

	public Guid UserId { get; set; }

	/// <summary>What the person called it, for example <c>Claude Code on the Mac</c>.</summary>
	public string Name { get; set; } = "";

	public TokenAccess Access { get; set; }

	public byte[] TokenHash { get; set; } = [];

	/// <summary>The first characters of the token, so the person can tell tokens apart.</summary>
	public string Preview { get; set; } = "";

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset? LastUsedAt { get; set; }

	public DateTimeOffset? RevokedAt { get; set; }
}
