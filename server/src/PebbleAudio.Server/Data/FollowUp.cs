namespace PebbleAudio.Server.Data;

/// <summary>
/// A follow-up or a reminder (sync-protocol.md §2.5, docs/reminders.md): something the app noticed in a conversation
/// that the person might act on (<see cref="FollowUpStage.Suggested"/>), one they said yes to or asked for
/// (<see cref="FollowUpStage.Reminder"/>), or one they said no to (<see cref="FollowUpStage.Skipped"/>).
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

	/// <summary>A phone from before stages sends none, and every row from before them is a reminder.</summary>
	public FollowUpStage Stage { get; set; } = FollowUpStage.Reminder;

	/// <summary>Cleared when the source conversation is deleted; the follow-up keeps its text.</summary>
	public string? SourceConversationId { get; set; }

	public DateTimeOffset? SourceAt { get; set; }

	public DateTimeOffset? SourceEndAt { get; set; }

	public bool SourceApproximate { get; set; }

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset? EditedAt { get; set; }
}
