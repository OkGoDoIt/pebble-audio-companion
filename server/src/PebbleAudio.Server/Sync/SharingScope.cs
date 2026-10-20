using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// The sharing scope and the account's clock, resolved at one moment (sync-protocol.md §5). Everything that reads
/// or keeps archive rows asks it: tools filter by <see cref="From"/> and <see cref="FromDay"/>, batches drop items
/// before them, and the nightly deletion removes what has fallen out.
/// </summary>
/// <remarks>
/// "Dated" means a conversation's start, a recap's or coverage's day, a brief's last day, a follow-up's source time
/// (else when it was created), and a note's conversation (else when it was created). A day is inside when it is on
/// or after the logical day <see cref="From"/> falls on.
/// </remarks>
public sealed record AccountScope(
	SharingScopeKind Kind,
	DateTimeOffset? Since,
	int? Days,
	string TimeZoneId,
	TimeZoneInfo TimeZone,
	DateTimeOffset Now)
{
	/// <summary>The earliest instant the archive may hold now; null when it holds everything.</summary>
	public DateTimeOffset? From => Kind switch
	{
		SharingScopeKind.All => null,
		SharingScopeKind.Since => Since,
		SharingScopeKind.LastDays => Now - TimeSpan.FromDays(Days ?? 0),
	};

	/// <summary>The earliest logical day the archive may hold now; null when it holds everything.</summary>
	public DateOnly? FromDay => From is { } from ? LogicalDays.Of(from, TimeZone) : null;

	/// <summary>Today, as the person's day: rolling over at 5 AM in the account's time zone.</summary>
	public DateOnly Today => LogicalDays.Of(Now, TimeZone);

	public bool Holds(DateTimeOffset at) => From is not { } from || at >= from;

	public bool HoldsDay(DateOnly day) => FromDay is not { } from || day >= from;

	/// <summary>True when both are the scope the phone set (the same window, whatever the moment).</summary>
	public bool SameScopeAs(AccountScope other) =>
		Kind == other.Kind &&
		Kind switch
		{
			SharingScopeKind.All => true,
			SharingScopeKind.Since => Since == other.Since,
			SharingScopeKind.LastDays => Days == other.Days,
		};
}

/// <summary>
/// The app's logical day: it rolls over at 5 AM local time, not midnight, so a late night belongs to the day before.
/// </summary>
public static class LogicalDays
{
	public static readonly TimeSpan Rollover = TimeSpan.FromHours(5);

	public static DateOnly Of(DateTimeOffset instant, TimeZoneInfo zone) =>
		DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(instant, zone).DateTime - Rollover);

	/// <summary>When a logical day starts (5 AM local).</summary>
	public static DateTimeOffset Start(DateOnly day, TimeZoneInfo zone) => At(day, Rollover, zone);

	/// <summary>A wall-clock time on a calendar date in a zone, moved past a daylight-saving gap if it falls in one.</summary>
	public static DateTimeOffset At(DateOnly date, TimeSpan timeOfDay, TimeZoneInfo zone)
	{
		var local = date.ToDateTime(TimeOnly.MinValue).Add(timeOfDay);
		while (zone.IsInvalidTime(local))
		{
			local = local.AddMinutes(30);
		}

		var offset = zone.GetUtcOffset(local);
		return new DateTimeOffset(local, offset).ToUniversalTime();
	}

	/// <summary>An IANA zone by id, or UTC when the id is missing or unknown here.</summary>
	public static TimeZoneInfo Zone(string? id)
	{
		if (!string.IsNullOrWhiteSpace(id))
		{
			try
			{
				return TimeZoneInfo.FindSystemTimeZoneById(id);
			}
			catch (Exception ex) when (ex is TimeZoneNotFoundException or InvalidTimeZoneException)
			{
			}
		}

		return TimeZoneInfo.Utc;
	}
}

/// <summary>
/// Reads and sets the sharing scope, which the phone owns and sends with its preferences.
/// </summary>
public sealed class SharingScopes(ArchiveDbContext db, TimeProvider time)
{
	/// <summary>The longest window a <c>lastDays</c> scope may ask for: about a hundred years.</summary>
	public const int MaxDays = 36_500;

	/// <summary>The time the nightly deletion runs, in the account's time zone.</summary>
	public static readonly TimeSpan SweepTime = new(3, 30, 0);

	public async Task<AccountScope> GetAsync(Guid userId, CancellationToken cancellationToken)
	{
		var row = await db.SyncPreferences.AsNoTracking().SingleOrDefaultAsync(p => p.UserId == userId, cancellationToken);
		return Resolve(row, time.GetUtcNow());
	}

	/// <summary>
	/// Stores the scope the phone sent. When it is a different scope, tonight's deletion counts as done, because the
	/// caller deletes what falls outside it at once.
	/// </summary>
	/// <returns>True when the scope changed.</returns>
	public async Task<bool> SetAsync(
		Guid userId,
		Guid deviceId,
		SharingScopeKind kind,
		DateTimeOffset? since,
		int? days,
		CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		var row = await db.SyncPreferences.SingleOrDefaultAsync(p => p.UserId == userId, cancellationToken);
		if (row is null)
		{
			row = new SyncPreferences { UserId = userId };
			db.SyncPreferences.Add(row);
		}

		var before = Resolve(row, now);
		row.ScopeKind = kind;
		row.ScopeSince = kind == SharingScopeKind.Since ? since?.ToUniversalTime() : null;
		row.ScopeDays = kind == SharingScopeKind.LastDays ? days : null;
		row.UpdatedAt = now;
		row.DeviceId = deviceId;
		var after = Resolve(row, now);
		var changed = !before.SameScopeAs(after);
		if (changed)
		{
			row.ScopeSweptFor = LatestSweepSlot(now, after.TimeZone);
		}

		await db.SaveChangesAsync(cancellationToken);
		return changed;
	}

	/// <summary>
	/// Keeps the account's time zone that of the latest conversation the phone sent. Called after a batch that
	/// stored a conversation.
	/// </summary>
	public async Task FollowLatestTimeZoneAsync(Guid userId, CancellationToken cancellationToken)
	{
		var zone = await db.Conversations
			.Where(c => c.UserId == userId)
			.OrderByDescending(c => c.StartedAt)
			.Select(c => c.TimeZone)
			.FirstOrDefaultAsync(cancellationToken);
		if (string.IsNullOrWhiteSpace(zone))
		{
			return;
		}

		var row = await db.SyncPreferences.SingleOrDefaultAsync(p => p.UserId == userId, cancellationToken);
		if (row is null)
		{
			db.SyncPreferences.Add(new SyncPreferences { UserId = userId, TimeZone = zone, UpdatedAt = time.GetUtcNow() });
		}
		else if (row.TimeZone == zone)
		{
			return;
		}
		else
		{
			row.TimeZone = zone;
		}

		await db.SaveChangesAsync(cancellationToken);
	}

	public static AccountScope Resolve(SyncPreferences? row, DateTimeOffset now)
	{
		var zone = LogicalDays.Zone(row?.TimeZone);
		var kind = row?.ScopeKind ?? SharingScopeKind.All;
		// A row the phone filled in half is read as the widest scope rather than an empty one.
		kind = kind switch
		{
			SharingScopeKind.Since when row?.ScopeSince is null => SharingScopeKind.All,
			SharingScopeKind.LastDays when row?.ScopeDays is not > 0 => SharingScopeKind.All,
			_ => kind,
		};
		return new AccountScope(
			kind,
			kind == SharingScopeKind.Since ? row!.ScopeSince : null,
			kind == SharingScopeKind.LastDays ? row!.ScopeDays : null,
			zone == TimeZoneInfo.Utc ? "UTC" : zone.Id,
			zone,
			now);
	}

	/// <summary>
	/// The most recent 03:30 in the account's time zone at or before <paramref name="now"/>: the nightly deletion
	/// that should have run by then.
	/// </summary>
	public static DateTimeOffset LatestSweepSlot(DateTimeOffset now, TimeZoneInfo zone)
	{
		var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, zone).DateTime);
		var slot = LogicalDays.At(today, SweepTime, zone);
		return slot <= now ? slot : LogicalDays.At(today.AddDays(-1), SweepTime, zone);
	}
}
