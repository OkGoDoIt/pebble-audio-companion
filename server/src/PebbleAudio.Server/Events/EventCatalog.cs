using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace PebbleAudio.Server.Events;

/// <summary>
/// One event an assistant can subscribe to (<c>events/list</c>).
/// </summary>
/// <param name="Name">The wire name, for example <c>day_recap.ready</c>.</param>
/// <param name="Label">What the admin area calls it.</param>
/// <param name="Description">What the assistant reads.</param>
/// <param name="InputSchema">The subscription arguments (none, for now).</param>
/// <param name="PayloadSchema">The shape of <c>data</c> in each delivery.</param>
public sealed record EventDefinition(string Name, string Label, string Description, JsonObject InputSchema, JsonObject PayloadSchema);

/// <summary>
/// The events this server emits. Payloads are short summaries with a viewer link, never transcripts: a delivery is
/// capped at 256 KiB, and the archive's tools fetch the rest.
/// </summary>
public static class EventCatalog
{
	public const string DayRecapReady = "day_recap.ready";

	public const string FollowUpCreated = "followup.created";

	private const string NoArguments = """{"type":"object","properties":{},"additionalProperties":false}""";

	public static IReadOnlyList<EventDefinition> All { get; } =
	[
		new(
			DayRecapReady,
			"Day recap is ready",
			"The phone finished the recap of one of the user's days. The payload is the headline, a one-line summary, " +
			"and a link; use the archive's tools for the full recap and its conversations.",
			Schema(NoArguments),
			Schema("""
				{
					"type": "object",
					"properties": {
						"day": { "type": "string", "format": "date", "description": "The logical day, YYYY-MM-DD. A day starts at 5 AM in its time zone." },
						"timeZone": { "type": "string", "description": "The IANA time zone of the day, for example Asia/Jakarta." },
						"headline": { "type": "string" },
						"summary": { "type": "string", "description": "One line about the day." },
						"conversationCount": { "type": "integer", "minimum": 0 },
						"url": { "type": "string", "format": "uri", "description": "The day in the Pebble Audio viewer." }
					},
					"required": ["day", "url"],
					"additionalProperties": false
				}
				""")),
		new(
			FollowUpCreated,
			"New reminder",
			"A reminder was added to the user's list: one they asked for, or a follow-up the app noticed that they said " +
			"yes to. Follow-ups still waiting for their review are not announced, and neither are reminders an assistant " +
			"created.",
			Schema(NoArguments),
			Schema("""
				{
					"type": "object",
					"properties": {
						"followUpId": { "type": "string" },
						"text": { "type": "string", "description": "What the reminder is for." },
						"why": { "type": "string" },
						"dueAt": { "type": "string", "format": "date-time" },
						"conversationId": { "type": "string", "description": "The conversation it came from, if any." },
						"url": { "type": "string", "format": "uri", "description": "That conversation in the Pebble Audio viewer." }
					},
					"required": ["followUpId", "text"],
					"additionalProperties": false
				}
				""")),
	];

	public static EventDefinition? Find(string? name) => All.FirstOrDefault(e => e.Name == name);

	public static string Label(string name) => Find(name)?.Label ?? name;

	private static JsonObject Schema(string json) => JsonNode.Parse(json)!.AsObject();
}

/// <summary><c>data</c> of <c>day_recap.ready</c>.</summary>
public sealed record DayRecapReadyData(
	[property: JsonPropertyName("day")] string Day,
	[property: JsonPropertyName("timeZone")] string? TimeZone,
	[property: JsonPropertyName("headline")] string? Headline,
	[property: JsonPropertyName("summary")] string? Summary,
	[property: JsonPropertyName("conversationCount")] int ConversationCount,
	[property: JsonPropertyName("url")] string Url);

/// <summary><c>data</c> of <c>followup.created</c>.</summary>
public sealed record FollowUpCreatedData(
	[property: JsonPropertyName("followUpId")] string FollowUpId,
	[property: JsonPropertyName("text")] string Text,
	[property: JsonPropertyName("why")] string? Why,
	[property: JsonPropertyName("dueAt")] DateTimeOffset? DueAt,
	[property: JsonPropertyName("conversationId")] string? ConversationId,
	[property: JsonPropertyName("url")] string? Url);
