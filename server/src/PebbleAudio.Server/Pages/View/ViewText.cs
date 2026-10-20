using System.Globalization;
using PebbleAudio.Server.Mcp;

namespace PebbleAudio.Server.Pages.View;

/// <summary>
/// Every time, duration, and list the viewer shows, in the app's words (ios/App/DesignSystem/Copy+History.swift):
/// "Wed, Oct 14 · 10:54 – 11:21 AM · 27 min · 48 sec missing". American English, Oxford comma.
/// </summary>
public static class ViewText
{
	public static readonly CultureInfo English = CultureInfo.GetCultureInfo("en-US");

	/// <summary><c>10:54 AM</c>.</summary>
	public static string Clock(DateTimeOffset local) => local.ToString("h:mm tt", English);

	/// <summary><c>10:54</c>, for margins where the day's half is already clear.</summary>
	public static string ShortClock(DateTimeOffset local) => local.ToString("h:mm", English);

	/// <summary><c>10:54 – 11:21 AM</c>, or <c>11:40 AM – 12:15 PM</c> across noon.</summary>
	public static string Range(DateTimeOffset start, DateTimeOffset end) =>
		start.ToString("tt", English) == end.ToString("tt", English)
			? $"{ShortClock(start)} – {Clock(end)}"
			: $"{Clock(start)} – {Clock(end)}";

	/// <summary><c>Wed, Oct 14</c>, with the year when it is not this year.</summary>
	public static string ShortDate(DateOnly day, DateOnly today) =>
		day.ToString(day.Year == today.Year ? "ddd, MMM d" : "ddd, MMM d, yyyy", English);

	/// <summary><c>October 14, 2026</c>.</summary>
	public static string LongDate(DateOnly day) => day.ToString("MMMM d, yyyy", English);

	/// <summary><c>Wednesday</c>.</summary>
	public static string Weekday(DateOnly day) => day.ToString("dddd", English);

	/// <summary>
	/// <c>27 min</c>, <c>1 hr 5 min</c>, and under a minute <c>under 1 min</c>, or <c>48 sec</c> with
	/// <paramref name="seconds"/> (for loss, where a short one still has to read as real).
	/// </summary>
	public static string Duration(double totalSeconds, bool seconds = false)
	{
		var whole = (int)Math.Round(Math.Max(0, totalSeconds));
		if (whole < 60)
		{
			return seconds ? $"{Math.Max(1, whole)} sec" : "under 1 min";
		}

		var minutes = (int)Math.Round(whole / 60.0);
		if (minutes < 60)
		{
			return $"{minutes} min";
		}

		var (hours, rest) = (minutes / 60, minutes % 60);
		return rest == 0 ? $"{hours} hr" : $"{hours} hr {rest} min";
	}

	/// <summary><c>48 sec missing</c>.</summary>
	public static string Missing(double seconds) => $"{Duration(seconds, seconds: true)} missing";

	/// <summary><c>3 conversations</c>.</summary>
	public static string Count(int count, string one, string many) =>
		count == 1 ? $"1 {one}" : $"{count.ToString("N0", English)} {many}";

	public static string List(IReadOnlyList<string> items) => Speak.List(items);

	/// <summary>
	/// <c>Sam, Priya, and 2 other voices</c>: named people first, never a made-up name for one the app has not
	/// matched; <c>2 voices</c> when nobody is named.
	/// </summary>
	public static string? People(IReadOnlyList<string> named, int unnamed)
	{
		if (named.Count == 0)
		{
			return unnamed == 0 ? null : Count(unnamed, "voice", "voices");
		}

		var parts = named.ToList();
		if (unnamed > 0)
		{
			parts.Add(unnamed == 1 ? "1 other voice" : $"{unnamed} other voices");
		}

		return List(parts);
	}

	/// <summary>The city of an IANA zone, the way the app names it: <c>Asia/Ho_Chi_Minh</c> is <c>Ho Chi Minh</c>.</summary>
	public static string Place(string zoneId)
	{
		var city = zoneId.Split('/').Last();
		return city.Replace('_', ' ');
	}

	/// <summary>Why audio is missing, worded as the app words the same cause; null when nothing was recorded about why.</summary>
	public static string? LossCause(string? origin) => origin switch
	{
		"link" => "connection was interrupted",
		"watch" => "the watch didn't record it",
		_ => null,
	};

	/// <summary>The app's sentence for the watch's power-save pause.</summary>
	public const string WatchSavingPower = "watch was saving power";

	/// <summary>An untitled conversation's place in a title.</summary>
	public const string NotSummarized = "Not summarized yet";

	/// <summary>A first letter in upper case: <c>music</c> becomes <c>Music</c>.</summary>
	public static string Capitalized(string text) =>
		text.Length == 0 ? text : char.ToUpper(text[0], English) + text[1..];

	/// <summary>An untitled conversation's first words, quoted, as the app shows them.</summary>
	public static string? FirstWords(string? text, int length = 80) =>
		string.IsNullOrWhiteSpace(text) ? null : $"“{Speak.Cap(text.Trim(), length)}”";
}
