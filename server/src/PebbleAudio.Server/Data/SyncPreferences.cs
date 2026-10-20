namespace PebbleAudio.Server.Data;

/// <summary>
/// What the person allowed on the phone (sync-protocol.md §5, <c>PUT /sync/preferences</c>): whether assistants
/// may ask for audio clips, and whether they may add follow-ups and notes. One row per user; no row means both
/// are off.
/// </summary>
public sealed class SyncPreferences
{
	public Guid UserId { get; set; }

	/// <summary>Assistants may ask the phone for audio clips.</summary>
	public bool Clips { get; set; }

	/// <summary>Assistants may add and change follow-ups and notes.</summary>
	public bool Edits { get; set; }

	public DateTimeOffset UpdatedAt { get; set; }

	/// <summary>The phone that set them last.</summary>
	public Guid? DeviceId { get; set; }
}
