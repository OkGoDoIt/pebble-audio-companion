using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// The JSON of sync-protocol.md: camelCase, explicit nulls, and every instant an RFC 3339 string in UTC with
/// milliseconds (<c>2026-10-14T13:05:09.754Z</c>). Reading accepts any RFC 3339 offset and stores UTC.
/// </summary>
public static partial class SyncJson
{
	public static JsonSerializerOptions Options { get; } = Create();

	public static string Format(DateTimeOffset value) =>
		value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

	/// <summary>
	/// Parses an RFC 3339 date-time, for example <c>2026-10-14T13:05:09.754Z</c> or <c>…+07:00</c>, into UTC.
	/// </summary>
	public static bool TryParseInstant(string? text, out DateTimeOffset value)
	{
		value = default;
		if (string.IsNullOrEmpty(text) || !Rfc3339().IsMatch(text) ||
			!DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed))
		{
			return false;
		}

		value = parsed.ToUniversalTime();
		return true;
	}

	/// <summary>A logical day key, <c>2026-10-14</c>.</summary>
	public static bool TryParseDay(string? text, out DateOnly day) =>
		DateOnly.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out day);

	private static JsonSerializerOptions Create()
	{
		var options = new JsonSerializerOptions(JsonSerializerDefaults.Web)
		{
			DefaultIgnoreCondition = JsonIgnoreCondition.Never,
		};
		options.Converters.Add(new InstantConverter());
		options.MakeReadOnly(populateMissingResolver: true);
		return options;
	}

	[GeneratedRegex(@"^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d{1,7})?([Zz]|[+-]\d{2}:\d{2})$")]
	private static partial Regex Rfc3339();

	private sealed class InstantConverter : JsonConverter<DateTimeOffset>
	{
		public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
		{
			var text = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
			return TryParseInstant(text, out var value)
				? value
				: throw new JsonException($"'{text}' is not an RFC 3339 time.");
		}

		public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
			writer.WriteStringValue(Format(value));
	}
}
