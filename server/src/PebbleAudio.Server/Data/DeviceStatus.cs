namespace PebbleAudio.Server.Data;

/// <summary>
/// The latest status a linked phone reported for its watch (sync-protocol.md §2.8, the <c>deviceStatus</c> kind): one
/// row per phone, replaced by every newer report. It is not archive content and has no sharing scope; the Pebble
/// plugin reads it (<c>GET /plugin/status</c>).
/// </summary>
public sealed class DeviceStatus
{
	/// <summary>The phone that reported it. The row goes with the phone.</summary>
	public Guid DeviceId { get; set; }

	public Guid UserId { get; set; }

	/// <summary>The batch item's version; a report at or below it is ignored.</summary>
	public long Version { get; set; }

	/// <summary>When the phone took the reading (its <c>updatedAtMs</c>).</summary>
	public DateTimeOffset UpdatedAt { get; set; }

	/// <summary>When the server stored it: what "stale" is measured from.</summary>
	public DateTimeOffset ReceivedAt { get; set; }

	public CaptureSetting Capture { get; set; }

	public WatchLink Link { get; set; }

	/// <summary>Whether audio is being recorded right now.</summary>
	public bool Recording { get; set; }

	/// <summary>When the newest audio from the watch arrived on the phone.</summary>
	public DateTimeOffset? LastAudioAt { get; set; }

	public int? WatchBatteryPercent { get; set; }

	public string? WatchFirmware { get; set; }

	public int? TodayRecordedMinutes { get; set; }

	public int? TodayQuietMinutes { get; set; }

	public int? TodayLostMinutes { get; set; }

	/// <summary>The audio the phone keeps, in bytes.</summary>
	public long? StorageUsedBytes { get; set; }

	public int? PhoneBatteryPercent { get; set; }
}
