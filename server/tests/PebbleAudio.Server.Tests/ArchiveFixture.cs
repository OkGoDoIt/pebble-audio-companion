using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// A synthetic archive, sent through the phone's own sync: a day a week ago with kitchen tiles with Sam, a dentist
/// booking, the product launch plan with Priya and Leo, and a stretch of music; badminton with another Sam the day
/// before; a launch check-in the day after. Recaps, briefs, coverage, follow-ups, a note, and people come with it.
/// Times are in Asia/Jakarta (UTC+7).
/// </summary>
internal sealed class ArchiveFixture
{
	public const long V = 1_791_999_175_292;
	public const string Zone = "Asia/Jakarta";
	public static readonly TimeSpan Offset = TimeSpan.FromHours(7);

	public ArchiveFixture(DateOnly? day = null)
	{
		var zone = LogicalDays.Zone(Zone);
		Today = LogicalDays.Of(DateTimeOffset.UtcNow, zone);
		Day = day ?? Today.AddDays(-7);
	}

	/// <summary>The person's today, in the fixture's time zone.</summary>
	public DateOnly Today { get; }

	/// <summary>The fixture's main day: kitchen tiles, the dentist, the launch plan, and music.</summary>
	public DateOnly Day { get; }

	/// <summary>The week's first day (Sunday), as the app keys weeks.</summary>
	public DateOnly WeekStart => Day.AddDays(-(int)Day.DayOfWeek);

	/// <summary>A local wall-clock time on a day, as an instant.</summary>
	public static DateTimeOffset At(DateOnly day, int hour, int minute, int second = 0) =>
		new DateTimeOffset(day.ToDateTime(new TimeOnly(hour, minute, second)), Offset).ToUniversalTime();

	public DateTimeOffset At(int hour, int minute, int second = 0) => At(Day, hour, minute, second);

	/// <summary>Every item of the archive, as one batch.</summary>
	public JsonObject[] Items()
	{
		var d = Day;
		var before = d.AddDays(-1);
		var after = d.AddDays(1);
		return
		[
			Item("person", "person-alex", Person("Alex")),
			Item("person", "person-sam", Person("Sam")),
			Item("person", "person-sam-k", Person("Sam")),
			Item("person", "person-priya", Person("Priya")),
			Item("person", "person-leo", Person("Leo")),

			Item("conversation", "conv-kitchen", Conversation(
				d, At(10, 5), At(10, 41), "Kitchen tiles with Sam",
				"Sam and you compare three tile samples for the kitchen renovation and settle on the matte grey ones; Sam needs the samples back before ordering, and the contractor starts on the 28th.",
				["kitchen renovation", "home"],
				[Speaker("1", "person-alex", "Alex"), Speaker("2", "person-sam", "Sam")],
				[Gap(At(10, 9), At(10, 10), "lost", origin: "watch"), Gap(At(10, 14), At(10, 16), "quiet"), Gap(At(10, 20), At(10, 20, 20), "quiet")],
				recordedMinutes: 33)),
			Item("transcript", "conv-kitchen", Transcript("conv-kitchen",
			[
				Turn(At(10, 5, 12), "2", "Sam", "The matte tiles hide water spots better than the glossy ones.", 0.93),
				Turn(At(10, 6, 30), "1", "Alex", "Then matte grey it is, as long as the grout matches.", 0.91),
				Marker(At(10, 9), At(10, 10), "lost", origin: "watch"),
				Turn(At(10, 11, 2), "2", "Sam", "The contractor starts on the twenty-eighth, so I need the samples back first.", 0.88),
				Marker(At(10, 14), At(10, 16), "quiet"),
				Turn(At(10, 26, 0), "1", "Alex", "I'll send you the samples tonight.", 0.95),
				Turn(At(10, 30, 0), "2", "Sam", "mumble budget something", 0.42),
				Marker(At(10, 33), At(10, 34), "masked", descriptor: "music"),
			])),

			Item("conversation", "conv-dentist", Conversation(
				d, At(11, 30), At(11, 36), "Booking a dentist appointment",
				"You book a cleaning at the dentist for Thursday at 3 PM.",
				["health"],
				[Speaker("1", "person-alex", "Alex"), Speaker("2", null, null)],
				[],
				recordedMinutes: 6)),
			Item("transcript", "conv-dentist", Transcript("conv-dentist",
			[
				Turn(At(11, 30, 10), "1", "Alex", "I'd like a cleaning appointment, please.", 0.94),
				Turn(At(11, 31, 0), "2", null, "Thursday at three works. We'll text you a reminder.", 0.9),
			])),

			Item("conversation", "conv-launch", Conversation(
				d, At(14, 0), At(14, 50), "Product launch plan with Priya and Leo",
				"Priya, Leo, and you agree the product launch moves to the 5th; the press kit is due Friday and Leo owns the demo video.",
				["product launch", "work"],
				[Speaker("1", "person-alex", "Alex"), Speaker("2", "person-priya", "Priya"), Speaker("3", "person-leo", "Leo")],
				[Gap(At(14, 20), At(14, 22), "quiet", reason: "watchPause")],
				recordedMinutes: 48)),
			Item("transcript", "conv-launch", Transcript("conv-launch",
			[
				Turn(At(14, 1, 0), "2", "Priya", "Let's move the product launch to the fifth.", 0.92),
				Turn(At(14, 12, 0), "3", "Leo", "I'll own the demo video.", 0.9),
				Turn(At(14, 13, 0), "1", "Alex", "And the press kit is due Friday.", 0.93),
			])),

			Item("conversation", "conv-music", Conversation(
				d, At(16, 0), At(16, 20), "Music in the café", null, [], [], [], recordedMinutes: 20, kind: "noConversation", descriptor: "music")),

			Item("conversation", "conv-badminton", Conversation(
				before, At(before, 18, 0), At(before, 18, 30), "Badminton on Saturday",
				"Sam from the club asks you to join the Saturday badminton game.",
				["sports"],
				[Speaker("1", "person-alex", "Alex"), Speaker("2", "person-sam-k", "Sam")],
				[],
				recordedMinutes: 30)),

			Item("conversation", "conv-launch-2", Conversation(
				after, At(after, 9, 30), At(after, 10, 0), "Launch date check-in with Priya",
				"Priya confirms the product launch date and asks for the press kit draft.",
				["product launch", "work"],
				[Speaker("1", "person-alex", "Alex"), Speaker("2", "person-priya", "Priya")],
				[],
				recordedMinutes: 30)),

			Item("recap", Key(d), Recap(d, "Tiles, teeth, and the launch", "Kitchen tiles with Sam, a dentist booking, and the launch plan with Priya and Leo.", "You started with Sam on the kitchen renovation: matte grey tiles, and the contractor starts on the 28th. You booked a dentist cleaning for Thursday. In the afternoon Priya, Leo, and you moved the product launch to the 5th.", ["conv-kitchen", "conv-dentist", "conv-launch", "conv-music"])),
			Item("brief", $"week:{Key(WeekStart)}", Brief("week", $"week:{Key(WeekStart)}", WeekStart, WeekStart.AddDays(6), "A renovation taking shape", "Tiles chosen, a dentist booked, and the launch moved to the 5th.", "The kitchen renovation took shape this week, and the product launch moved to the 5th.")),
			Item("brief", $"month:{d:yyyy-MM}", Brief("month", $"month:{d:yyyy-MM}", new DateOnly(d.Year, d.Month, 1), new DateOnly(d.Year, d.Month, DateTime.DaysInMonth(d.Year, d.Month)), "A month of launches", "The launch, the kitchen, and the club.", "A month spent on the product launch and the kitchen.")),
			Item("coverage", Key(d), Coverage(d)),

			Item("followUp", "fu-tiles", FollowUp("Send Sam the tile samples", "conv-kitchen", At(10, 26), At(10, 45), quote: "I'll send you the samples tonight.", why: "Sam needs them before ordering.", dueAt: At(d.AddDays(2), 18, 0), priority: 2)),
			Item("followUp", "fu-dentist", FollowUp("Book the dentist cleaning", "conv-dentist", At(11, 31), At(11, 40), done: true, completedAt: At(11, 36))),
			Item("followUp", "fu-launch", FollowUp("Draft the launch announcement", "conv-launch", At(14, 13), At(15, 0), snoozedUntil: DateTimeOffset.UtcNow.AddDays(3))),
			Item("note", "note-launch", Note("conv-launch", "Launch checklist", "Press kit by Friday; Leo owns the demo video.", At(14, 12), At(15, 30))),
		];
	}

	/// <summary>Seeds a new user's archive through a linked phone with the fixture, and returns the phone.</summary>
	public static async Task<(Phone Phone, ArchiveFixture Fixture)> SeedAsync(ArchiveServerFactory factory, bool clips = false, bool edits = false)
	{
		var userId = await factory.CreateUserAsync();
		var phone = await Phone.LinkAsync(factory, userId);
		var fixture = new ArchiveFixture();
		var answer = await phone.BatchAsync(fixture.Items());
		Assert.Equal(0, answer.GetProperty("rejected").GetArrayLength());
		await phone.AllowAsync(clips, edits);
		return (phone, fixture);
	}

	/// <summary>An MCP client signed in with a new personal token of the user.</summary>
	public static async Task<McpClient> ConnectAsync(ArchiveServerFactory factory, Guid userId, TokenAccess access, string name = "Claude Code on the test Mac")
	{
		string secret;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			(_, secret) = await scope.ServiceProvider.GetRequiredService<ApiTokenService>().CreateAsync(userId, name, access, CancellationToken.None);
		}

		var http = factory.CreateClient();
		var transport = new HttpClientTransport(
			new HttpClientTransportOptions
			{
				Endpoint = new Uri(http.BaseAddress!, "/mcp"),
				TransportMode = HttpTransportMode.StreamableHttp,
				AdditionalHeaders = new Dictionary<string, string> { ["Authorization"] = $"Bearer {secret}" },
			},
			http,
			NullLoggerFactory.Instance,
			ownsHttpClient: true);
		return await McpClient.CreateAsync(transport);
	}

	/// <summary>
	/// Calls a tool and returns its structured content, checking the shape every result shares and that it matches the
	/// output schema the tool declares in <c>tools/list</c> (OpenAI: structured content must match it).
	/// </summary>
	public static async Task<JsonElement> CallAsync(McpClient mcp, string tool, Dictionary<string, object?>? arguments = null)
	{
		var result = await mcp.CallToolAsync(tool, arguments ?? []);
		Assert.True(result.IsError != true, $"{tool} answered with an error: {Text(result)}");
		var structured = result.StructuredContent!.Value;
		Assert.Equal("summary", structured.EnumerateObject().First().Name);
		if (!Schemas.TryGetValue(mcp, out var schemas))
		{
			schemas = (await mcp.ListToolsAsync())
				.Where(t => t.ProtocolTool.OutputSchema is not null)
				.ToDictionary(t => t.Name, t => t.ProtocolTool.OutputSchema!.Value.Clone());
			Schemas.AddOrUpdate(mcp, schemas);
		}

		var problems = new List<string>();
		SchemaCheck.Validate(schemas[tool], structured, tool, problems);
		Assert.True(problems.Count == 0, $"{tool}'s structured content does not match its output schema: {string.Join("; ", problems.Take(5))}");
		// search and fetch: the JSON alone, as OpenAI's connector contract has it; every other tool: the summary, then it.
		var document = tool is "search" or "fetch";
		Assert.Equal(document ? 1 : 2, result.Content.Count);
		if (!document)
		{
			Assert.Equal(structured.GetProperty("summary").GetString(), Assert.IsType<TextContentBlock>(result.Content[0]).Text);
		}

		Assert.True(
			JsonNode.DeepEquals(JsonNode.Parse(Assert.IsType<TextContentBlock>(result.Content[^1]).Text), JsonNode.Parse(structured.GetRawText())),
			$"{tool}'s text content is not its structured content.");
		return structured.Clone();
	}

	private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<McpClient, Dictionary<string, JsonElement>> Schemas = new();

	public static string Text(CallToolResult result) =>
		string.Join("\n", result.Content.OfType<TextContentBlock>().Select(t => t.Text));

	public static string Key(DateOnly day) => day.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);

	// Payloads, as the phone writes them (sync-protocol.md §2)

	public static JsonObject Item(string kind, string id, JsonObject payload, long version = V) => Wire.Item(kind, id, version, payload: payload);

	public static JsonObject Person(string name) => new() { ["name"] = name };

	public static JsonObject Speaker(string label, string? personId, string? name) => new() { ["label"] = label, ["name"] = name, ["personId"] = personId };

	public static JsonObject Gap(DateTimeOffset start, DateTimeOffset end, string kind, string? origin = null, string? reason = null)
	{
		var gap = new JsonObject { ["endedAt"] = Wire.T(end), ["kind"] = kind, ["startedAt"] = Wire.T(start) };
		if (origin is not null)
		{
			gap["origin"] = origin;
		}

		if (reason is not null)
		{
			gap["reason"] = reason;
		}

		return gap;
	}

	public static JsonObject Conversation(
		DateOnly day,
		DateTimeOffset start,
		DateTimeOffset end,
		string title,
		string? summary,
		string[] tags,
		JsonObject[] people,
		JsonObject[] gaps,
		int recordedMinutes,
		string kind = "conversation",
		string? descriptor = null) => new()
		{
			["annotationModel"] = "gpt-6-luna",
			["annotationProvider"] = "openai-chat",
			["contentDescriptor"] = descriptor,
			["contentKind"] = kind,
			["dayKey"] = Key(day),
			["endedAt"] = Wire.T(end),
			["gaps"] = new JsonArray([.. gaps]),
			["hasMissingAudio"] = gaps.Any(g => g["kind"]!.GetValue<string>() == "lost"),
			["isFinal"] = true,
			["mostlyQuiet"] = false,
			["people"] = new JsonArray([.. people]),
			["pieces"] = new JsonArray(new JsonObject { ["endMediaMs"] = null, ["endedAt"] = Wire.T(end), ["ordinal"] = 0, ["segmentId"] = $"seg-{title.GetHashCode():x}", ["startMediaMs"] = 0, ["startedAt"] = Wire.T(start) }),
			["provisional"] = false,
			["recordedMs"] = recordedMinutes * 60_000L,
			["startReason"] = "topicChange",
			["startedAt"] = Wire.T(start),
			["state"] = "closed",
			["summary"] = summary,
			["tags"] = new JsonArray([.. tags.Select(t => (JsonNode)t)]),
			["timeZone"] = Zone,
			["title"] = title,
			["titleEditedByUser"] = false,
		};

	public static JsonObject Turn(DateTimeOffset at, string speaker, string? name, string text, double confidence) => new()
	{
		["at"] = Wire.T(at),
		["confidence"] = confidence,
		["endAt"] = Wire.T(at.AddSeconds(6)),
		["kind"] = "turn",
		["name"] = name,
		["speaker"] = speaker,
		["text"] = text,
	};

	public static JsonObject Marker(DateTimeOffset at, DateTimeOffset end, string kind, string? origin = null, string? descriptor = null)
	{
		var marker = new JsonObject { ["at"] = Wire.T(at), ["endAt"] = Wire.T(end), ["kind"] = kind };
		if (origin is not null)
		{
			marker["origin"] = origin;
		}

		if (descriptor is not null)
		{
			marker["descriptor"] = descriptor;
		}

		return marker;
	}

	public static JsonObject Transcript(string conversationId, JsonObject[] items)
	{
		var text = string.Join("\n", items.Where(i => i["kind"]!.GetValue<string>() == "turn").Select(i => $"{i["name"]?.GetValue<string>() ?? "Speaker " + i["speaker"]!.GetValue<string>()}: {i["text"]!.GetValue<string>()}"));
		return new JsonObject
		{
			["charCount"] = text.Length,
			["conversationId"] = conversationId,
			["items"] = new JsonArray([.. items]),
			["language"] = null,
			["model"] = "stt-async-v5",
			["provider"] = "soniox",
			["sourceHash"] = "5f2c",
			["text"] = text,
		};
	}

	public static JsonObject Recap(DateOnly day, string headline, string line, string text, string[] conversationIds) => new()
	{
		["conversationIds"] = new JsonArray([.. conversationIds.Select(c => (JsonNode)c)]),
		["dayKey"] = Key(day),
		["headline"] = headline,
		["lineSummary"] = line,
		["model"] = "gpt-6-luna",
		["provider"] = "openai-chat",
		["shortText"] = line,
		["text"] = text,
		["timeZone"] = Zone,
	};

	public static JsonObject Brief(string kind, string key, DateOnly start, DateOnly end, string headline, string line, string text) => new()
	{
		["endDay"] = Key(end),
		["headline"] = headline,
		["kind"] = kind,
		["lineSummary"] = line,
		["model"] = "gpt-6-luna",
		["periodKey"] = key,
		["provider"] = "openai-chat",
		["startDay"] = Key(start),
		["text"] = text,
	};

	public JsonObject Coverage(DateOnly day) => new()
	{
		["dayKey"] = Key(day),
		["missingMs"] = 120_000,
		["quietMs"] = 9_000_000,
		["recordedMs"] = 7_800_000,
		["spans"] = new JsonArray(
			new JsonObject { ["endedAt"] = Wire.T(At(day, 12, 0)), ["kind"] = "recorded", ["startedAt"] = Wire.T(At(day, 9, 0)) },
			new JsonObject { ["endedAt"] = Wire.T(At(day, 13, 0)), ["kind"] = "paused", ["startedAt"] = Wire.T(At(day, 12, 0)) },
			new JsonObject { ["endedAt"] = Wire.T(At(day, 17, 0)), ["kind"] = "recorded", ["startedAt"] = Wire.T(At(day, 13, 0)) }),
		["timeZone"] = Zone,
	};

	public static JsonObject FollowUp(
		string text,
		string? source,
		DateTimeOffset? sourceAt,
		DateTimeOffset createdAt,
		string? quote = null,
		string? why = null,
		DateTimeOffset? dueAt = null,
		int priority = 1,
		bool done = false,
		DateTimeOffset? completedAt = null,
		DateTimeOffset? snoozedUntil = null,
		string origin = "ai",
		string? stage = null)
	{
		var followUp = new JsonObject
		{
			["archivedAt"] = null,
			["completedAt"] = completedAt is { } c ? Wire.T(c) : null,
			["createdAt"] = Wire.T(createdAt),
			["done"] = done,
			["dueAt"] = dueAt is { } due ? Wire.T(due) : null,
			["editedAt"] = null,
			["origin"] = origin,
			["priority"] = priority,
			["quote"] = quote,
			["snoozedUntil"] = snoozedUntil is { } s ? Wire.T(s) : null,
			["sourceApproximate"] = false,
			["sourceAt"] = sourceAt is { } at ? Wire.T(at) : null,
			["sourceConversationId"] = source,
			["sourceEndAt"] = null,
			["text"] = text,
			["why"] = why,
		};

		// A phone from before stages sends none; the fixture's own rows are written that way.
		if (stage is not null)
		{
			followUp["stage"] = stage;
		}

		return followUp;
	}

	public static JsonObject Note(string? conversationId, string title, string body, DateTimeOffset citedAt, DateTimeOffset createdAt) => new()
	{
		["body"] = body,
		["citations"] = conversationId is null ? new JsonArray() : new JsonArray(new JsonObject { ["at"] = Wire.T(citedAt), ["conversationId"] = conversationId, ["endAt"] = null }),
		["conversationId"] = conversationId,
		["createdAt"] = Wire.T(createdAt),
		["editedAt"] = null,
		["model"] = null,
		["origin"] = "user",
		["provider"] = null,
		["templateId"] = "meeting-notes",
		["title"] = title,
	};
}

/// <summary>
/// The part of JSON Schema the SDK's output schemas use: <c>type</c> (one or a list), <c>required</c>,
/// <c>properties</c>, and <c>items</c>.
/// </summary>
internal static class SchemaCheck
{
	public static void Validate(JsonElement schema, JsonElement value, string path, List<string> problems)
	{
		if (schema.ValueKind != JsonValueKind.Object)
		{
			return;
		}

		if (schema.TryGetProperty("type", out var type))
		{
			var types = type.ValueKind == JsonValueKind.Array ? [.. type.EnumerateArray().Select(t => t.GetString())] : new[] { type.GetString() };
			if (!types.Any(t => Is(t, value)))
			{
				problems.Add($"{path} is {value.ValueKind}, not {string.Join(" or ", types)}");
				return;
			}
		}

		if (value.ValueKind == JsonValueKind.Object)
		{
			if (schema.TryGetProperty("required", out var required))
			{
				foreach (var name in required.EnumerateArray().Select(r => r.GetString()!))
				{
					if (!value.TryGetProperty(name, out _))
					{
						problems.Add($"{path}.{name} is required and missing");
					}
				}
			}

			if (schema.TryGetProperty("properties", out var properties))
			{
				foreach (var property in properties.EnumerateObject())
				{
					if (value.TryGetProperty(property.Name, out var child))
					{
						Validate(property.Value, child, $"{path}.{property.Name}", problems);
					}
				}
			}
		}

		if (value.ValueKind == JsonValueKind.Array && schema.TryGetProperty("items", out var items))
		{
			var index = 0;
			foreach (var item in value.EnumerateArray())
			{
				Validate(items, item, $"{path}[{index++}]", problems);
			}
		}
	}

	private static bool Is(string? type, JsonElement value) => type switch
	{
		"object" => value.ValueKind == JsonValueKind.Object,
		"array" => value.ValueKind == JsonValueKind.Array,
		"string" => value.ValueKind == JsonValueKind.String,
		"number" => value.ValueKind == JsonValueKind.Number,
		"integer" => value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out _),
		"boolean" => value.ValueKind is JsonValueKind.True or JsonValueKind.False,
		"null" => value.ValueKind == JsonValueKind.Null,
		_ => true,
	};
}
