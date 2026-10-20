namespace PebbleAudio.Server.Data;

/// <summary>
/// A weekly or monthly brief (sync-protocol.md §2.4).
/// </summary>
public sealed class Brief : SyncedRecord
{
	/// <summary><c>week:2026-10-11</c> or <c>month:2026-10</c>.</summary>
	public string PeriodKey { get; set; } = "";

	public BriefKind Kind { get; set; }

	public DateOnly StartDay { get; set; }

	public DateOnly EndDay { get; set; }

	public string? Headline { get; set; }

	public string? LineSummary { get; set; }

	public string? Text { get; set; }

	public string? Provider { get; set; }

	public string? Model { get; set; }
}
