using System.Globalization;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Mcp;

namespace PebbleAudio.Server.Pages;

/// <summary>
/// The words the server's own pages share with the iPhone app's AI Assistants screens
/// (ios/App/DesignSystem/Copy+AssistantAccess.swift, <c>AssistantTime</c>), so the site and the phone say the same
/// thing about the same assistant. Times are read in the account's time zone.
/// </summary>
public static class SiteText
{
	public static readonly CultureInfo English = CultureInfo.GetCultureInfo("en-US");

	/// <summary>"just now", "2 min ago", "1 hr ago", "yesterday", "Oct 18".</summary>
	public static string Ago(DateTimeOffset at, DateTimeOffset now, TimeZoneInfo zone)
	{
		var since = now - at;
		if (since < TimeSpan.FromMinutes(1))
		{
			return "just now";
		}

		if (since < TimeSpan.FromHours(1))
		{
			return $"{(int)since.TotalMinutes} min ago";
		}

		var then = DateOnly.FromDateTime(Days.Local(at, zone).DateTime);
		var today = DateOnly.FromDateTime(Days.Local(now, zone).DateTime);
		if (then == today)
		{
			return $"{(int)since.TotalHours} hr ago";
		}

		return then == today.AddDays(-1) ? "yesterday" : ShortDay(at, zone);
	}

	/// <summary>"just now", "2 min ago", or "Oct 12": when an assistant connected.</summary>
	public static string ConnectedWhen(DateTimeOffset at, DateTimeOffset now, TimeZoneInfo zone)
	{
		var since = now - at;
		if (since < TimeSpan.FromMinutes(1))
		{
			return "just now";
		}

		return since < TimeSpan.FromHours(1) ? $"{(int)since.TotalMinutes} min ago" : ShortDay(at, zone);
	}

	/// <summary>"Connected Oct 12".</summary>
	public static string Connected(DateTimeOffset at, DateTimeOffset now, TimeZoneInfo zone) =>
		$"Connected {ConnectedWhen(at, now, zone)}";

	/// <summary>"Last read 1 hr ago", or "Not used yet".</summary>
	public static string LastRead(DateTimeOffset? at, DateTimeOffset now, TimeZoneInfo zone) =>
		at is { } used ? $"Last read {Ago(used, now, zone)}" : "Not used yet";

	/// <summary>"Oct 18".</summary>
	public static string ShortDay(DateTimeOffset at, TimeZoneInfo zone) => Days.Local(at, zone).ToString("MMM d", English);

	/// <summary>What an assistant may do: the same words as the phone's Who can read and Privacy screens.</summary>
	public static string MayDo(bool clips, bool add) => (clips, add) switch
	{
		(true, true) => "Can read, ask for clips, and add",
		(true, false) => "Can read and ask for clips",
		(false, true) => "Can read and add",
		(false, false) => "Can read",
	};

	/// <summary>Whether the scopes let an assistant add follow-ups and notes, once the phone allows it.</summary>
	public static bool CanWrite(IEnumerable<string> scopes) => scopes.Contains(ArchiveScopes.Write);
}
