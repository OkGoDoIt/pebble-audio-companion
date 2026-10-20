using System.Globalization;
using Microsoft.AspNetCore.Html;

namespace PebbleAudio.Server.Pages;

/// <summary>
/// Markup helpers for times. The server renders UTC; admin.js rewrites each <c>time[data-format]</c> into the
/// viewer's own time zone.
/// </summary>
public static class Display
{
	public static IHtmlContent Time(DateTimeOffset value, string format = "datetime")
	{
		var utc = value.ToUniversalTime();
		var iso = utc.ToString("O", CultureInfo.InvariantCulture);
		var fallback = format == "date"
			? utc.ToString("MMM d, yyyy", CultureInfo.InvariantCulture)
			: utc.ToString("MMM d, yyyy, h:mm tt 'UTC'", CultureInfo.InvariantCulture);
		return new HtmlString(
			$"<time datetime=\"{iso}\" data-format=\"{format}\">{System.Net.WebUtility.HtmlEncode(fallback)}</time>");
	}

	public static string Day(DateOnly day) => day.ToString("MMM d, yyyy", CultureInfo.InvariantCulture);

	public static string Count(int value) => value.ToString("N0", CultureInfo.InvariantCulture);
}
