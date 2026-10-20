namespace PebbleAudio.Server.Data;

/// <summary>
/// The columns every row mirrored from the phone carries (sync-protocol.md §2). Each such entity is keyed by
/// <c>(UserId, its id)</c>, so rows are always scoped to their user.
/// </summary>
public abstract class SyncedRecord
{
	public Guid UserId { get; set; }

	/// <summary>
	/// The phone's version of the entity (its <c>updatedAtMs</c>). It only increases; a batch item with a lower
	/// or equal version is ignored.
	/// </summary>
	public long Version { get; set; }

	/// <summary>
	/// When the phone says the entity last changed.
	/// </summary>
	public DateTimeOffset ChangedAt { get; set; }

	/// <summary>
	/// When the server applied this version.
	/// </summary>
	public DateTimeOffset ReceivedAt { get; set; }

	/// <summary>
	/// When the phone's retention aged the entity out (op <c>expire</c>). The server keeps the row.
	/// </summary>
	public DateTimeOffset? ExpiredOnPhoneAt { get; set; }
}
