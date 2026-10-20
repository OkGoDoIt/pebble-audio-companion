namespace PebbleAudio.Server.Data;

/// <summary>
/// How one logical day was covered: recorded, quiet, missing, paused, or off (sync-protocol.md §2.7).
/// </summary>
public sealed class CoverageDay : SyncedRecord
{
	public DateOnly DayKey { get; set; }

	public string TimeZone { get; set; } = "";

	public List<CoverageSpan> Spans { get; set; } = [];

	public long RecordedMs { get; set; }

	public long QuietMs { get; set; }

	public long MissingMs { get; set; }
}
