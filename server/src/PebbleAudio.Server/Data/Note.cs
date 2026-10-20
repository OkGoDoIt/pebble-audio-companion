namespace PebbleAudio.Server.Data;

/// <summary>
/// A note, usually about one conversation (sync-protocol.md §2.6).
/// </summary>
public sealed class Note : SyncedRecord
{
	public string Id { get; set; } = "";

	public string? ConversationId { get; set; }

	public string? TemplateId { get; set; }

	public string? Title { get; set; }

	public string Body { get; set; } = "";

	public List<NoteCitation> Citations { get; set; } = [];

	public ContentOrigin Origin { get; set; }

	public string? Provider { get; set; }

	public string? Model { get; set; }

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset? EditedAt { get; set; }
}
