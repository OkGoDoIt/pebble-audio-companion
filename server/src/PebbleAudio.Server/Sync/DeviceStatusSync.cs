using System.Text.Json;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// The <c>deviceStatus</c> batch kind (sync-protocol.md §2.8): what the phone last knew about its watch, one per
/// phone. It is kept apart from the archive's kinds: it is not dated content, so the sharing scope does not apply,
/// its version lives on its own row rather than in the archive's ledger, and only <c>upsert</c> makes sense for it.
/// </summary>
internal static class DeviceStatusSync
{
	public const string Kind = "deviceStatus";

	/// <summary>The longest firmware name kept; anything longer is cut.</summary>
	public const int FirmwareLength = 80;

	/// <summary>
	/// Reads the payload. The phone's fields are required as the contract marks them (<c>updatedAtMs</c>,
	/// <c>capture</c>, <c>link</c>, <c>recording</c>); a reading that cannot be right (a percentage outside 0 to 100, a
	/// negative count) is kept as unknown rather than costing the whole report. Numbers may arrive with a fraction.
	/// </summary>
	public static Parsed<DeviceStatus> Read(JsonElement payload)
	{
		if (payload.ValueKind != JsonValueKind.Object)
		{
			return Parsed<DeviceStatus>.Fail("payload: not an object");
		}

		Payload p;
		try
		{
			p = payload.Deserialize<Payload>(SyncJson.Options) ?? new Payload();
		}
		catch (JsonException ex)
		{
			var path = (ex.Path ?? "").TrimStart('$', '.');
			return Parsed<DeviceStatus>.Fail(path.Length > 0 ? $"payload: {path} has the wrong type" : "payload: not readable");
		}

		if (Instant(p.UpdatedAtMs) is not { } updatedAt)
		{
			return Parsed<DeviceStatus>.Fail("payload: updatedAtMs missing");
		}

		if (!WireNames.TryParse(p.Capture, out CaptureSetting capture))
		{
			return Unknown("capture", p.Capture);
		}

		if (!WireNames.TryParse(p.Link, out WatchLink link))
		{
			return Unknown("link", p.Link);
		}

		if (p.Recording is not { } recording)
		{
			return Parsed<DeviceStatus>.Fail("payload: recording missing");
		}

		var firmware = p.WatchFirmware?.Trim();
		return Parsed<DeviceStatus>.Ok(new DeviceStatus
		{
			UpdatedAt = updatedAt,
			Capture = capture,
			Link = link,
			Recording = recording,
			LastAudioAt = Instant(p.LastAudioAtMs),
			WatchBatteryPercent = Percent(p.WatchBatteryPercent),
			WatchFirmware = string.IsNullOrEmpty(firmware) ? null : firmware.Length > FirmwareLength ? firmware[..FirmwareLength] : firmware,
			TodayRecordedMinutes = Count(p.TodayRecordedMinutes),
			TodayQuietMinutes = Count(p.TodayQuietMinutes),
			TodayLostMinutes = Count(p.TodayLostMinutes),
			StorageUsedBytes = p.StorageUsedBytes is { } bytes && bytes >= 0 && bytes < long.MaxValue ? (long)Math.Round(bytes) : null,
			PhoneBatteryPercent = Percent(p.PhoneBatteryPercent),
		});
	}

	/// <summary>Epoch milliseconds as an instant, or null for none or one no clock could have read.</summary>
	private static DateTimeOffset? Instant(double? milliseconds) =>
		milliseconds is { } ms && ms > 0 && ms < 253_402_300_799_999
			? DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(ms))
			: null;

	private static int? Percent(double? value) =>
		value is { } v && v >= 0 && v <= 100 ? (int)Math.Round(v) : null;

	private static int? Count(double? value) =>
		value is { } v && v >= 0 && v <= int.MaxValue ? (int)Math.Round(v) : null;

	private static Parsed<DeviceStatus> Unknown(string field, string? value) =>
		Parsed<DeviceStatus>.Fail(value is null ? $"payload: {field} missing" : $"payload: {field} '{value}' is not known");

	/// <summary>The wire shape. Every field is optional here; <see cref="Read"/> decides what is required.</summary>
	private sealed class Payload
	{
		public double? UpdatedAtMs { get; init; }
		public string? Capture { get; init; }
		public string? Link { get; init; }
		public bool? Recording { get; init; }
		public double? LastAudioAtMs { get; init; }
		public double? WatchBatteryPercent { get; init; }
		public string? WatchFirmware { get; init; }
		public double? TodayRecordedMinutes { get; init; }
		public double? TodayQuietMinutes { get; init; }
		public double? TodayLostMinutes { get; init; }
		public double? StorageUsedBytes { get; init; }
		public double? PhoneBatteryPercent { get; init; }
	}
}
