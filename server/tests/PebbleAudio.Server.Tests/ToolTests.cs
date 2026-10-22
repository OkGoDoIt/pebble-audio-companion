using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Mcp;
using PebbleAudio.Server.Settings;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// The archive's MCP tools as an assistant uses them, against a seeded synthetic archive (docs/tool-results.md).
/// </summary>
[Collection(ServerCollection.Name)]
public sealed class ToolTests(ArchiveServerFactory factory)
{
	private const string Origin = ArchiveServerFactory.PublicOrigin;

	private static readonly string[] ReadTools =
		["get_status", "list_days", "get_day", "get_brief", "list_conversations", "get_conversation", "search", "fetch", "list_follow_ups", "get_people", "get_tags", "get_audio"];

	private static readonly string[] WriteToolNames = ["create_follow_up", "update_follow_up", "create_note"];

	[Fact]
	public async Task The_read_tools_answer_from_a_seeded_archive_in_the_documented_shapes()
	{
		var (phone, fx) = await ArchiveFixture.SeedAsync(factory);
		using var linked = phone;
		var day = ArchiveFixture.Key(fx.Day);
		await using var mcp = await ArchiveFixture.ConnectAsync(factory, phone.UserId, TokenAccess.Read);

		// Every tool is annotated for the hosts' approval prompts, with ChatGPT's short status strings and a schema.
		var tools = await mcp.ListToolsAsync();
		foreach (var name in ReadTools)
		{
			var tool = Assert.Single(tools, t => t.Name == name).ProtocolTool;
			Assert.False(string.IsNullOrWhiteSpace(tool.Title));
			Assert.Equal((true, false, false), (tool.Annotations?.ReadOnlyHint, tool.Annotations?.DestructiveHint, tool.Annotations?.OpenWorldHint));
			Assert.NotNull(tool.OutputSchema);
			Assert.Equal("""[{"type":"oauth2","scopes":["archive:read"]}]""", tool.Meta?["securitySchemes"]?.ToJsonString());
			foreach (var key in new[] { "openai/toolInvocation/invoking", "openai/toolInvocation/invoked" })
			{
				var text = tool.Meta?[key]?.GetValue<string>();
				Assert.False(string.IsNullOrEmpty(text), $"{name} has no {key}");
				Assert.True(text.Length <= 64, $"{name}'s {key} is {text.Length} characters");
			}
		}

		// A read-only connection does not see the write tools.
		Assert.DoesNotContain(tools, t => WriteToolNames.Contains(t.Name));
		Assert.True(Instructions.Lead.Length <= Instructions.LeadLimit, $"The instructions' lead is {Instructions.Lead.Length} characters.");

		var status = await ArchiveFixture.CallAsync(mcp, "get_status");
		Assert.Equal(6, status.GetProperty("counts").GetProperty("conversations").GetInt32());
		Assert.Equal(5, status.GetProperty("counts").GetProperty("people").GetInt32());
		Assert.Equal(ArchiveFixture.Key(fx.Day.AddDays(-1)), status.GetProperty("firstDay").GetString());
		Assert.Equal(ArchiveFixture.Zone, status.GetProperty("timeZone").GetString());
		Assert.EndsWith("+07:00", status.GetProperty("serverTime").GetString());
		Assert.Equal("all", status.GetProperty("sharing").GetProperty("kind").GetString());
		Assert.False(status.GetProperty("allowed").GetProperty("edits").GetBoolean());
		Assert.False(status.GetProperty("canWrite").GetBoolean());
		Assert.StartsWith("Your archive holds 6 conversations from", status.GetProperty("summary").GetString());

		// list_days: newest first, days without anything left out, minutes from coverage when the phone sent it.
		var days = await ArchiveFixture.CallAsync(mcp, "list_days", new() { ["from"] = ArchiveFixture.Key(fx.Day.AddDays(-3)), ["to"] = ArchiveFixture.Key(fx.Day.AddDays(3)) });
		Assert.Equal(
			[ArchiveFixture.Key(fx.Day.AddDays(1)), day, ArchiveFixture.Key(fx.Day.AddDays(-1))],
			days.GetProperty("days").EnumerateArray().Select(d => d.GetProperty("day").GetString()));
		var listed = days.GetProperty("days")[1];
		Assert.Equal(("Tiles, teeth, and the launch", 3, 130.0, 150.0, 2.0, true), (
			listed.GetProperty("headline").GetString(),
			listed.GetProperty("conversationCount").GetInt32(),
			listed.GetProperty("recordedMinutes").GetDouble(),
			listed.GetProperty("quietMinutes").GetDouble(),
			listed.GetProperty("lostMinutes").GetDouble(),
			listed.GetProperty("hasRecap").GetBoolean()));
		Assert.Equal($"{Origin}/d/{day}", listed.GetProperty("url").GetString());
		Assert.StartsWith("3 of the 7 days from ", days.GetProperty("summary").GetString());
		Assert.False(days.GetProperty("truncated").GetBoolean());

		// get_day: recap, coverage, conversations in time order with quiet and lost apart, follow-ups said that day.
		var got = await ArchiveFixture.CallAsync(mcp, "get_day", new() { ["date"] = day });
		Assert.True(got.GetProperty("found").GetBoolean());
		Assert.Equal(fx.Day.DayOfWeek.ToString(), got.GetProperty("weekday").GetString());
		Assert.Equal("Tiles, teeth, and the launch", got.GetProperty("recap").GetProperty("headline").GetString());
		Assert.Equal(["recorded", "paused", "recorded"], got.GetProperty("coverage").GetProperty("spans").EnumerateArray().Select(s => s.GetProperty("kind").GetString()));
		var cards = got.GetProperty("conversations").EnumerateArray().ToList();
		Assert.Equal(["conv-kitchen", "conv-dentist", "conv-launch", "conv-music"], cards.Select(c => c.GetProperty("id").GetString()));
		var kitchen = cards[0];
		Assert.Equal($"{ArchiveFixture.Key(fx.Day)}T10:05:00+07:00", kitchen.GetProperty("startedAt").GetString());
		Assert.Equal(36.0, kitchen.GetProperty("minutes").GetDouble());
		Assert.Equal((1.0, 2.0), (kitchen.GetProperty("lostMinutes").GetDouble(), kitchen.GetProperty("quietMinutes").GetDouble()));
		Assert.Equal(["Alex", "Sam"], kitchen.GetProperty("people").EnumerateArray().Select(p => p.GetProperty("name").GetString()));
		Assert.True(kitchen.GetProperty("hasTranscript").GetBoolean());
		Assert.Equal(("noConversation", "music"), (cards[3].GetProperty("kind").GetString(), cards[3].GetProperty("descriptor").GetString()));
		Assert.False(cards[1].GetProperty("people")[1].TryGetProperty("name", out _), "An unmatched speaker has no name.");
		Assert.Equal(["fu-tiles", "fu-dentist", "fu-launch"], got.GetProperty("followUps").EnumerateArray().Select(f => f.GetProperty("id").GetString()));
		Assert.StartsWith($"On {fx.Day.DayOfWeek}, ", got.GetProperty("summary").GetString());
		Assert.Contains("you had 3 conversations over 2 hours 10 minutes of recording: Tiles, teeth, and the launch.", got.GetProperty("summary").GetString());

		// An ambiguous weekday and an empty day answer with candidates, not a guess.
		var weekday = await ArchiveFixture.CallAsync(mcp, "get_day", new() { ["date"] = fx.Day.DayOfWeek.ToString().ToLowerInvariant() });
		Assert.False(weekday.GetProperty("found").GetBoolean());
		Assert.StartsWith($"Which {fx.Day.DayOfWeek} do you mean", weekday.GetProperty("summary").GetString());
		Assert.Contains(day, weekday.GetProperty("candidates").EnumerateArray().Select(c => c.GetProperty("day").GetString()));
		var empty = await ArchiveFixture.CallAsync(mcp, "get_day", new() { ["date"] = ArchiveFixture.Key(fx.Day.AddDays(3)) });
		Assert.False(empty.GetProperty("found").GetBoolean());
		Assert.Equal(ArchiveFixture.Key(fx.Day.AddDays(1)), empty.GetProperty("candidates")[0].GetProperty("day").GetString());
		Assert.True((await mcp.CallToolAsync("get_day", new Dictionary<string, object?> { ["date"] = "the 14th" })).IsError);

		// get_brief: by a day inside the week, the latest, a month, and candidates for one that is not there.
		var week = await ArchiveFixture.CallAsync(mcp, "get_brief", new() { ["kind"] = "week", ["key"] = day });
		Assert.Equal(($"week:{ArchiveFixture.Key(fx.WeekStart)}", $"{Origin}/b/week/{ArchiveFixture.Key(fx.WeekStart)}"), (week.GetProperty("key").GetString(), week.GetProperty("url").GetString()));
		Assert.Equal("A renovation taking shape", week.GetProperty("headline").GetString());
		Assert.Equal(week.GetProperty("key").GetString(), (await ArchiveFixture.CallAsync(mcp, "get_brief")).GetProperty("key").GetString());
		var month = await ArchiveFixture.CallAsync(mcp, "get_brief", new() { ["kind"] = "month", ["key"] = fx.Day.ToString("yyyy-MM") });
		Assert.Equal($"{Origin}/b/month/{fx.Day:yyyy-MM}", month.GetProperty("url").GetString());
		var missing = await ArchiveFixture.CallAsync(mcp, "get_brief", new() { ["kind"] = "week", ["key"] = ArchiveFixture.Key(fx.Day.AddDays(-30)) });
		Assert.False(missing.GetProperty("found").GetBoolean());
		Assert.Equal(week.GetProperty("key").GetString(), missing.GetProperty("candidates")[0].GetProperty("key").GetString());

		// list_conversations: newest first; a tag; two people called Sam are a question; a person id answers it.
		var all = await ArchiveFixture.CallAsync(mcp, "list_conversations");
		Assert.Equal(["conv-launch-2", "conv-music", "conv-launch", "conv-dentist", "conv-kitchen", "conv-badminton"], Ids(all, "conversations"));
		Assert.Equal(["conv-launch-2", "conv-launch"], Ids(await ArchiveFixture.CallAsync(mcp, "list_conversations", new() { ["tag"] = "Product Launch" }), "conversations"));
		var sams = await ArchiveFixture.CallAsync(mcp, "list_conversations", new() { ["person"] = "sam" });
		Assert.Empty(sams.GetProperty("conversations").EnumerateArray());
		Assert.Equal(["person-sam", "person-sam-k"], sams.GetProperty("candidates").EnumerateArray().Select(c => c.GetProperty("personId").GetString()).Order());
		Assert.StartsWith("2 people are called Sam. Which one", sams.GetProperty("summary").GetString());
		var sam = await ArchiveFixture.CallAsync(mcp, "list_conversations", new() { ["person"] = "person-sam-k" });
		Assert.Equal(["conv-badminton"], Ids(sam, "conversations"));
		Assert.Equal("person-sam-k", sam.GetProperty("filters").GetProperty("personId").GetString());
		Assert.Equal(["conv-launch"], Ids(await ArchiveFixture.CallAsync(mcp, "list_conversations", new() { ["person"] = "Leo" }), "conversations"));
		Assert.Equal(["conv-kitchen"], Ids(await ArchiveFixture.CallAsync(mcp, "list_conversations", new() { ["query"] = "grout", ["from"] = day, ["to"] = day }), "conversations"));

		// get_conversation: the overview and gaps; the transcript with markers, confidence, and t; a window.
		var summary = await ArchiveFixture.CallAsync(mcp, "get_conversation", new() { ["id"] = "conv-kitchen" });
		Assert.True(summary.GetProperty("found").GetBoolean());
		Assert.StartsWith("Sam and you compare three tile samples", summary.GetProperty("overview").GetString());
		Assert.False(summary.TryGetProperty("transcript", out _));
		// Read the app's way (GapRows): the 20-second quiet stretch is not a row, so it is neither listed nor counted.
		Assert.Equal([("lost", 240, "watch"), ("quiet", 540, null)], summary.GetProperty("gaps").EnumerateArray().Select(g => (
			g.GetProperty("kind").GetString(), g.GetProperty("t").GetInt32(), g.TryGetProperty("origin", out var o) ? o.GetString() : null)));
		Assert.Equal("fu-tiles", summary.GetProperty("followUps")[0].GetProperty("id").GetString());
		Assert.Equal($"{Origin}/c/conv-kitchen?t=1260", summary.GetProperty("followUps")[0].GetProperty("url").GetString());
		Assert.StartsWith($"Kitchen tiles with Sam, {fx.Day.DayOfWeek} 10:05 AM", summary.GetProperty("summary").GetString());
		Assert.Contains("10:05 AM to 10:41 AM, 36 minutes, 1 minute of lost audio.", summary.GetProperty("summary").GetString());

		var full = await ArchiveFixture.CallAsync(mcp, "get_conversation", new() { ["id"] = "conv-kitchen", ["include"] = "transcript" });
		Assert.Equal(summary.GetProperty("overview").GetString(), full.GetProperty("overview").GetString());
		var items = full.GetProperty("transcript").GetProperty("items").EnumerateArray().ToList();
		Assert.Equal(["turn", "turn", "lost", "turn", "quiet", "turn", "turn", "masked"], items.Select(i => i.GetProperty("kind").GetString()));
		Assert.Equal((12, "Sam", 0.93), (items[0].GetProperty("t").GetInt32(), items[0].GetProperty("name").GetString(), items[0].GetProperty("confidence").GetDouble()));
		Assert.Equal(("watch", 1.0), (items[2].GetProperty("origin").GetString(), items[2].GetProperty("minutes").GetDouble()));
		Assert.Equal(0.42, items[6].GetProperty("confidence").GetDouble());
		Assert.Equal("music", items[7].GetProperty("descriptor").GetString());
		Assert.False(full.GetProperty("truncated").GetBoolean());
		var windowed = await ArchiveFixture.CallAsync(mcp, "get_conversation", new() { ["id"] = "conv-kitchen", ["include"] = "transcript", ["from_time"] = "300", ["to_time"] = $"{ArchiveFixture.Key(fx.Day)}T10:27:00" });
		Assert.Equal(["turn", "quiet", "turn"], windowed.GetProperty("transcript").GetProperty("items").EnumerateArray().Select(i => i.GetProperty("kind").GetString()));
		var both = await ArchiveFixture.CallAsync(mcp, "get_conversation", new() { ["id"] = "conv-launch", ["include"] = "both" });
		Assert.Equal("Launch checklist", both.GetProperty("notes")[0].GetProperty("title").GetString());
		Assert.Equal($"{Origin}/c/conv-launch?t=720", both.GetProperty("notes")[0].GetProperty("citations")[0].GetProperty("url").GetString());
		// Three turns and the watch's power-save pause, which the phone's transcript shows as a row of its own.
		var launchItems = both.GetProperty("transcript").GetProperty("items").EnumerateArray().ToList();
		Assert.Equal(["turn", "turn", "turn", "quiet"], launchItems.Select(i => i.GetProperty("kind").GetString()));
		Assert.Equal("paused for 2 min (watch was saving power)", launchItems[3].GetProperty("label").GetString());
		var unknown = await ArchiveFixture.CallAsync(mcp, "get_conversation", new() { ["id"] = "kitchen tiles" });
		Assert.False(unknown.GetProperty("found").GetBoolean());
		Assert.Equal("conv-kitchen", unknown.GetProperty("candidates")[0].GetProperty("id").GetString());
		Assert.True((await mcp.CallToolAsync("get_conversation", new Dictionary<string, object?> { ["id"] = "conv-kitchen", ["include"] = "everything" })).IsError);

		// list_follow_ups by status, open ones soonest due first.
		var open = await ArchiveFixture.CallAsync(mcp, "list_follow_ups");
		Assert.Equal(["fu-tiles"], Ids(open, "followUps"));
		var tiles = open.GetProperty("followUps")[0];
		Assert.Equal(("high", "open", "ai"), (tiles.GetProperty("priority").GetString(), tiles.GetProperty("status").GetString(), tiles.GetProperty("origin").GetString()));
		Assert.Equal("Kitchen tiles with Sam", tiles.GetProperty("source").GetProperty("title").GetString());
		Assert.Contains("the next is due", open.GetProperty("summary").GetString());
		Assert.Equal(["fu-dentist"], Ids(await ArchiveFixture.CallAsync(mcp, "list_follow_ups", new() { ["status"] = "done" }), "followUps"));
		Assert.Equal(["fu-launch"], Ids(await ArchiveFixture.CallAsync(mcp, "list_follow_ups", new() { ["status"] = "snoozed" }), "followUps"));
		Assert.Equal(3, (await ArchiveFixture.CallAsync(mcp, "list_follow_ups", new() { ["status"] = "all" })).GetProperty("followUps").GetArrayLength());

		// get_people keeps the two Sams apart; get_tags counts conversations.
		var people = (await ArchiveFixture.CallAsync(mcp, "get_people")).GetProperty("people").EnumerateArray().ToList();
		Assert.Equal(2, people.Count(p => p.GetProperty("name").GetString() == "Sam"));
		Assert.Equal(("Alex", 5), (people[0].GetProperty("name").GetString(), people[0].GetProperty("conversationCount").GetInt32()));
		var tags = (await ArchiveFixture.CallAsync(mcp, "get_tags")).GetProperty("tags").EnumerateArray().ToList();
		Assert.Equal(("product launch", 2), (tags[0].GetProperty("tag").GetString(), tags[0].GetProperty("conversationCount").GetInt32()));

		// Resources and prompts, for clients that use them.
		var templates = await mcp.ListResourceTemplatesAsync();
		Assert.Equal(["conversation://{id}", "day://{date}"], templates.Select(t => t.UriTemplate).Order());
		var resource = Assert.IsType<TextResourceContents>(Assert.Single((await mcp.ReadResourceAsync("conversation://conv-kitchen")).Contents));
		Assert.Contains("# Kitchen tiles with Sam", resource.Text);
		Assert.Contains("(audio interrupted for 1 min)", resource.Text);
		var dayResource = Assert.IsType<TextResourceContents>(Assert.Single((await mcp.ReadResourceAsync($"day://{day}")).Contents));
		Assert.Contains($"[Kitchen tiles with Sam]({Origin}/c/conv-kitchen)", dayResource.Text);
		var prompts = await mcp.ListPromptsAsync();
		Assert.Equal(["brief_me_on_a_day", "what_did_i_promise_this_week"], prompts.Select(p => p.Name).Order());
		var brief = await mcp.GetPromptAsync("brief_me_on_a_day", new Dictionary<string, object?> { ["date"] = day });
		Assert.Contains(day, Assert.IsType<TextContentBlock>(Assert.Single(brief.Messages).Content).Text);

		// Every call is in the AI-read log, by the client's name, with the ids it was given.
		await using var scope = factory.Services.CreateAsyncScope();
		var reads = await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().AiReads.AsNoTracking().Where(r => r.UserId == phone.UserId).ToListAsync();
		Assert.All(reads, r => Assert.Equal("Claude Code on the test Mac", r.Client));
		Assert.Contains(reads, r => r.Tool == "get_day" && r.EntityIds.Contains("conv-kitchen") && r.EntityIds.Contains(day));
		Assert.Contains(reads, r => r.Tool == "get_conversation" && r.EntityIds.SequenceEqual(["conv-kitchen"]));
		Assert.Contains(reads, r => r.Tool == "resource:conversation");
		Assert.Contains("resource:day", (await phone.GetJsonAsync("/sync/status")).GetProperty("aiReads").EnumerateArray().Select(r => r.GetProperty("tool").GetString()));
	}

	[Fact]
	public async Task Search_and_fetch_answer_in_ChatGPTs_document_shapes()
	{
		var (phone, fx) = await ArchiveFixture.SeedAsync(factory);
		using var linked = phone;
		await using var mcp = await ArchiveFixture.ConnectAsync(factory, phone.UserId, TokenAccess.Read, name: "ChatGPT");

		// ChatGPT's search shape: results of id, title, url, every url absolute and token-free; matches link to the moment.
		var tiles = await ArchiveFixture.CallAsync(mcp, "search", new() { ["query"] = "tiles" });
		var results = tiles.GetProperty("results").EnumerateArray().ToList();
		Assert.NotEmpty(results);
		Assert.All(results, r =>
		{
			Assert.False(string.IsNullOrEmpty(r.GetProperty("id").GetString()));
			Assert.False(string.IsNullOrEmpty(r.GetProperty("title").GetString()));
			Assert.StartsWith($"{Origin}/", r.GetProperty("url").GetString());
			Assert.DoesNotContain("token", r.GetProperty("url").GetString());
		});
		var conversation = results.First(r => r.GetProperty("kind").GetString() == "conversation");
		Assert.Equal("conv-kitchen", conversation.GetProperty("id").GetString());
		Assert.Equal($"{Origin}/c/conv-kitchen?t=12", conversation.GetProperty("url").GetString());
		Assert.Contains("**tiles**", conversation.GetProperty("snippet").GetString());
		Assert.Contains(results, r => r.GetProperty("id").GetString() == $"recap:{ArchiveFixture.Key(fx.Day)}");
		Assert.Contains(results, r => r.GetProperty("id").GetString() == "followUp:fu-tiles");
		Assert.Contains("the best is", tiles.GetProperty("summary").GetString());

		// Stemming finds "launch" in "launches"; kinds narrow it; days narrow it.
		var launches = await ArchiveFixture.CallAsync(mcp, "search", new() { ["query"] = "launches", ["kinds"] = new[] { "note", "brief" } });
		Assert.Equal(["brief", "note"], launches.GetProperty("results").EnumerateArray().Select(r => r.GetProperty("kind").GetString()).Distinct().Order());
		var after = await ArchiveFixture.CallAsync(mcp, "search", new() { ["query"] = "launch", ["kinds"] = new[] { "conversation" }, ["from"] = ArchiveFixture.Key(fx.Day.AddDays(1)) });
		Assert.Equal(["conv-launch-2"], Ids(after, "results"));
		var nothing = await ArchiveFixture.CallAsync(mcp, "search", new() { ["query"] = "volcano" });
		Assert.Empty(nothing.GetProperty("results").EnumerateArray());
		Assert.Equal("Nothing matched “volcano”.", nothing.GetProperty("summary").GetString());

		// fetch: ChatGPT's document shape, the transcript as text with its honest markers.
		var fetched = await ArchiveFixture.CallAsync(mcp, "fetch", new() { ["id"] = "conv-kitchen" });
		Assert.Equal(["summary", "id", "title", "text", "url", "metadata"], fetched.EnumerateObject().Select(p => p.Name));
		Assert.Equal(($"{Origin}/c/conv-kitchen", "Kitchen tiles with Sam"), (fetched.GetProperty("url").GetString(), fetched.GetProperty("title").GetString()));
		var text = fetched.GetProperty("text").GetString()!;
		Assert.Contains("[10:05:12] Sam: The matte tiles hide water spots", text);
		Assert.Contains("[10:09–10:10] (audio interrupted for 1 min)", text);
		Assert.Contains("[10:14–10:16] (quiet for 2 min)", text);
		Assert.Contains("mumble budget something (low confidence)", text);
		Assert.Contains("(music)", text);
		Assert.False(fetched.GetProperty("metadata").GetProperty("truncated").GetBoolean());
		Assert.Equal(1.0, fetched.GetProperty("metadata").GetProperty("lostMinutes").GetDouble());

		foreach (var id in new[] { $"recap:{ArchiveFixture.Key(fx.Day)}", $"brief:week:{ArchiveFixture.Key(fx.WeekStart)}", "followUp:fu-tiles", "note:note-launch" })
		{
			var item = await ArchiveFixture.CallAsync(mcp, "fetch", new() { ["id"] = id });
			Assert.Equal(id, item.GetProperty("id").GetString());
			Assert.False(string.IsNullOrWhiteSpace(item.GetProperty("text").GetString()));
			Assert.StartsWith($"{Origin}/", item.GetProperty("url").GetString());
		}

		Assert.Equal($"{Origin}/c/conv-kitchen?t=1260", (await ArchiveFixture.CallAsync(mcp, "fetch", new() { ["id"] = "followUp:fu-tiles" })).GetProperty("url").GetString());
		var unknown = await mcp.CallToolAsync("fetch", new Dictionary<string, object?> { ["id"] = "conv-nowhere" });
		Assert.True(unknown.IsError);
	}

	[Fact]
	public async Task Dense_day_coverage_keeps_totals_and_conversations_within_the_answer_budget()
	{
		var (phone, fx) = await ArchiveFixture.SeedAsync(factory);
		using var linked = phone;
		var coverage = fx.Coverage(fx.Day);
		var start = fx.At(9, 0);
		coverage["spans"] = new JsonArray(Enumerable.Range(0, 4000).Select(i => (JsonNode)new JsonObject
		{
			["startedAt"] = Wire.T(start.AddSeconds(i)),
			["endedAt"] = Wire.T(start.AddSeconds(i + 1)),
			["kind"] = i % 2 == 0 ? "recorded" : "missing",
		}).ToArray());
		Assert.Single(Phone.Ids(await phone.BatchAsync(ArchiveFixture.Item("coverage", ArchiveFixture.Key(fx.Day), coverage, ArchiveFixture.V + 1)), "accepted"));
		await using var mcp = await ArchiveFixture.ConnectAsync(factory, phone.UserId, TokenAccess.Read);
		var day = await ArchiveFixture.CallAsync(mcp, "get_day", new() { ["date"] = ArchiveFixture.Key(fx.Day) });
		Assert.True(Length(day) <= ArchiveSettings.Defaults.ToolMaxCharacters);
		Assert.Equal(4, day.GetProperty("conversations").GetArrayLength());
		Assert.False(day.GetProperty("truncated").GetBoolean());
		var detail = day.GetProperty("coverage");
		Assert.True(detail.GetProperty("spansOmitted").GetBoolean());
		Assert.Equal(0, detail.GetProperty("spans").GetArrayLength());
		Assert.Equal(130, detail.GetProperty("recordedMinutes").GetDouble());
		Assert.Equal(150, detail.GetProperty("quietMinutes").GetDouble());
		Assert.Equal(2, detail.GetProperty("lostMinutes").GetDouble());
	}

	[Fact]
	public async Task Results_stay_under_the_caps_and_say_how_to_continue()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		var fx = new ArchiveFixture();

		// A long talk: 400 turns of about 120 characters, and a dozen short ones on other days.
		var start = fx.At(9, 0);
		var turns = Enumerable.Range(0, 400)
			.Select(i => ArchiveFixture.Turn(start.AddSeconds(i * 15), i % 2 == 0 ? "1" : "2", i % 2 == 0 ? "Alex" : "Priya", $"Turn {i}: the launch checklist still needs the press kit, the demo video, the pricing page, and the FAQ.", 0.9))
			.ToArray();
		var batch = new List<System.Text.Json.Nodes.JsonObject>
		{
			ArchiveFixture.Item("conversation", "conv-long", ArchiveFixture.Conversation(fx.Day, start, start.AddMinutes(100), "Launch review with Priya", "A long review of everything left for the launch.", ["product launch"], [ArchiveFixture.Speaker("1", null, "Alex"), ArchiveFixture.Speaker("2", null, "Priya")], [], 100)),
			ArchiveFixture.Item("transcript", "conv-long", ArchiveFixture.Transcript("conv-long", turns)),
		};
		for (var i = 1; i <= 12; i++)
		{
			var day = fx.Day.AddDays(-i);
			batch.Add(ArchiveFixture.Item("conversation", $"conv-short-{i}", ArchiveFixture.Conversation(day, ArchiveFixture.At(day, 9, 0), ArchiveFixture.At(day, 9, 10), $"Launch standup {i}", "A short launch standup.", ["product launch"], [], [], 10)));
		}

		// A conversation the watch kept dropping out of: 600 interruptions of 12 seconds, 8 seconds apart, so each is a
		// row of its own the way the app reads them.
		var gappyDay = fx.Day.AddDays(-14);
		var gappyStart = ArchiveFixture.At(gappyDay, 9, 0);
		var lostGaps = Enumerable.Range(0, 600).Select(i => ArchiveFixture.Gap(gappyStart.AddSeconds(i * 20), gappyStart.AddSeconds(i * 20 + 12), "lost", "watch")).ToArray();
		batch.Add(ArchiveFixture.Item("conversation", "conv-gappy", ArchiveFixture.Conversation(gappyDay, gappyStart, gappyStart.AddMinutes(200), "Watch reconnects all morning", "The watch kept dropping out.", ["watch"], [], lostGaps, 80)));
		batch.Add(ArchiveFixture.Item("transcript", "conv-gappy", ArchiveFixture.Transcript("conv-gappy", [.. Enumerable.Range(0, 50).Select(i => ArchiveFixture.Turn(gappyStart.AddSeconds(i * 10 + 2), "1", "Alex", $"Turn {i}: it dropped again.", 0.9))])));

		Assert.Equal(0, (await phone.BatchAsync([.. batch])).GetProperty("rejected").GetArrayLength());
		await using var mcp = await ArchiveFixture.ConnectAsync(factory, userId, TokenAccess.Read);

		// Hundreds of gaps still answer inside the cap, lost ones listed first, and the summary says how many it lists;
		// with the transcript the gaps take at most half, so turns still come back.
		foreach (var include in new[] { "summary", "both" })
		{
			var gappy = await ArchiveFixture.CallAsync(mcp, "get_conversation", new() { ["id"] = "conv-gappy", ["include"] = include });
			Assert.True(Length(gappy) <= ArchiveSettings.Defaults.ToolMaxCharacters, $"{include}: {Length(gappy)} characters");
			Assert.InRange(gappy.GetProperty("gaps").GetArrayLength(), 1, 599);
			Assert.Contains("of 600 gaps to fit the answer", gappy.GetProperty("summary").GetString());
			if (include == "both")
			{
				Assert.True(gappy.GetProperty("transcript").GetProperty("shownCount").GetInt32() > 0);
			}
		}

		// With the defaults the long transcript comes back cut to the transcript read, and says how to read on.
		var first = await ArchiveFixture.CallAsync(mcp, "get_conversation", new() { ["id"] = "conv-long", ["include"] = "transcript" });
		Assert.True(first.GetProperty("truncated").GetBoolean());
		Assert.True(Length(first) <= ArchiveSettings.Defaults.ToolMaxCharacters);
		Assert.InRange(first.GetProperty("transcript").GetProperty("shownCount").GetInt32(), 100, 399);
		Assert.Equal(400, first.GetProperty("transcript").GetProperty("itemCount").GetInt32());
		Assert.Contains("Showing", first.GetProperty("summary").GetString());

		// Following next reads every turn exactly once, each window within max_chars.
		var seen = new List<int>();
		var calls = 0;
		var arguments = new Dictionary<string, object?> { ["id"] = "conv-long", ["include"] = "transcript", ["max_chars"] = 8_000 };
		while (true)
		{
			var page = await ArchiveFixture.CallAsync(mcp, "get_conversation", arguments);
			var items = page.GetProperty("transcript").GetProperty("items").EnumerateArray().ToList();
			Assert.True(items.Sum(i => Length(i) + 1) <= 8_000);
			seen.AddRange(items.Select(i => int.Parse(i.GetProperty("text").GetString()!.Split(':')[0][5..], System.Globalization.CultureInfo.InvariantCulture)));
			if (!page.GetProperty("truncated").GetBoolean())
			{
				break;
			}

			var call = page.GetProperty("next");
			Assert.Equal("get_conversation", call.GetProperty("tool").GetString());
			arguments = call.GetProperty("arguments").EnumerateObject().ToDictionary(p => p.Name, p => (object?)(p.Value.ValueKind == JsonValueKind.Number ? p.Value.GetInt32() : p.Value.GetString()));
			Assert.True(++calls < 40, "Reading on never ended.");
		}

		Assert.Equal(Enumerable.Range(0, 400), seen);
		Assert.True(calls >= 5);

		// Lower caps, as the admin can set them: lists page with a cursor, search says it was cut.
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			await scope.ServiceProvider.GetRequiredService<SettingsService>().SaveAsync(
				new Dictionary<string, int> { [nameof(ArchiveSettings.ToolMaxResults)] = 5, [nameof(ArchiveSettings.ToolMaxCharacters)] = 2_000 },
				CancellationToken.None);
		}

		try
		{
			var listed = new List<string>();
			var listArguments = new Dictionary<string, object?> { ["tag"] = "product launch" };
			for (var page = 0; page < 10; page++)
			{
				var result = await ArchiveFixture.CallAsync(mcp, "list_conversations", listArguments);
				Assert.True(Length(result) <= 2_000, $"A page is {Length(result)} characters.");
				listed.AddRange(Ids(result, "conversations"));
				if (!result.GetProperty("truncated").GetBoolean())
				{
					break;
				}

				listArguments = result.GetProperty("next").GetProperty("arguments").EnumerateObject().ToDictionary(p => p.Name, p => (object?)p.Value.GetString());
			}

			Assert.Equal(13, listed.Count);
			Assert.Equal(13, listed.Distinct().Count());
			Assert.Equal("conv-long", listed[0]);

			var searched = await ArchiveFixture.CallAsync(mcp, "search", new() { ["query"] = "launch" });
			Assert.True(searched.GetProperty("truncated").GetBoolean());
			Assert.True(Length(searched) <= 2_000);
			Assert.Contains("narrow", searched.GetProperty("summary").GetString());

			var days = await ArchiveFixture.CallAsync(mcp, "list_days", new() { ["from"] = ArchiveFixture.Key(fx.Day.AddDays(-20)), ["to"] = ArchiveFixture.Key(fx.Day) });
			Assert.Equal(5, days.GetProperty("days").GetArrayLength());
			Assert.True(days.GetProperty("truncated").GetBoolean());
			Assert.Equal(ArchiveFixture.Key(fx.Day.AddDays(-5)), days.GetProperty("next").GetProperty("arguments").GetProperty("to").GetString());

			var fetched = await ArchiveFixture.CallAsync(mcp, "fetch", new() { ["id"] = "conv-long" });
			Assert.True(fetched.GetProperty("metadata").GetProperty("truncated").GetBoolean());
			Assert.Equal("get_conversation", fetched.GetProperty("metadata").GetProperty("next").GetProperty("tool").GetString());
			Assert.True(Length(fetched) <= 2_000);
		}
		finally
		{
			await using var scope = factory.Services.CreateAsyncScope();
			await scope.ServiceProvider.GetRequiredService<SettingsService>().SaveAsync(
				SettingDefinition.All.ToDictionary(d => d.Key, d => d.Default),
				CancellationToken.None);
		}
	}

	[Fact]
	public async Task Get_audio_answers_ready_requested_not_allowed_and_unavailable()
	{
		var (phone, fx) = await ArchiveFixture.SeedAsync(factory, clips: false);
		using var linked = phone;
		await using var mcp = await ArchiveFixture.ConnectAsync(factory, phone.UserId, TokenAccess.Read);
		var span = new Dictionary<string, object?> { ["conversation_id"] = "conv-kitchen", ["start"] = "300", ["end"] = "600" };

		// Not allowed on the phone: nothing is asked.
		var refused = await ArchiveFixture.CallAsync(mcp, "get_audio", span);
		Assert.Equal("notAllowed", refused.GetProperty("status").GetString());
		Assert.StartsWith("You haven't allowed assistants to play your audio", refused.GetProperty("summary").GetString());
		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		Assert.False(await db.Requests.AnyAsync(r => r.UserId == phone.UserId));

		// Allowed: the phone is asked, and the answer says to ask again.
		await phone.AllowAsync(clips: true, edits: false);
		var requested = await ArchiveFixture.CallAsync(mcp, "get_audio", span);
		Assert.Equal("requested", requested.GetProperty("status").GetString());
		Assert.Equal($"{fx.Day:yyyy-MM-dd}T10:10:00+07:00", requested.GetProperty("startedAt").GetString());
		Assert.Equal($"{Origin}/c/conv-kitchen?t=300", requested.GetProperty("url").GetString());
		Assert.Contains("ask again", requested.GetProperty("summary").GetString());
		var requestId = Guid.Parse(requested.GetProperty("requestId").GetString()!);
		Assert.Equal("clip", (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests")[0].GetProperty("kind").GetString());

		// Ready (the conversion is ClipTests' business): a plain url for text clients and the same link in _meta.
		var clip = await db.Clips.SingleAsync(c => c.RequestId == requestId);
		var relative = Path.Combine(phone.UserId.ToString("N"), $"{clip.Id:N}.m4a");
		Directory.CreateDirectory(Path.Combine(factory.ClipsPath, phone.UserId.ToString("N")));
		await File.WriteAllBytesAsync(Path.Combine(factory.ClipsPath, relative), [0, 0, 0, 24, (byte)'f', (byte)'t', (byte)'y', (byte)'p']);
		await db.Clips.Where(c => c.Id == clip.Id).ExecuteUpdateAsync(s => s
			.SetProperty(c => c.Status, ClipStatus.Ready)
			.SetProperty(c => c.Path, relative)
			.SetProperty(c => c.DurationMs, 300_000L)
			.SetProperty(c => c.CoveredStartAt, clip.StartAt)
			.SetProperty(c => c.CoveredEndAt, clip.EndAt));
		var call = await mcp.CallToolAsync("get_audio", span);
		var ready = call.StructuredContent!.Value;
		Assert.Equal("ready", ready.GetProperty("status").GetString());
		var audioUrl = ready.GetProperty("audioUrl").GetString()!;
		Assert.StartsWith($"{Origin}/clips/{clip.Id:N}.m4a?exp=", audioUrl);
		Assert.Equal(5.0, ready.GetProperty("minutes").GetDouble());
		var meta = call.Meta![AudioTools.MetaKey]!;
		Assert.Equal(audioUrl, meta["url"]!.GetValue<string>());
		Assert.Equal("audio/mp4", meta["mimeType"]!.GetValue<string>());
		using (var browser = factory.CreateClient())
		{
			Assert.Equal(System.Net.HttpStatusCode.OK, (await browser.GetAsync(new Uri(audioUrl).PathAndQuery)).StatusCode);
		}

		// Unavailable: the phone no longer has it; and a conversation that is not there.
		var other = new Dictionary<string, object?> { ["conversation_id"] = "conv-launch" };
		var asked = await ArchiveFixture.CallAsync(mcp, "get_audio", other);
		var answer = await phone.SendAsync(HttpMethod.Post, $"/sync/requests/{asked.GetProperty("requestId").GetString()}/result", Phone.Json(new System.Text.Json.Nodes.JsonObject { ["status"] = "unavailable", ["detail"] = "Aged out." }));
		Assert.Equal(System.Net.HttpStatusCode.NoContent, answer.StatusCode);
		var gone = await ArchiveFixture.CallAsync(mcp, "get_audio", other);
		Assert.Equal(("unavailable", "gone"), (gone.GetProperty("status").GetString(), gone.GetProperty("reason").GetString()));
		var nowhere = await ArchiveFixture.CallAsync(mcp, "get_audio", new() { ["conversation_id"] = "conv-nowhere" });
		Assert.Equal(("unavailable", "notFound"), (nowhere.GetProperty("status").GetString(), nowhere.GetProperty("reason").GetString()));
		Assert.True((await mcp.CallToolAsync("get_audio", new Dictionary<string, object?> { ["conversation_id"] = "conv-kitchen", ["start"] = "99999" })).IsError);
	}

	[Fact]
	public async Task Write_tools_need_the_write_scope_and_the_phones_permission()
	{
		var (phone, fx) = await ArchiveFixture.SeedAsync(factory, edits: false);
		using var linked = phone;
		var create = new Dictionary<string, object?>
		{
			["text"] = "Call the tile shop about grout",
			["source_conversation_id"] = "conv-kitchen",
			["source_at"] = "400",
			["priority"] = "high",
			["due_at"] = $"{ArchiveFixture.Key(fx.Today.AddDays(2))}T17:00:00+07:00",
		};

		// A read-only connection: the tools are not listed, and calling one says to reconnect.
		await using (var reader = await ArchiveFixture.ConnectAsync(factory, phone.UserId, TokenAccess.Read))
		{
			var refused = await reader.CallToolAsync("create_follow_up", create);
			Assert.True(refused.IsError);
			Assert.Contains("Reconnect it", ArchiveFixture.Text(refused));
		}

		await using var mcp = await ArchiveFixture.ConnectAsync(factory, phone.UserId, TokenAccess.ReadWrite);
		var tools = await mcp.ListToolsAsync();
		foreach (var name in WriteToolNames)
		{
			var tool = Assert.Single(tools, t => t.Name == name).ProtocolTool;
			// Adding is additive; changing a follow-up replaces what it said, so hosts ask before it.
			Assert.Equal((false, name == "update_follow_up", false), (tool.Annotations?.ReadOnlyHint, tool.Annotations?.DestructiveHint, tool.Annotations?.OpenWorldHint));
			Assert.False(string.IsNullOrWhiteSpace(tool.Title));
			Assert.Equal("""[{"type":"oauth2","scopes":["archive:read","archive:write"]}]""", tool.Meta?["securitySchemes"]?.ToJsonString());
			Assert.All(
				new[] { "openai/toolInvocation/invoking", "openai/toolInvocation/invoked" },
				key => Assert.InRange(tool.Meta?[key]?.GetValue<string>().Length ?? 0, 1, 64));
		}

		Assert.True((await ArchiveFixture.CallAsync(mcp, "get_status")).GetProperty("canWrite").GetBoolean());

		// The phone has not allowed edits: each write says so and stores nothing.
		var notAllowed = await ArchiveFixture.CallAsync(mcp, "create_follow_up", create);
		Assert.Equal("notAllowed", notAllowed.GetProperty("status").GetString());
		Assert.Equal(WriteTools.NotAllowedSummary, notAllowed.GetProperty("summary").GetString());
		Assert.Equal("notAllowed", (await ArchiveFixture.CallAsync(mcp, "update_follow_up", new() { ["id"] = "fu-tiles", ["done"] = true })).GetProperty("status").GetString());
		Assert.Equal("notAllowed", (await ArchiveFixture.CallAsync(mcp, "create_note", new() { ["conversation_id"] = "conv-kitchen", ["body"] = "Grout: light grey." })).GetProperty("status").GetString());
		await using var scope = factory.Services.CreateAsyncScope();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		Assert.False(await db.Requests.AnyAsync(r => r.UserId == phone.UserId));
		Assert.Equal(3, await db.FollowUps.CountAsync(f => f.UserId == phone.UserId));

		// Allowed: written here at once, waiting for the phone, and the request is on its way.
		await phone.AllowAsync(clips: false, edits: true);
		var added = await ArchiveFixture.CallAsync(mcp, "create_follow_up", create);
		Assert.Equal("added", added.GetProperty("status").GetString());
		var followUp = added.GetProperty("followUp");
		Assert.Equal(("assistant", true, "high"), (followUp.GetProperty("origin").GetString(), followUp.GetProperty("waitingForPhone").GetBoolean(), followUp.GetProperty("priority").GetString()));
		Assert.Equal($"{Origin}/c/conv-kitchen?t=400", followUp.GetProperty("url").GetString());
		Assert.Equal("Added a follow-up: Call the tile shop about grout. It reaches your phone on its next sync.", added.GetProperty("summary").GetString());
		Assert.Contains(followUp.GetProperty("id").GetString(), Ids(await ArchiveFixture.CallAsync(mcp, "list_follow_ups"), "followUps"));

		var done = await ArchiveFixture.CallAsync(mcp, "update_follow_up", new() { ["id"] = "fu-tiles", ["done"] = true, ["due_at"] = "none" });
		Assert.Equal(("updated", "done"), (done.GetProperty("status").GetString(), done.GetProperty("followUp").GetProperty("status").GetString()));
		Assert.Equal("Marked done: Send Sam the tile samples. It reaches your phone on its next sync.", done.GetProperty("summary").GetString());
		Assert.Equal("unchanged", (await ArchiveFixture.CallAsync(mcp, "update_follow_up", new() { ["id"] = "fu-tiles" })).GetProperty("status").GetString());
		Assert.Equal("notFound", (await ArchiveFixture.CallAsync(mcp, "update_follow_up", new() { ["id"] = "fu-nowhere", ["done"] = true })).GetProperty("status").GetString());

		var note = await ArchiveFixture.CallAsync(mcp, "create_note", new()
		{
			["conversation_id"] = "conv-launch",
			["title"] = "Owners",
			["body"] = "Leo: demo video. Priya: launch date.",
			["citations"] = new[] { new Dictionary<string, object?> { ["at"] = "720" } },
		});
		Assert.Equal("added", note.GetProperty("status").GetString());
		Assert.Equal($"{Origin}/c/conv-launch?t=720", note.GetProperty("note").GetProperty("citations")[0].GetProperty("url").GetString());
		Assert.Equal("notFound", (await ArchiveFixture.CallAsync(mcp, "create_note", new() { ["conversation_id"] = "conv-nowhere", ["body"] = "x" })).GetProperty("status").GetString());
		Assert.True((await mcp.CallToolAsync("create_follow_up", new Dictionary<string, object?> { ["text"] = "x", ["priority"] = "urgent" })).IsError);

		var pulled = (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests").EnumerateArray().Select(r => r.GetProperty("kind").GetString()).ToList();
		Assert.Equal(["followUp.create", "followUp.update", "note.create"], pulled);
		Assert.Contains(await db.AiReads.AsNoTracking().Where(r => r.UserId == phone.UserId).Select(r => r.Tool).ToListAsync(), t => t == "create_note");
	}

	[Fact]
	public async Task Every_tool_schema_stands_alone_without_defs_or_refs()
	{
		// Gemini cannot read a schema with $defs (or the $ref that points into it), so every input and output schema is
		// written out in full, the write tools' too.
		var userId = await factory.CreateUserAsync();
		await using var mcp = await ArchiveFixture.ConnectAsync(factory, userId, TokenAccess.ReadWrite);
		var tools = await mcp.ListToolsAsync();
		Assert.Contains(tools, t => t.Name == "create_note");
		var problems = new List<string>();
		foreach (var tool in tools)
		{
			foreach (var (kind, schema) in new[] { ("input", (JsonElement?)tool.ProtocolTool.InputSchema), ("output", tool.ProtocolTool.OutputSchema) })
			{
				var text = schema?.GetRawText() ?? "";
				foreach (var word in new[] { "\"$defs\"", "\"definitions\"", "\"$ref\"" })
				{
					if (text.Contains(word, StringComparison.Ordinal))
					{
						problems.Add($"{tool.Name}'s {kind} schema has {word}");
					}
				}
			}
		}

		Assert.True(problems.Count == 0, string.Join("; ", problems));
	}

	/// <summary>A result's length as the model reads it: the JSON text of <c>content</c>, written like the server writes it.</summary>
	private static int Length(JsonElement element) => ToolJson.Serialize(element).Length;

	private static string[] Ids(JsonElement result, string list) =>
		[.. result.GetProperty(list).EnumerateArray().Select(e => e.GetProperty("id").GetString()!)];
}
