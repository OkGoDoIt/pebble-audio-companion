namespace PebbleAudio.Server.Data;

/// <summary>
/// A linked phone. Its device token (<c>pad_…</c>) is stored only as a SHA-256 hash.
/// </summary>
public sealed class Device
{
	public Guid Id { get; set; }

	public Guid UserId { get; set; }

	public string Name { get; set; } = "";

	public string? AppVersion { get; set; }

	public string? AppBuild { get; set; }

	public byte[] TokenHash { get; set; } = [];

	public DateTimeOffset LinkedAt { get; set; }

	public DateTimeOffset? LastSeenAt { get; set; }

	public DateTimeOffset? LastBatchAt { get; set; }

	/// <summary>Set by <c>DELETE /link</c>: the token is revoked and the data stays.</summary>
	public DateTimeOffset? UnlinkedAt { get; set; }
}
