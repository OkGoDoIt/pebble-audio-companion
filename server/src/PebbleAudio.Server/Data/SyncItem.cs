namespace PebbleAudio.Server.Data;

/// <summary>
/// The ledger of the highest version the server has applied for each <c>(kind, id)</c>. It outlives deletes,
/// so a replayed upsert older than a delete stays ignored.
/// </summary>
public sealed class SyncItem
{
	public Guid UserId { get; set; }

	public SyncKind Kind { get; set; }

	public string EntityId { get; set; } = "";

	public long Version { get; set; }

	public SyncOp Op { get; set; }

	public DateTimeOffset AppliedAt { get; set; }

	/// <summary>The phone that sent it.</summary>
	public Guid? DeviceId { get; set; }
}
