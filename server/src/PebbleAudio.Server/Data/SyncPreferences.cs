namespace PebbleAudio.Server.Data;

/// <summary>
/// What the person allowed on the phone (sync-protocol.md §5, <c>PUT /sync/preferences</c>): whether assistants
/// may ask for audio clips, whether they may add follow-ups and notes, and which conversations the server may hold
/// at all (the sharing scope). One row per user; no row means clips and edits are off and the scope is
/// <see cref="SharingScopeKind.All"/>. The row survives a wipe and an unlink.
/// </summary>
public sealed class SyncPreferences
{
	public Guid UserId { get; set; }

	/// <summary>Assistants may ask the phone for audio clips.</summary>
	public bool Clips { get; set; }

	/// <summary>Assistants may add and change follow-ups and notes.</summary>
	public bool Edits { get; set; }

	public SharingScopeKind ScopeKind { get; set; }

	/// <summary>With <see cref="SharingScopeKind.Since"/>: nothing dated before this is held.</summary>
	public DateTimeOffset? ScopeSince { get; set; }

	/// <summary>With <see cref="SharingScopeKind.LastDays"/>: how many days back the window reaches.</summary>
	public int? ScopeDays { get; set; }

	/// <summary>
	/// The account's IANA time zone: the zone of the latest conversation the phone sent. The nightly scope deletion
	/// runs at 03:30 in it, and days without a conversation of their own ("today") are read in it. UTC when unset.
	/// </summary>
	public string? TimeZone { get; set; }

	/// <summary>The 03:30 whose scope deletion was last queued, so each night's runs once.</summary>
	public DateTimeOffset? ScopeSweptFor { get; set; }

	public DateTimeOffset UpdatedAt { get; set; }

	/// <summary>The phone that set them last.</summary>
	public Guid? DeviceId { get; set; }
}
