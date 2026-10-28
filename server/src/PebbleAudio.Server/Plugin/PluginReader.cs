using System.Security.Claims;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Mcp;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Plugin;

/// <summary>
/// What the Pebble plugin reads (pebble-plugin/README.md, "Server endpoints"): the watch's status as the phone last
/// reported it, and today at a glance. Today goes through <see cref="ArchiveReader"/>, so it is the account's own and
/// inside the sharing scope exactly as the MCP tools read it.
/// </summary>
public sealed class PluginReader(ArchiveDbContext db, ArchiveReader archive, SettingsService settings, TimeProvider time)
{
	/// <summary>The longest recap line sent; a watch shows far less.</summary>
	public const int RecapLineLength = 200;

	/// <summary>
	/// The newest report from a linked phone (by when the phone took it), or null when none has arrived. With two
	/// phones linked, the one that reported last is the one holding the watch.
	/// </summary>
	public async Task<PluginStatus?> StatusAsync(Guid userId, CancellationToken cancellationToken)
	{
		var latest = await (
				from row in db.DeviceStatuses.AsNoTracking()
				join d in db.Devices.AsNoTracking() on row.DeviceId equals d.Id
				where row.UserId == userId && d.UserId == userId && d.UnlinkedAt == null
				orderby row.UpdatedAt descending, row.ReceivedAt descending
				select new { Status = row, d.Name })
			.FirstOrDefaultAsync(cancellationToken);
		if (latest is null)
		{
			return null;
		}

		var s = latest.Status;
		var staleAfter = (await settings.GetAsync(cancellationToken)).PluginStaleAfter;
		return new PluginStatus(
			s.UpdatedAt.ToUnixTimeMilliseconds(),
			s.Capture.ToWire(),
			s.Link.ToWire(),
			s.Recording,
			s.LastAudioAt?.ToUnixTimeMilliseconds(),
			s.WatchBatteryPercent,
			s.WatchFirmware,
			s.TodayRecordedMinutes,
			s.TodayQuietMinutes,
			s.TodayLostMinutes,
			s.StorageUsedBytes,
			s.PhoneBatteryPercent,
			s.ReceivedAt.ToUnixTimeMilliseconds(),
			time.GetUtcNow() - s.ReceivedAt > staleAfter,
			ArchiveReader.Blank(latest.Name));
	}

	/// <summary>
	/// Today, the archive's logical day (rolling over at 5 AM in the account's time zone): how many conversations, the
	/// recap's first line, the conversation still going (the day's newest, while it is live or provisional), and the
	/// latest one before it, which may be from an earlier day. Music and other audio that is not a conversation is not
	/// counted, as <c>get_day</c> does not count it.
	/// </summary>
	public async Task<PluginToday> TodayAsync(ClaimsPrincipal user, CancellationToken cancellationToken)
	{
		var call = await archive.BeginAsync(user, cancellationToken);
		var day = call.Today;
		var talk = archive.Conversations(call).Where(c => c.ContentKind == ContentKind.Conversation);

		var count = await talk.CountAsync(c => c.DayKey == day, cancellationToken);
		var recap = await archive.Recaps(call)
			.Where(r => r.DayKey == day)
			.Select(r => new { r.Headline, r.LineSummary, r.Text })
			.SingleOrDefaultAsync(cancellationToken);

		var newest = await talk
			.Where(c => c.DayKey == day)
			.OrderByDescending(c => c.StartedAt)
			.Select(c => new Row(c.Id, c.Title, c.StartedAt, c.EndedAt, c.RecordedMs, c.State, c.Provisional))
			.FirstOrDefaultAsync(cancellationToken);
		var current = newest is { } n && (n.State == ConversationState.Live || n.Provisional) ? n : null;

		var lastQuery = talk.Where(c => c.State == ConversationState.Closed);
		if (current is not null)
		{
			var currentId = current.Id;
			lastQuery = lastQuery.Where(c => c.Id != currentId);
		}

		var last = await lastQuery
			.OrderByDescending(c => c.StartedAt)
			.Select(c => new Row(c.Id, c.Title, c.StartedAt, c.EndedAt, c.RecordedMs, c.State, c.Provisional))
			.FirstOrDefaultAsync(cancellationToken);

		return new PluginToday(
			Days.Key(day),
			count,
			Speak.Cap(FirstLine(recap?.Headline) ?? FirstLine(recap?.LineSummary) ?? FirstLine(recap?.Text), RecapLineLength),
			current is null ? null : new PluginCurrent(current.Id, ArchiveReader.Blank(current.Title), current.StartedAt.ToUnixTimeMilliseconds(), State(current)),
			last is null
				? null
				: new PluginLast(
					last.Id,
					ArchiveReader.Blank(last.Title),
					last.StartedAt.ToUnixTimeMilliseconds(),
					(last.EndedAt ?? last.StartedAt + TimeSpan.FromMilliseconds(last.RecordedMs)).ToUnixTimeMilliseconds(),
					State(last)),
			archive.Links.Day(day));
	}

	/// <summary><c>live</c> while it is being recorded, <c>provisional</c> while its edges may still move, else <c>closed</c>.</summary>
	private static string State(Row row) =>
		row.State == ConversationState.Live ? ConversationState.Live.ToWire()
		: row.Provisional ? "provisional"
		: ConversationState.Closed.ToWire();

	/// <summary>The first line of a text, and of that its first sentence.</summary>
	internal static string? FirstLine(string? text)
	{
		var line = ArchiveReader.Blank(text)?.Split('\n', 2)[0].Trim();
		if (string.IsNullOrEmpty(line))
		{
			return null;
		}

		for (var i = 0; i < line.Length - 1; i++)
		{
			if (line[i] is '.' or '!' or '?' && line[i + 1] == ' ')
			{
				return line[..(i + 1)];
			}
		}

		return line;
	}

	private sealed record Row(string Id, string? Title, DateTimeOffset StartedAt, DateTimeOffset? EndedAt, long RecordedMs, ConversationState State, bool Provisional);
}

/// <summary><c>GET /plugin/status</c>: the phone's report (sync-protocol.md §2.8), with when it arrived and whether that is too long ago.</summary>
public sealed record PluginStatus(
	long UpdatedAtMs,
	string Capture,
	string Link,
	bool Recording,
	long? LastAudioAtMs,
	int? WatchBatteryPercent,
	string? WatchFirmware,
	int? TodayRecordedMinutes,
	int? TodayQuietMinutes,
	int? TodayLostMinutes,
	long? StorageUsedBytes,
	int? PhoneBatteryPercent,
	long ReceivedAtMs,
	bool Stale,
	string? DeviceName);

/// <summary><c>GET /plugin/today</c>.</summary>
/// <param name="Date">The archive's day, <c>yyyy-MM-dd</c>.</param>
/// <param name="ViewerUrl">The day in the viewer (<c>/d/{day}</c>), which asks for the passkey.</param>
public sealed record PluginToday(string Date, int ConversationCount, string? RecapHeadline, PluginCurrent? Current, PluginLast? Last, string? ViewerUrl);

/// <param name="Title">Null until the phone has titled it.</param>
public sealed record PluginCurrent(string Id, string? Title, long StartedAtMs, string State);

public sealed record PluginLast(string Id, string? Title, long StartedAtMs, long EndedAtMs, string State);
