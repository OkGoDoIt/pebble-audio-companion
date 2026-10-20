using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// A stand-in for the iPhone app's sync: it links with a code and sends exactly the headers and JSON the app does
/// (ios/PebbleAudioKit/Sources/CompanionRuntime/ArchiveSync).
/// </summary>
internal sealed class Phone(ArchiveServerFactory factory, string token, Guid deviceId, Guid userId) : IDisposable
{
	private readonly HttpClient _http = factory.CreateClient();

	public string Token { get; } = token;

	public Guid DeviceId { get; } = deviceId;

	public Guid UserId { get; } = userId;

	/// <summary>Mints a code the way the admin page does and links with it.</summary>
	public static async Task<Phone> LinkAsync(ArchiveServerFactory factory, Guid userId, string name = "Roger's iPhone")
	{
		string code;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			code = (await scope.ServiceProvider.GetRequiredService<PhoneLinkService>().MintAsync(userId, CancellationToken.None)).Code;
		}

		using var http = factory.CreateClient();
		var response = await http.SendAsync(LinkRequest(code, name));
		Assert.Equal(HttpStatusCode.Created, response.StatusCode);
		using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
		var root = body.RootElement;
		Assert.Equal(userId.ToString(), root.GetProperty("userId").GetString());
		Assert.True(DateTimeOffset.UtcNow - root.GetProperty("serverTime").GetDateTimeOffset() < TimeSpan.FromMinutes(1));
		return new Phone(
			factory,
			root.GetProperty("deviceToken").GetString()!,
			Guid.Parse(root.GetProperty("deviceId").GetString()!),
			userId);
	}

	/// <summary><c>POST /link</c> as the app sends it: no token, a normalized code, the protocol header.</summary>
	public static HttpRequestMessage LinkRequest(string code, string name = "Roger's iPhone")
	{
		var request = new HttpRequestMessage(HttpMethod.Post, "/link")
		{
			Content = Json(new JsonObject { ["code"] = code, ["deviceName"] = name, ["appVersion"] = "1.4", ["appBuild"] = "812" }),
		};
		request.Headers.Add(SyncProtocol.VersionHeader, "1");
		return request;
	}

	public HttpRequestMessage Request(HttpMethod method, string path, HttpContent? content = null)
	{
		var request = new HttpRequestMessage(method, path) { Content = content };
		request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Token);
		request.Headers.Add(SyncProtocol.VersionHeader, "1");
		request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
		return request;
	}

	public Task<HttpResponseMessage> SendAsync(HttpRequestMessage request) => _http.SendAsync(request);

	public Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, HttpContent? content = null) =>
		_http.SendAsync(Request(method, path, content));

	/// <summary><c>PUT /sync/batch</c> with these items; returns the parsed 200 answer.</summary>
	public async Task<JsonElement> BatchAsync(params JsonObject[] items)
	{
		var response = await SendAsync(HttpMethod.Put, "/sync/batch", BatchBody(DeviceId, items));
		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		return JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.Clone();
	}

	public async Task<JsonElement> GetJsonAsync(string path)
	{
		var response = await SendAsync(HttpMethod.Get, path);
		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		return JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.Clone();
	}

	public async Task AllowAsync(bool clips, bool edits)
	{
		var response = await SendAsync(HttpMethod.Put, "/sync/preferences", Json(new JsonObject { ["clips"] = clips, ["edits"] = edits }));
		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
	}

	public static HttpContent BatchBody(Guid deviceId, IEnumerable<JsonObject> items) =>
		Json(new JsonObject
		{
			["deviceId"] = deviceId.ToString(),
			// Copies, so one item can go in more than one batch (a replay).
			["items"] = new JsonArray([.. items.Select(i => i.DeepClone())]),
			["sentAt"] = SyncJson.Format(DateTimeOffset.UtcNow),
		});

	public static HttpContent Json(JsonNode node) =>
		new StringContent(node.ToJsonString(), Encoding.UTF8, "application/json");

	public static string[] Ids(JsonElement answer, string list) =>
		[.. answer.GetProperty(list).EnumerateArray().Select(e => $"{e.GetProperty("kind").GetString()}:{e.GetProperty("id").GetString()}")];

	public void Dispose() => _http.Dispose();
}

/// <summary>Batch items and §2 payloads with the keys and values the app writes.</summary>
internal static class Wire
{
	public static readonly DateTimeOffset Start = new(2026, 10, 14, 13, 5, 9, 754, TimeSpan.Zero);

	public static string T(DateTimeOffset at) => SyncJson.Format(at);

	public static JsonObject Item(string kind, string id, long version, string op = "upsert", JsonObject? payload = null)
	{
		var item = new JsonObject
		{
			["changedAt"] = T(DateTimeOffset.FromUnixTimeMilliseconds(version)),
			["id"] = id,
			["kind"] = kind,
			["op"] = op,
		};
		if (payload is not null)
		{
			item["payload"] = payload;
		}

		item["version"] = version;
		return item;
	}

	/// <summary>
	/// A conversation as the app sends it: a whole-segment first piece (startMediaMs 0, endMediaMs null), a
	/// second piece cut inside its segment, a loss from the link, one of unknown origin, the watch's power-save
	/// pause, and plain quiet.
	/// </summary>
	public static JsonObject Conversation(string title, string summary = "Why the watch kept showing a paused audiobook as playing.", DateTimeOffset? start = null)
	{
		var s = start ?? Start;
		return new JsonObject
		{
			["annotationModel"] = "gpt-6-luna",
			["annotationProvider"] = "openai-chat",
			["contentDescriptor"] = null,
			["contentKind"] = "conversation",
			["dayKey"] = "2026-10-14",
			["endedAt"] = T(s.AddMinutes(23)),
			["gaps"] = new JsonArray(
				new JsonObject { ["endedAt"] = T(s.AddMinutes(5)), ["kind"] = "lost", ["origin"] = "link", ["startedAt"] = T(s.AddMinutes(4)) },
				new JsonObject { ["endedAt"] = T(s.AddMinutes(7)), ["kind"] = "lost", ["origin"] = "unknown", ["startedAt"] = T(s.AddMinutes(6)) },
				new JsonObject { ["endedAt"] = T(s.AddMinutes(11)), ["kind"] = "quiet", ["reason"] = "watchPause", ["startedAt"] = T(s.AddMinutes(9)) },
				new JsonObject { ["endedAt"] = T(s.AddMinutes(13)), ["kind"] = "quiet", ["startedAt"] = T(s.AddMinutes(12)) }),
			["hasMissingAudio"] = true,
			["isFinal"] = true,
			["mostlyQuiet"] = false,
			["people"] = new JsonArray(new JsonObject { ["label"] = "1", ["name"] = "Roger", ["personId"] = "person-roger" }),
			["pieces"] = new JsonArray(
				new JsonObject { ["endMediaMs"] = null, ["endedAt"] = T(s.AddMinutes(15)), ["ordinal"] = 0, ["segmentId"] = "seg-1791997844787-ed737f28-62", ["startMediaMs"] = 0, ["startedAt"] = T(s) },
				new JsonObject { ["endMediaMs"] = 480_000, ["endedAt"] = T(s.AddMinutes(23)), ["ordinal"] = 1, ["segmentId"] = "seg-1791997844787-ed737f28-63", ["startMediaMs"] = 0, ["startedAt"] = T(s.AddMinutes(15)) }),
			["provisional"] = false,
			["recordedMs"] = 1_123_000,
			["startReason"] = "topicChange",
			["startedAt"] = T(s),
			["state"] = "closed",
			["summary"] = summary,
			["tags"] = new JsonArray("Pebble", "firmware"),
			["timeZone"] = "Asia/Jakarta",
			["title"] = title,
			["titleEditedByUser"] = false,
		};
	}

	/// <summary>A transcript as the app sends it; its language is null.</summary>
	public static JsonObject Transcript(string conversationId, string said)
	{
		var text = $"Roger: {said}";
		return new JsonObject
		{
			["charCount"] = text.Length,
			["conversationId"] = conversationId,
			["items"] = new JsonArray(
				new JsonObject { ["at"] = T(Start), ["confidence"] = 0.93, ["endAt"] = T(Start.AddSeconds(8)), ["kind"] = "turn", ["name"] = "Roger", ["speaker"] = "1", ["text"] = said },
				new JsonObject { ["at"] = T(Start.AddMinutes(4)), ["endAt"] = T(Start.AddMinutes(5)), ["kind"] = "lost", ["origin"] = "link" },
				new JsonObject { ["at"] = T(Start.AddMinutes(9)), ["endAt"] = T(Start.AddMinutes(11)), ["kind"] = "quiet" },
				new JsonObject { ["at"] = T(Start.AddMinutes(14)), ["descriptor"] = "music", ["endAt"] = T(Start.AddMinutes(15)), ["kind"] = "masked" }),
			["language"] = null,
			["model"] = "stt-async-v5",
			["provider"] = "soniox",
			["sourceHash"] = "5f2c",
			["text"] = text,
		};
	}

	public static JsonObject FollowUp(string text, string? sourceConversationId, string origin = "ai") => new()
	{
		["archivedAt"] = null,
		["completedAt"] = null,
		["createdAt"] = T(Start.AddMinutes(30)),
		["done"] = false,
		["dueAt"] = null,
		["editedAt"] = null,
		["origin"] = origin,
		["priority"] = 1,
		["quote"] = "I'll look at the AMS rate tonight.",
		["snoozedUntil"] = null,
		["sourceApproximate"] = false,
		["sourceAt"] = sourceConversationId is null ? null : T(Start.AddMinutes(2)),
		["sourceConversationId"] = sourceConversationId,
		["sourceEndAt"] = sourceConversationId is null ? null : T(Start.AddMinutes(3)),
		["text"] = text,
		["why"] = null,
	};

	public static JsonObject Note(string conversationId, string body) => new()
	{
		["body"] = body,
		["citations"] = new JsonArray(new JsonObject { ["at"] = T(Start.AddMinutes(2)), ["conversationId"] = conversationId, ["endAt"] = null }),
		["conversationId"] = conversationId,
		["createdAt"] = T(Start.AddMinutes(40)),
		["editedAt"] = null,
		["model"] = null,
		["origin"] = "user",
		["provider"] = null,
		["templateId"] = "meeting-notes",
		["title"] = "Notes",
	};

	public static JsonObject Recap(string conversationId) => new()
	{
		["conversationIds"] = new JsonArray(conversationId),
		["dayKey"] = "2026-10-14",
		["headline"] = "Debugging the watch",
		["lineSummary"] = "An afternoon on audiobook playback.",
		["model"] = "gpt-6-luna",
		["provider"] = "openai-chat",
		["shortText"] = "Audiobook state.",
		["text"] = "Most of the afternoon went to why the watch showed a paused audiobook as playing.",
		["timeZone"] = "Asia/Jakarta",
	};

	public static JsonObject Brief() => new()
	{
		["endDay"] = "2026-10-17",
		["headline"] = "A week of firmware",
		["kind"] = "week",
		["lineSummary"] = "Mostly the watch.",
		["model"] = "gpt-6-luna",
		["periodKey"] = "week:2026-10-11",
		["provider"] = "openai-chat",
		["startDay"] = "2026-10-11",
		["text"] = "The week was mostly about the watch.",
	};

	public static JsonObject Person(string name) => new() { ["name"] = name };

	public static JsonObject Coverage() => new()
	{
		["dayKey"] = "2026-10-14",
		["missingMs"] = 120_000,
		["quietMs"] = 9_000_000,
		["recordedMs"] = 31_200_000,
		["spans"] = new JsonArray(
			new JsonObject { ["endedAt"] = T(Start.AddHours(1)), ["kind"] = "recorded", ["startedAt"] = T(Start) },
			new JsonObject { ["endedAt"] = T(Start.AddHours(2)), ["kind"] = "paused", ["startedAt"] = T(Start.AddHours(1)) },
			new JsonObject { ["endedAt"] = T(Start.AddHours(3)), ["kind"] = "off", ["startedAt"] = T(Start.AddHours(2)) }),
		["timeZone"] = "Asia/Jakarta",
	};
}
