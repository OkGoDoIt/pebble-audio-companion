namespace PebbleAudio.Server.Data;

/// <summary>
/// Something to follow up on, from the app's AI, the person, or an assistant (sync-protocol.md §2.5).
/// </summary>
public sealed class FollowUp : SyncedRecord
{
	public string Id { get; set; } = "";

	public string Text { get; set; } = "";

	public string? Quote { get; set; }

	public string? Why { get; set; }

	public DateTimeOffset? DueAt { get; set; }

	public int Priority { get; set; }

	public bool Done { get; set; }

	public DateTimeOffset? CompletedAt { get; set; }

	public DateTimeOffset? ArchivedAt { get; set; }

	public DateTimeOffset? SnoozedUntil { get; set; }

	public ContentOrigin Origin { get; set; }

	/// <summary>Cleared when the source conversation is deleted; the follow-up keeps its text.</summary>
	public string? SourceConversationId { get; set; }

	public DateTimeOffset? SourceAt { get; set; }

	public DateTimeOffset? SourceEndAt { get; set; }

	public bool SourceApproximate { get; set; }

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset? EditedAt { get; set; }
}
