namespace PebbleAudio.Server.Data;

/// <summary>
/// A one-time code the admin area shows for linking a phone (sync-protocol.md §1). Stored hashed.
/// </summary>
public sealed class LinkCode
{
	public Guid Id { get; set; }

	public Guid UserId { get; set; }

	public byte[] CodeHash { get; set; } = [];

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset ExpiresAt { get; set; }

	public DateTimeOffset? UsedAt { get; set; }

	/// <summary>The phone the code linked.</summary>
	public Guid? DeviceId { get; set; }
}
