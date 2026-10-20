using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Options;
using ModelContextProtocol.Protocol;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>A tool's structured content: every one leads with a speakable sentence (docs/tool-results.md).</summary>
public interface IToolResult
{
	string Summary { get; }
}

/// <summary>The exact call that continues a cut or paged result.</summary>
public sealed record NextCall(string Tool, IReadOnlyDictionary<string, object> Arguments);

/// <summary>
/// The JSON of tool results (docs/tool-results.md): camelCase, nulls left out, and instants written whole seconds in
/// the offset they carry, which the tools set to the conversation's or the account's time zone.
/// </summary>
public static class ToolJson
{
	public static JsonSerializerOptions Options { get; } = Create();

	private static JsonSerializerOptions Create()
	{
		var options = new JsonSerializerOptions(JsonSerializerDefaults.Web)
		{
			DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
			// The JSON is read by models and widgets, never put into HTML, so quotes and accents stay as they are.
			Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
		};
		options.Converters.Add(new LocalInstantConverter());
		options.MakeReadOnly(populateMissingResolver: true);
		return options;
	}

	public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Options);

	/// <summary>How many characters <paramref name="value"/> takes as result JSON.</summary>
	public static int Length<T>(T value) => Serialize(value).Length;

	private sealed class LocalInstantConverter : JsonConverter<DateTimeOffset>
	{
		public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
			DateTimeOffset.Parse(reader.GetString()!, CultureInfo.InvariantCulture);

		public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
			writer.WriteStringValue(value.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture));
	}
}

/// <summary>
/// Builds <see cref="CallToolResult"/>s the way every tool answers: the structured content, then in <c>content</c> its
/// speakable summary and the same JSON as text.
/// </summary>
public static class ToolResults
{
	public static CallToolResult Of<T>(T value, JsonObject? meta = null)
		where T : IToolResult
	{
		var json = ToolJson.Serialize(value);
		using var document = JsonDocument.Parse(json);
		return new CallToolResult
		{
			StructuredContent = document.RootElement.Clone(),
			Content =
			[
				new TextContentBlock { Text = value.Summary },
				new TextContentBlock { Text = json },
			],
			Meta = meta,
		};
	}

	/// <summary>Arguments the tool cannot use: the text says what to send instead.</summary>
	public static CallToolResult Error(string message) => new()
	{
		IsError = true,
		Content = [new TextContentBlock { Text = message }],
	};
}

/// <summary>
/// The viewer's links (docs/tool-results.md, "Viewer links"), built from the public origin and never from a request.
/// </summary>
public sealed class ViewerLinks(IOptions<PebbleAudioOptions> options)
{
	private string Origin => options.Value.PublicOrigin;

	public string Conversation(string id) => $"{Origin}/c/{Uri.EscapeDataString(id)}";

	public string Moment(string id, int secondsFromStart) =>
		secondsFromStart > 0 ? $"{Conversation(id)}?t={secondsFromStart.ToString(CultureInfo.InvariantCulture)}" : Conversation(id);

	public string Day(DateOnly day) => $"{Origin}/d/{Days.Key(day)}";

	public string Week(DateOnly startDay) => $"{Origin}/b/week/{Days.Key(startDay)}";

	public string Month(DateOnly startDay) => $"{Origin}/b/month/{startDay.ToString("yyyy-MM", CultureInfo.InvariantCulture)}";
}

/// <summary>Days and instants as the results write and say them.</summary>
public static class Days
{
	public static string Key(DateOnly day) => day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

	/// <summary>An instant in a zone's local offset.</summary>
	public static DateTimeOffset Local(DateTimeOffset instant, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(instant, zone);

	public static DateTimeOffset? Local(DateTimeOffset? instant, TimeZoneInfo zone) => instant is { } at ? Local(at, zone) : null;

	/// <summary>Whole seconds from <paramref name="start"/>, never negative: the <c>t</c> of a moment link.</summary>
	public static int Offset(DateTimeOffset at, DateTimeOffset start) => Math.Max(0, (int)Math.Floor((at - start).TotalSeconds));

	public static double Minutes(long milliseconds) => Math.Round(milliseconds / 60_000.0, 1);

	public static double Minutes(TimeSpan span) => Math.Round(Math.Max(0, span.TotalMinutes), 1);

	/// <summary><c>yyyy-MM-dd</c>, <c>today</c>, or <c>yesterday</c>.</summary>
	public static bool TryParse(string? text, DateOnly today, out DateOnly day)
	{
		var trimmed = text?.Trim().ToLowerInvariant();
		switch (trimmed)
		{
			case "today":
				day = today;
				return true;
			case "yesterday":
				day = today.AddDays(-1);
				return true;
			default:
				return DateOnly.TryParseExact(trimmed, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out day);
		}
	}

	/// <summary>A bare weekday name such as <c>tuesday</c> or <c>last Tuesday</c>, which could be more than one day.</summary>
	public static DayOfWeek? Weekday(string? text)
	{
		var words = (text ?? "").Trim().ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
		var name = words switch
		{
			[var only] => only,
			["last" or "this" or "on", var second] => second,
			_ => null,
		};
		return Enum.GetValues<DayOfWeek>().Cast<DayOfWeek?>().FirstOrDefault(d => d.ToString()!.Equals(name, StringComparison.OrdinalIgnoreCase));
	}

	/// <summary>
	/// An instant (RFC 3339, any offset), seconds from <paramref name="start"/>, or a local date and time without an
	/// offset, read in <paramref name="zone"/>. False for anything else.
	/// </summary>
	public static bool TryParseTime(string? text, DateTimeOffset start, TimeZoneInfo zone, out DateTimeOffset at)
	{
		at = default;
		var trimmed = text?.Trim();
		if (string.IsNullOrEmpty(trimmed))
		{
			return false;
		}

		if (double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && seconds >= 0 && seconds < 7 * 86_400)
		{
			at = start.AddSeconds(seconds);
			return true;
		}

		if (SyncJson.TryParseInstant(trimmed, out at))
		{
			return true;
		}

		if (trimmed.Length < 16)
		{
			return false;
		}

		// Without an offset it is the person's wall clock where the conversation happened.
		var hasOffset = trimmed.EndsWith('Z') || trimmed.EndsWith('z') || trimmed.Length > 6 && trimmed[^6] is '+' or '-' && trimmed[^3] == ':';
		if (hasOffset && DateTimeOffset.TryParse(trimmed, CultureInfo.InvariantCulture, DateTimeStyles.None, out var withOffset))
		{
			at = withOffset.ToUniversalTime();
			return true;
		}

		if (!hasOffset && DateTime.TryParse(trimmed, CultureInfo.InvariantCulture, DateTimeStyles.None, out var wall))
		{
			var local = DateTime.SpecifyKind(wall, DateTimeKind.Unspecified);
			at = new DateTimeOffset(local, zone.GetUtcOffset(local)).ToUniversalTime();
			return true;
		}

		return false;
	}
}

/// <summary>Words for speakable summaries: American English, a touch friendly, no markup.</summary>
public static class Speak
{
	private static readonly CultureInfo English = CultureInfo.GetCultureInfo("en-US");

	/// <summary><c>Tuesday, October 14</c>, with the year when it is not this year.</summary>
	public static string Day(DateOnly day, DateOnly today) =>
		day.ToString(day.Year == today.Year ? "dddd, MMMM d" : "dddd, MMMM d, yyyy", English);

	/// <summary><c>October 14</c>, with the year when it is not this year.</summary>
	public static string ShortDay(DateOnly day, DateOnly today) =>
		day.ToString(day.Year == today.Year ? "MMMM d" : "MMMM d, yyyy", English);

	public static string Clock(DateTimeOffset local) => local.ToString("h:mm tt", English);

	public static string Duration(double minutes)
	{
		if (minutes < 1)
		{
			return "under a minute";
		}

		var total = (int)Math.Round(minutes);
		var hours = total / 60;
		var rest = total % 60;
		var hourText = hours == 1 ? "1 hour" : $"{hours} hours";
		var minuteText = rest == 1 ? "1 minute" : $"{rest} minutes";
		return hours == 0 ? minuteText : rest == 0 ? hourText : $"{hourText} {minuteText}";
	}

	public static string Count(int count, string one, string many) =>
		count == 1 ? $"1 {one}" : $"{count.ToString("N0", English)} {many}";

	/// <summary>A list with the Oxford comma: <c>a, b, and c</c>, or with <paramref name="conjunction"/> <c>or</c>.</summary>
	public static string List(IReadOnlyList<string> items, string conjunction = "and") => items.Count switch
	{
		0 => "",
		1 => items[0],
		2 => $"{items[0]} {conjunction} {items[1]}",
		_ => $"{string.Join(", ", items.Take(items.Count - 1))}, {conjunction} {items[^1]}",
	};

	/// <summary>Cuts a text to <paramref name="length"/> characters, ending with an ellipsis when cut.</summary>
	public static string? Cap(string? text, int length)
	{
		if (text is null || text.Length <= length)
		{
			return text;
		}

		var cut = text[..Math.Max(0, length - 1)];
		var space = cut.LastIndexOf(' ');
		if (space > length * 2 / 3)
		{
			cut = cut[..space];
		}

		return cut.TrimEnd(' ', ',', ';', ':', '.') + "…";
	}

	/// <summary>A clause that ends a sentence: trailing punctuation removed so the caller adds its own.</summary>
	public static string Clause(string text) => text.Trim().TrimEnd('.', '!', ';', ':', ' ');

	/// <summary>How long ago, for "last synced 3 minutes ago".</summary>
	public static string Ago(TimeSpan span) => span.TotalMinutes switch
	{
		< 1 => "just now",
		< 60 => $"{Count((int)span.TotalMinutes, "minute", "minutes")} ago",
		< 48 * 60 => $"{Count((int)span.TotalHours, "hour", "hours")} ago",
		_ => $"{Count((int)span.TotalDays, "day", "days")} ago",
	};
}
