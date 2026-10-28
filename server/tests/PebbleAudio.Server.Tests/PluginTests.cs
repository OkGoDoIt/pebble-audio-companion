using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Plugin;
using PebbleAudio.Server.Settings;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// The Pebble plugin's server half: the phone's <c>deviceStatus</c> reports in its batches, <c>GET /plugin/status</c>
/// and <c>GET /plugin/today</c> behind a read-only personal token, and the one-time code that makes that token.
/// </summary>
[Collection(ServerCollection.Name)]
public sealed partial class PluginTests(ArchiveServerFactory factory)
{
	private const long V = 1_791_999_175_292;

	[Fact]
	public async Task A_phone_reports_its_watch_and_the_plugin_reads_the_latest_from_a_linked_phone()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		var token = await TokenAsync(userId);
		using var http = factory.CreateClient();

		// Nothing has arrived yet: a 404 the plugin reads as "no status", with a reason for its log.
		var none = await http.SendAsync(Get("/plugin/status", token));
		Assert.Equal(HttpStatusCode.NotFound, none.StatusCode);
		Assert.True(none.Headers.CacheControl?.NoStore);
		Assert.False(string.IsNullOrEmpty(JsonDocument.Parse(await none.Content.ReadAsStringAsync()).RootElement.GetProperty("error").GetString()));

		// The report rides in an ordinary batch, filed under the phone the token names; a bad one is rejected alone.
		var updatedAt = DateTimeOffset.UtcNow.AddSeconds(-20);
		var lastAudio = updatedAt.AddSeconds(-5);
		var noLink = Status(updatedAt, lastAudio);
		noLink.Remove("link");
		var answer = await phone.BatchAsync(
			Wire.Item(DeviceStatusSync.Kind, phone.DeviceId.ToString(), V, payload: Status(updatedAt, lastAudio)),
			Wire.Item(DeviceStatusSync.Kind, phone.DeviceId.ToString(), V + 1, op: "delete"),
			Wire.Item(DeviceStatusSync.Kind, "watch", V + 2, payload: noLink));
		Assert.Equal([$"deviceStatus:{phone.DeviceId}"], Phone.Ids(answer, "accepted"));
		Assert.Equal(
			new[] { "op: device status is only upserted", "payload: link missing" },
			answer.GetProperty("rejected").EnumerateArray().Select(r => r.GetProperty("reason").GetString()!).ToArray());

		var status = await JsonAsync(http, "/plugin/status", token);
		Assert.Equal(updatedAt.ToUnixTimeMilliseconds(), status.GetProperty("updatedAtMs").GetInt64());
		Assert.Equal("active", status.GetProperty("capture").GetString());
		Assert.Equal("streaming", status.GetProperty("link").GetString());
		Assert.True(status.GetProperty("recording").GetBoolean());
		Assert.Equal(lastAudio.ToUnixTimeMilliseconds(), status.GetProperty("lastAudioAtMs").GetInt64());
		Assert.Equal(62, status.GetProperty("watchBatteryPercent").GetInt32());
		Assert.Equal("v4.41.0-667", status.GetProperty("watchFirmware").GetString());
		Assert.Equal(312, status.GetProperty("todayRecordedMinutes").GetInt32());
		Assert.Equal(95, status.GetProperty("todayQuietMinutes").GetInt32());
		Assert.Equal(4, status.GetProperty("todayLostMinutes").GetInt32());
		Assert.Equal(734_003_200, status.GetProperty("storageUsedBytes").GetInt64());
		// A fraction is rounded.
		Assert.Equal(81, status.GetProperty("phoneBatteryPercent").GetInt32());
		Assert.InRange(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - status.GetProperty("receivedAtMs").GetInt64(), 0, 60_000);
		Assert.False(status.GetProperty("stale").GetBoolean());
		Assert.Equal("Alex's iPhone", status.GetProperty("deviceName").GetString());

		// A replay and an older report change nothing; a newer one replaces it, and an impossible reading reads unknown.
		var replay = await phone.BatchAsync(Wire.Item(DeviceStatusSync.Kind, phone.DeviceId.ToString(), V, payload: Status(updatedAt, lastAudio)));
		Assert.Equal("duplicate", replay.GetProperty("ignored")[0].GetProperty("reason").GetString());
		var older = await phone.BatchAsync(Wire.Item(DeviceStatusSync.Kind, phone.DeviceId.ToString(), V - 1, payload: Status(updatedAt, lastAudio)));
		Assert.Equal("stale", older.GetProperty("ignored")[0].GetProperty("reason").GetString());
		var paused = Status(updatedAt.AddMinutes(1), null, capture: "paused", link: "connected", recording: false);
		paused["watchBatteryPercent"] = 140;
		paused["watchFirmware"] = null;
		Assert.Single(Phone.Ids(await phone.BatchAsync(Wire.Item(DeviceStatusSync.Kind, phone.DeviceId.ToString(), V + 10, payload: paused)), "accepted"));
		status = await JsonAsync(http, "/plugin/status", token);
		Assert.Equal(("paused", "connected", false), (status.GetProperty("capture").GetString(), status.GetProperty("link").GetString(), status.GetProperty("recording").GetBoolean()));
		Assert.Equal(JsonValueKind.Null, status.GetProperty("watchBatteryPercent").ValueKind);
		Assert.Equal(JsonValueKind.Null, status.GetProperty("watchFirmware").ValueKind);
		Assert.Equal(JsonValueKind.Null, status.GetProperty("lastAudioAtMs").ValueKind);

		// Stale once the report is older than the setting (35 minutes unless changed at /settings).
		await SetReceivedAtAsync(phone.DeviceId, DateTimeOffset.UtcNow.AddMinutes(-36));
		Assert.True((await JsonAsync(http, "/plugin/status", token)).GetProperty("stale").GetBoolean());
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var settings = scope.ServiceProvider.GetRequiredService<SettingsService>();
			await settings.SaveAsync(new Dictionary<string, int> { [nameof(ArchiveSettings.PluginStaleMinutes)] = 60 }, CancellationToken.None);
			try
			{
				Assert.False((await JsonAsync(http, "/plugin/status", token)).GetProperty("stale").GetBoolean());
			}
			finally
			{
				await settings.SaveAsync(new Dictionary<string, int> { [nameof(ArchiveSettings.PluginStaleMinutes)] = ArchiveSettings.Defaults.PluginStaleMinutes }, CancellationToken.None);
			}
		}

		// With two phones linked, the newest report wins; an unlinked phone's report goes with it.
		using var second = await Phone.LinkAsync(factory, userId, name: "Alex's other iPhone");
		await second.BatchAsync(Wire.Item(DeviceStatusSync.Kind, second.DeviceId.ToString(), V, payload: Status(updatedAt.AddMinutes(5), null, link: "disconnected", recording: false)));
		Assert.Equal("Alex's other iPhone", (await JsonAsync(http, "/plugin/status", token)).GetProperty("deviceName").GetString());
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			Assert.True(await scope.ServiceProvider.GetRequiredService<ArchiveWipe>().UnlinkFromAdminAsync(userId, second.DeviceId, CancellationToken.None));
			Assert.False(await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().DeviceStatuses.AnyAsync(s => s.DeviceId == second.DeviceId));
		}

		Assert.Equal("Alex's iPhone", (await JsonAsync(http, "/plugin/status", token)).GetProperty("deviceName").GetString());

		// Another account's plugin never sees it.
		var stranger = await TokenAsync(await factory.CreateUserAsync());
		Assert.Equal(HttpStatusCode.NotFound, (await http.SendAsync(Get("/plugin/status", stranger))).StatusCode);

		// The app's Delete all takes it too.
		Assert.Equal(HttpStatusCode.OK, (await phone.SendAsync(HttpMethod.Post, "/sync/wipe", Phone.Json(new JsonObject { ["confirm"] = "wipe" }))).StatusCode);
		Assert.Equal(HttpStatusCode.NotFound, (await http.SendAsync(Get("/plugin/status", token))).StatusCode);
	}

	[Fact]
	public async Task Only_a_live_personal_token_opens_the_plugin_endpoints()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		var token = await TokenAsync(userId);
		using var http = factory.CreateClient();

		foreach (var path in new[] { "/plugin/status", "/plugin/today" })
		{
			Assert.Equal(HttpStatusCode.Unauthorized, (await http.GetAsync(path)).StatusCode);
			Assert.Equal(HttpStatusCode.Unauthorized, (await http.SendAsync(Get(path, "pat_not-a-real-token"))).StatusCode);
			// The phone's device token opens /sync/* only.
			Assert.Equal(HttpStatusCode.Unauthorized, (await http.SendAsync(Get(path, phone.Token))).StatusCode);
		}

		Assert.Equal(HttpStatusCode.OK, (await http.SendAsync(Get("/plugin/today", token))).StatusCode);

		// Disconnected in Who can read: the next request is refused.
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var tokens = scope.ServiceProvider.GetRequiredService<ApiTokenService>();
			var made = Assert.Single(await tokens.ListAsync(userId, CancellationToken.None));
			Assert.True(await tokens.RevokeAsync(userId, made.Id, CancellationToken.None));
		}

		Assert.Equal(HttpStatusCode.Unauthorized, (await http.SendAsync(Get("/plugin/today", token))).StatusCode);

		// And the plugin's token never opens the phone's door.
		var other = await TokenAsync(userId);
		var batch = new HttpRequestMessage(HttpMethod.Put, "/sync/batch") { Content = Phone.BatchBody(phone.DeviceId, []) };
		batch.Headers.Authorization = new AuthenticationHeaderValue("Bearer", other);
		batch.Headers.Add(SyncProtocol.VersionHeader, "1");
		Assert.Equal(HttpStatusCode.Unauthorized, (await http.SendAsync(batch)).StatusCode);
	}

	[Fact]
	public async Task Today_reads_the_archive_day_inside_the_sharing_scope()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		var token = await TokenAsync(userId);
		using var http = factory.CreateClient();

		// An empty archive still answers: today's date, nothing in it, and the day's link.
		var zone = LogicalDays.Zone(ArchiveFixture.Zone);
		var today = LogicalDays.Of(DateTimeOffset.UtcNow, zone);
		var empty = await JsonAsync(http, "/plugin/today", token);
		Assert.Equal(ArchiveFixture.Key(today), empty.GetProperty("date").GetString());
		Assert.Equal(0, empty.GetProperty("conversationCount").GetInt32());
		Assert.Equal(JsonValueKind.Null, empty.GetProperty("current").ValueKind);
		Assert.Equal(JsonValueKind.Null, empty.GetProperty("last").ValueKind);

		// Today (from 5 AM, Asia/Jakarta): a finished conversation, music, and one still being recorded; yesterday one more.
		var start = LogicalDays.Start(today, zone);
		var elapsed = DateTimeOffset.UtcNow - start;
		var standup = start + elapsed * 0.2;
		var music = start + elapsed * 0.4;
		var live = start + elapsed * 0.8;
		var yesterday = today.AddDays(-1);
		var liveConversation = ArchiveFixture.Conversation(today, live, live.AddSeconds(1), "x", null, [], [], [], recordedMinutes: 1);
		liveConversation["state"] = "live";
		liveConversation["provisional"] = true;
		liveConversation["title"] = null;
		liveConversation["endedAt"] = null;
		var answer = await phone.BatchAsync(
			ArchiveFixture.Item("conversation", "conv-yesterday", ArchiveFixture.Conversation(yesterday, ArchiveFixture.At(yesterday, 18, 0), ArchiveFixture.At(yesterday, 18, 30), "Badminton on Saturday", null, [], [], [], 30)),
			ArchiveFixture.Item("conversation", "conv-standup", ArchiveFixture.Conversation(today, standup, standup.AddMinutes(1), "Morning standup", null, [], [], [], 1)),
			ArchiveFixture.Item("conversation", "conv-music", ArchiveFixture.Conversation(today, music, music.AddMinutes(1), "Music in the café", null, [], [], [], 1, kind: "noConversation", descriptor: "music")),
			ArchiveFixture.Item("conversation", "conv-live", liveConversation),
			ArchiveFixture.Item("recap", ArchiveFixture.Key(today), ArchiveFixture.Recap(today, "", "Standup, then a quiet stretch. More later.\nSecond line.", "Long text.", ["conv-standup"])));
		Assert.Equal(0, answer.GetProperty("rejected").GetArrayLength());

		var day = await JsonAsync(http, "/plugin/today", token);
		Assert.Equal(ArchiveFixture.Key(today), day.GetProperty("date").GetString());
		// Music is not a conversation, as get_day counts them.
		Assert.Equal(2, day.GetProperty("conversationCount").GetInt32());
		// No headline: the recap's line, first sentence.
		Assert.Equal("Standup, then a quiet stretch.", day.GetProperty("recapHeadline").GetString());
		var current = day.GetProperty("current");
		Assert.Equal("conv-live", current.GetProperty("id").GetString());
		Assert.Equal(JsonValueKind.Null, current.GetProperty("title").ValueKind);
		Assert.Equal("live", current.GetProperty("state").GetString());
		Assert.Equal(live.ToUnixTimeMilliseconds(), current.GetProperty("startedAtMs").GetInt64());
		var last = day.GetProperty("last");
		Assert.Equal(("conv-standup", "Morning standup", "closed"), (last.GetProperty("id").GetString(), last.GetProperty("title").GetString(), last.GetProperty("state").GetString()));
		Assert.Equal(standup.ToUnixTimeMilliseconds(), last.GetProperty("startedAtMs").GetInt64());
		Assert.Equal(standup.AddMinutes(1).ToUnixTimeMilliseconds(), last.GetProperty("endedAtMs").GetInt64());
		Assert.Equal($"{ArchiveServerFactory.PublicOrigin}/d/{ArchiveFixture.Key(today)}", day.GetProperty("viewerUrl").GetString());

		// The phone narrows what it shares to start with the live conversation: nothing before it is read any more.
		var preferences = await phone.SendAsync(HttpMethod.Put, "/sync/preferences", Phone.Json(new JsonObject
		{
			["scope"] = new JsonObject { ["kind"] = "since", ["since"] = Wire.T(live) },
		}));
		Assert.Equal(HttpStatusCode.OK, preferences.StatusCode);
		var narrowed = await JsonAsync(http, "/plugin/today", token);
		Assert.Equal(1, narrowed.GetProperty("conversationCount").GetInt32());
		Assert.Equal("conv-live", narrowed.GetProperty("current").GetProperty("id").GetString());
		Assert.Equal(JsonValueKind.Null, narrowed.GetProperty("last").ValueKind);
	}

	[Fact]
	public async Task The_plugin_connects_with_a_one_time_code_from_its_connect_page()
	{
		var userId = await factory.CreateUserAsync();
		using var browser = factory.CreateClient(new Microsoft.AspNetCore.Mvc.Testing.WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
		Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync($"{TestSignIn.Path}?userId={userId}")).StatusCode);

		// The page asks for a code first, then shows one, which only that response carries.
		var page = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/pebble-plugin"));
		Assert.Contains("Apps › Plugins › Pebble Audio", page, StringComparison.Ordinal);
		Assert.Contains("Show a Code", page, StringComparison.Ordinal);
		Assert.DoesNotContain("code-boxes", page, StringComparison.Ordinal);
		var csrf = Csrf().Match(page).Groups["token"].Value;
		var shown = await browser.PostAsync("/connect/pebble-plugin?handler=Code", new FormUrlEncodedContent(new Dictionary<string, string> { ["__RequestVerificationToken"] = csrf }));
		Assert.Equal(HttpStatusCode.OK, shown.StatusCode);
		Assert.True(shown.Headers.CacheControl?.NoStore);
		var withCode = WebUtility.HtmlDecode(await shown.Content.ReadAsStringAsync());
		var pageCode = CodeOnPage().Match(withCode).Groups["code"].Value;
		Assert.Matches("^[A-Z2-9]{4}-[A-Z2-9]{4}$", pageCode);
		Assert.Contains("once you enter the code", withCode, StringComparison.Ordinal);
		Assert.Equal(HttpStatusCode.NotFound, (await browser.PostAsync("/connect/pebble-plugin?handler=Key", new FormUrlEncodedContent(new Dictionary<string, string> { ["__RequestVerificationToken"] = csrf }))).StatusCode);

		// A newer code ends the one on the page; a phone's code is not a plugin's, nor the other way round.
		string code, phoneCode;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			code = (await scope.ServiceProvider.GetRequiredService<PluginLinkService>().MintAsync(userId, CancellationToken.None)).Code;
			phoneCode = (await scope.ServiceProvider.GetRequiredService<PhoneLinkService>().MintAsync(userId, CancellationToken.None)).Code;
		}

		using var plugin = factory.CreateClient();
		Assert.Equal(HttpStatusCode.Conflict, (await plugin.PostAsync("/plugin/link", Phone.Json(new JsonObject { ["code"] = pageCode }))).StatusCode);
		Assert.Equal(HttpStatusCode.Conflict, (await plugin.PostAsync("/plugin/link", Phone.Json(new JsonObject { ["code"] = phoneCode }))).StatusCode);
		Assert.Equal(HttpStatusCode.Conflict, (await plugin.SendAsync(Phone.LinkRequest(code))).StatusCode);

		// Typed the way a person might, it is exchanged once for a read-only token named for the plugin.
		var linked = await plugin.PostAsync("/plugin/link", Phone.Json(new JsonObject { ["code"] = PhoneLinkService.Display(code).ToLowerInvariant() }));
		Assert.Equal(HttpStatusCode.Created, linked.StatusCode);
		Assert.True(linked.Headers.CacheControl?.NoStore);
		var token = JsonDocument.Parse(await linked.Content.ReadAsStringAsync()).RootElement.GetProperty("token").GetString()!;
		Assert.StartsWith(ApiTokenService.Prefix, token);
		Assert.Equal(HttpStatusCode.Conflict, (await plugin.PostAsync("/plugin/link", Phone.Json(new JsonObject { ["code"] = code }))).StatusCode);
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var made = Assert.Single(await scope.ServiceProvider.GetRequiredService<ApiTokenService>().ListAsync(userId, CancellationToken.None));
			Assert.Equal((PluginLinkService.TokenName, TokenAccess.Read), (made.Name, made.Access));
			var used = await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().PluginLinkCodes.AsNoTracking()
				.SingleAsync(c => c.UserId == userId && c.UsedAt != null);
			Assert.Equal(made.Id, used.ApiTokenId);
		}

		// Once it reads, the plugin is connected on its page.
		Assert.Equal(HttpStatusCode.NotFound, (await plugin.SendAsync(Get("/plugin/status", token))).StatusCode);
		var connected = WebUtility.HtmlDecode(await browser.GetStringAsync("/connect/pebble-plugin"));
		Assert.Contains("data-ready=\"true\"", connected, StringComparison.Ordinal);
		Assert.Contains("Pebble plugin is connected.", connected, StringComparison.Ordinal);
	}

	[Fact]
	public async Task The_phone_shows_the_plugin_s_code_and_sees_it_connect()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		using var http = factory.CreateClient();

		// The phone's door only: no token, a personal token, or a phone without the protocol header get nothing.
		foreach (var (method, path) in new[] { (HttpMethod.Post, "/sync/plugin-code"), (HttpMethod.Get, "/sync/plugin") })
		{
			Assert.Equal(HttpStatusCode.Unauthorized, (await http.SendAsync(new HttpRequestMessage(method, path))).StatusCode);
			var withKey = new HttpRequestMessage(method, path);
			withKey.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await TokenAsync(await factory.CreateUserAsync()));
			withKey.Headers.Add(SyncProtocol.VersionHeader, "1");
			Assert.Equal(HttpStatusCode.Unauthorized, (await http.SendAsync(withKey)).StatusCode);
			var noHeader = new HttpRequestMessage(method, path);
			noHeader.Headers.Authorization = new AuthenticationHeaderValue("Bearer", phone.Token);
			Assert.Equal(HttpStatusCode.UpgradeRequired, (await http.SendAsync(noHeader)).StatusCode);
		}

		// Not connected yet.
		var before = await phone.GetJsonAsync("/sync/plugin");
		Assert.False(before.GetProperty("connected").GetBoolean());
		Assert.Equal(JsonValueKind.Null, before.GetProperty("lastUsedAtMs").ValueKind);

		// A code as it is typed, for ten minutes, never cached; a newer one ends it.
		var first = await CodeAsync(phone);
		var minted = await phone.SendAsync(HttpMethod.Post, "/sync/plugin-code");
		Assert.Equal(HttpStatusCode.Created, minted.StatusCode);
		Assert.True(minted.Headers.CacheControl?.NoStore);
		var answer = JsonDocument.Parse(await minted.Content.ReadAsStringAsync()).RootElement;
		var code = answer.GetProperty("code").GetString()!;
		Assert.Matches("^[A-Z2-9]{4}-[A-Z2-9]{4}$", code);
		Assert.InRange(
			answer.GetProperty("expiresAtMs").GetInt64() - DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
			(long)SyncProtocol.LinkCodeLifetime.TotalMilliseconds - 60_000,
			(long)SyncProtocol.LinkCodeLifetime.TotalMilliseconds);
		Assert.NotEqual(first, code);

		using var plugin = factory.CreateClient();
		Assert.Equal(HttpStatusCode.Conflict, (await plugin.PostAsync("/plugin/link", Phone.Json(new JsonObject { ["code"] = first }))).StatusCode);
		// A plugin code never links a phone, and a phone's code never connects the plugin.
		Assert.Equal(HttpStatusCode.Conflict, (await plugin.SendAsync(Phone.LinkRequest(code))).StatusCode);
		string phoneCode;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			phoneCode = (await scope.ServiceProvider.GetRequiredService<PhoneLinkService>().MintAsync(userId, CancellationToken.None)).Code;
		}

		Assert.Equal(HttpStatusCode.Conflict, (await plugin.PostAsync("/plugin/link", Phone.Json(new JsonObject { ["code"] = phoneCode }))).StatusCode);

		// Typed the way a person might, it is exchanged once for a read-only token named for the plugin.
		var linked = await plugin.PostAsync("/plugin/link", Phone.Json(new JsonObject { ["code"] = code.ToLowerInvariant() }));
		Assert.Equal(HttpStatusCode.Created, linked.StatusCode);
		var token = JsonDocument.Parse(await linked.Content.ReadAsStringAsync()).RootElement.GetProperty("token").GetString()!;
		Assert.StartsWith(ApiTokenService.Prefix, token);
		Assert.Equal(HttpStatusCode.Conflict, (await plugin.PostAsync("/plugin/link", Phone.Json(new JsonObject { ["code"] = code }))).StatusCode);
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var made = Assert.Single(await scope.ServiceProvider.GetRequiredService<ApiTokenService>().ListAsync(userId, CancellationToken.None));
			Assert.Equal((PluginLinkService.TokenName, TokenAccess.Read), (made.Name, made.Access));
		}

		// Connected at once; its last read once it reads.
		var connected = await phone.GetJsonAsync("/sync/plugin");
		Assert.True(connected.GetProperty("connected").GetBoolean());
		Assert.Equal(JsonValueKind.Null, connected.GetProperty("lastUsedAtMs").ValueKind);
		Assert.Equal(HttpStatusCode.OK, (await plugin.SendAsync(Get("/plugin/today", token))).StatusCode);
		var read = await phone.GetJsonAsync("/sync/plugin");
		Assert.True(read.GetProperty("connected").GetBoolean());
		Assert.InRange(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - read.GetProperty("lastUsedAtMs").GetInt64(), 0, 60_000);

		// Another account's phone sees nothing of it.
		using (var stranger = await Phone.LinkAsync(factory, await factory.CreateUserAsync()))
		{
			Assert.False((await stranger.GetJsonAsync("/sync/plugin")).GetProperty("connected").GetBoolean());
		}

		// Disconnected in Who can read: the phone sees it go.
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var tokens = scope.ServiceProvider.GetRequiredService<ApiTokenService>();
			Assert.True(await tokens.RevokeAsync(userId, Assert.Single(await tokens.ListAsync(userId, CancellationToken.None)).Id, CancellationToken.None));
		}

		var gone = await phone.GetJsonAsync("/sync/plugin");
		Assert.False(gone.GetProperty("connected").GetBoolean());
		Assert.Equal(JsonValueKind.Null, gone.GetProperty("lastUsedAtMs").ValueKind);
	}

	/// <summary><c>POST /sync/plugin-code</c>'s code.</summary>
	private static async Task<string> CodeAsync(Phone phone)
	{
		var response = await phone.SendAsync(HttpMethod.Post, "/sync/plugin-code");
		Assert.Equal(HttpStatusCode.Created, response.StatusCode);
		return JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.GetProperty("code").GetString()!;
	}

	private static JsonObject Status(
		DateTimeOffset updatedAt,
		DateTimeOffset? lastAudio,
		string capture = "active",
		string link = "streaming",
		bool recording = true) => new()
		{
			["updatedAtMs"] = updatedAt.ToUnixTimeMilliseconds(),
			["capture"] = capture,
			["link"] = link,
			["recording"] = recording,
			["lastAudioAtMs"] = lastAudio?.ToUnixTimeMilliseconds(),
			["watchBatteryPercent"] = 62,
			["watchFirmware"] = "v4.41.0-667",
			["todayRecordedMinutes"] = 312,
			["todayQuietMinutes"] = 95,
			["todayLostMinutes"] = 4,
			["storageUsedBytes"] = 734_003_200,
			["phoneBatteryPercent"] = 80.6,
		};

	private async Task<string> TokenAsync(Guid userId)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		var (_, secret) = await scope.ServiceProvider.GetRequiredService<ApiTokenService>().CreateAsync(userId, PluginLinkService.TokenName, TokenAccess.Read, CancellationToken.None);
		return secret;
	}

	private async Task SetReceivedAtAsync(Guid deviceId, DateTimeOffset at)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().DeviceStatuses
			.Where(s => s.DeviceId == deviceId)
			.ExecuteUpdateAsync(s => s.SetProperty(r => r.ReceivedAt, at));
	}

	private static HttpRequestMessage Get(string path, string token)
	{
		var request = new HttpRequestMessage(HttpMethod.Get, path);
		request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
		return request;
	}

	private static async Task<JsonElement> JsonAsync(HttpClient http, string path, string token)
	{
		var response = await http.SendAsync(Get(path, token));
		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		return JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.Clone();
	}

	[GeneratedRegex("""<meta name="csrf-token" content="(?<token>[^"]+)">""")]
	private static partial Regex Csrf();

	[GeneratedRegex("""data-code="(?<code>[A-Z2-9-]+)""")]
	private static partial Regex CodeOnPage();
}
