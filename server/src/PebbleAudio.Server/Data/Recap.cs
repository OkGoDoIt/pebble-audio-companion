namespace PebbleAudio.Server.Data;

/// <summary>
/// The app's recap of one logical day (sync-protocol.md §2.3).
/// </summary>
public sealed class Recap : SyncedRecord
{
	public DateOnly DayKey { get; set; }

	public string TimeZone { get; set; } = "";

	public string? Headline { get; set; }

	public string? LineSummary { get; set; }

	public string? ShortText { get; set; }

	public string? Text { get; set; }

	public List<string> ConversationIds { get; set; } = [];

	public string? Provider { get; set; }

	public string? Model { get; set; }
}
