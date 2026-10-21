using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Mcp;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// The conversation viewer, the app-site association, and the MCP Apps widgets: the viewer is the signed-in
/// person's own archive, opened at a moment and never past the sharing scope; the widgets are what the render
/// tools point at.
/// </summary>
[Collection(ServerCollection.Name)]
public sealed partial class ViewerTests(ArchiveServerFactory factory)
{
	[Fact]
	public async Task The_viewer_sends_a_signed_out_person_to_sign_in_and_back()
	{
		using var client = factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });

		foreach (var path in new[] { "/", "/c/conv-kitchen?t=1260", "/d/2026-10-14", "/b/week/2026-10-11" })
		{
			var response = await client.GetAsync(path);
			Assert.Equal(HttpStatusCode.Redirect, response.StatusCode);
			var location = response.Headers.Location!.ToString();
			Assert.Contains("/sign-in", location, StringComparison.Ordinal);
			Assert.Contains($"ReturnUrl={Uri.EscapeDataString(path)}", location, StringComparison.Ordinal);
		}

		// The page's clip calls answer 401 to a script rather than redirecting it.
		Assert.Equal(HttpStatusCode.Unauthorized, (await client.PostAsJsonAsync("/c/conv-kitchen/clip", new { start = 0, end = 60 })).StatusCode);
		Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync($"/c/conv-kitchen/clip/{Guid.NewGuid()}")).StatusCode);
	}

	[Fact]
	public async Task A_conversation_opens_at_its_moment_and_asks_the_phone_for_its_clip_inside_the_scope()
	{
		var (phone, fixture) = await ArchiveFixture.SeedAsync(factory, clips: true);
		using var _ = phone;
		// Thirty days: the fixture's week-old day is inside; one conversation planted far older is not, as if the
		// nightly deletion had not run yet.
		var scoped = await phone.SendAsync(HttpMethod.Put, "/sync/preferences", Phone.Json(new JsonObject
		{
			["clips"] = true,
			["edits"] = false,
			["scope"] = new JsonObject { ["kind"] = "lastDays", ["days"] = 30 },
		}));
		Assert.Equal(HttpStatusCode.OK, scoped.StatusCode);
		var old = DateTimeOffset.UtcNow.AddDays(-60);
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var planted = TestData.Conversation(phone.UserId, "conv-long-ago", "Choosing paint with Priya", "home");
			planted.StartedAt = old;
			planted.EndedAt = old.AddMinutes(20);
			planted.DayKey = LogicalDays.Of(old, LogicalDays.Zone(planted.TimeZone));
			db.Conversations.Add(planted);
			await db.SaveChangesAsync();
		}

		using var browser = await SignedInAsync(phone.UserId);

		// The kitchen conversation at 10:26 (t = 1260): the cited band sits on the turn said then.
		var page = await PageAsync(browser, "/c/conv-kitchen?t=1260");
		Assert.Contains("Kitchen tiles with Sam", page, StringComparison.Ordinal);
		Assert.Contains("Alex and Sam", page, StringComparison.Ordinal);
		Assert.Contains("1 min missing · the watch didn't record it", page, StringComparison.Ordinal);
		Assert.Contains("Quiet · 2 min", page, StringComparison.Ordinal);
		Assert.Single(Regex.Matches(page, "The moment this cites"));
		var band = page.IndexOf("The moment this cites", StringComparison.Ordinal);
		var words = page.IndexOf("I'll send you the samples tonight.", StringComparison.Ordinal);
		Assert.InRange(words - band, 1, 600);
		var model = JsonDocument.Parse(Model().Match(page).Groups["json"].Value).RootElement;
		Assert.Equal(1260, model.GetProperty("t").GetInt32());
		Assert.Equal(36 * 60, model.GetProperty("dur").GetInt32());
		Assert.Equal("none", model.GetProperty("clip").GetProperty("status").GetString());
		Assert.Contains(model.GetProperty("gaps").EnumerateArray(), g => g.GetProperty("k").GetString() == "lost");

		// The clip around 10:26 is the twenty minutes from 10:21. Asking for it queues one request to the phone;
		// asking again is the same request; polling it says it waits.
		var window = new { start = model.GetProperty("clip").GetProperty("from").GetInt32(), end = model.GetProperty("clip").GetProperty("to").GetInt32() };
		Assert.Equal((16 * 60, 36 * 60), (window.start, window.end));
		var csrf = Csrf().Match(page).Groups["token"].Value;
		Assert.Equal(HttpStatusCode.BadRequest, (await browser.PostAsJsonAsync("/c/conv-kitchen/clip", window)).StatusCode);
		var asked = await ClipAsync(browser, "/c/conv-kitchen/clip", csrf, window);
		Assert.Equal("requested", asked.GetProperty("status").GetString());
		var requestId = asked.GetProperty("requestId").GetString();
		Assert.Equal(requestId, (await ClipAsync(browser, "/c/conv-kitchen/clip", csrf, window)).GetProperty("requestId").GetString());
		var polled = JsonDocument.Parse(await browser.GetStringAsync($"/c/conv-kitchen/clip/{requestId}")).RootElement;
		Assert.Equal("requested", polled.GetProperty("status").GetString());
		var pulled = (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests").EnumerateArray().ToList();
		var clip = Assert.Single(pulled, r => r.GetProperty("kind").GetString() == "clip");
		Assert.Equal(requestId, clip.GetProperty("id").GetString());
		Assert.Equal(Wire.T(fixture.At(10, 21)), clip.GetProperty("payload").GetProperty("startAt").GetString());
		Assert.Equal(Wire.T(fixture.At(10, 41)), clip.GetProperty("payload").GetProperty("endAt").GetString());

		// The page now says it is waiting for the phone.
		var waiting = JsonDocument.Parse(Model().Match(await PageAsync(browser, "/c/conv-kitchen?t=1260")).Groups["json"].Value).RootElement;
		Assert.Equal("requested", waiting.GetProperty("clip").GetProperty("status").GetString());

		// The day, the brief, and the recent days show what the scope holds, and never the planted conversation.
		var day = await PageAsync(browser, $"/d/{ArchiveFixture.Key(fixture.Day)}");
		Assert.Contains("Tiles, teeth, and the launch", day, StringComparison.Ordinal);
		Assert.Contains("Booking a dentist appointment", day, StringComparison.Ordinal);
		Assert.Contains("Send Sam the tile samples", day, StringComparison.Ordinal);
		var week = await PageAsync(browser, $"/b/week/{ArchiveFixture.Key(fixture.WeekStart)}");
		Assert.Contains("A renovation taking shape", week, StringComparison.Ordinal);
		var home = await PageAsync(browser, "/");
		Assert.Contains("Tiles, teeth, and the launch", home, StringComparison.Ordinal);
		Assert.DoesNotContain("Choosing paint", home, StringComparison.Ordinal);

		var outside = await browser.GetAsync("/c/conv-long-ago");
		Assert.Equal(HttpStatusCode.NotFound, outside.StatusCode);
		Assert.DoesNotContain("Choosing paint", await outside.Content.ReadAsStringAsync(), StringComparison.Ordinal);
		Assert.Contains("Your phone doesn't share this day", await PageAsync(browser, $"/d/{ArchiveFixture.Key(LogicalDays.Of(old, LogicalDays.Zone(ArchiveFixture.Zone)))}"), StringComparison.Ordinal);
		using (var request = new HttpRequestMessage(HttpMethod.Post, "/c/conv-long-ago/clip") { Content = JsonContent.Create(new { start = 0, end = 60 }) })
		{
			request.Headers.Add("RequestVerificationToken", csrf);
			Assert.Equal(HttpStatusCode.NotFound, (await browser.SendAsync(request)).StatusCode);
		}

		// Someone else's archive is not here at all.
		var stranger = await factory.CreateUserAsync();
		using var other = await SignedInAsync(stranger);
		Assert.Equal(HttpStatusCode.NotFound, (await other.GetAsync("/c/conv-kitchen")).StatusCode);
		Assert.DoesNotContain("Tiles, teeth", await PageAsync(other, "/"), StringComparison.Ordinal);
	}

	[Fact]
	public async Task The_app_site_association_is_json_at_its_well_known_path()
	{
		using var client = factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });

		var response = await client.GetAsync("/.well-known/apple-app-site-association");

		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
		var details = Assert.Single(JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.GetProperty("applinks").GetProperty("details").EnumerateArray());
		Assert.Equal(
			["R73F7TNT65.dev.audiocompanion.app", "R73F7TNT65.dev.audiocompanion.app.dev"],
			details.GetProperty("appIDs").EnumerateArray().Select(e => e.GetString()));
		Assert.Equal(
			["/link*", "/c/*", "/d/*", "/b/*"],
			details.GetProperty("components").EnumerateArray().Select(e => e.GetProperty("/").GetString()));
	}

	[Fact]
	public async Task The_render_tools_point_at_widgets_that_are_listed_and_readable()
	{
		var userId = await factory.CreateUserAsync();
		await using var mcp = await ArchiveFixture.ConnectAsync(factory, userId, TokenAccess.Read);

		var resources = (await mcp.ListResourcesAsync()).ToDictionary(r => r.Uri);
		foreach (var widget in Widgets.All)
		{
			var listed = resources[widget.Uri].ProtocolResource;
			Assert.Equal("text/html;profile=mcp-app", listed.MimeType);
			AssertCsp(listed.Meta);

			var read = Assert.IsType<TextResourceContents>(Assert.Single((await mcp.ReadResourceAsync(widget.Uri)).Contents));
			Assert.Equal("text/html;profile=mcp-app", read.MimeType);
			AssertCsp(read.Meta);
			Assert.StartsWith("<!DOCTYPE html>", read.Text, StringComparison.Ordinal);
			// Composed: every include is in place, and nothing is loaded from anywhere.
			Assert.DoesNotContain("@include", read.Text, StringComparison.Ordinal);
			Assert.DoesNotContain("<script src", read.Text, StringComparison.Ordinal);
			Assert.DoesNotContain("<link", read.Text, StringComparison.Ordinal);
			Assert.DoesNotMatch(@"(?m)^\s*import\s", read.Text);
			Assert.Contains("ui/initialize", read.Text, StringComparison.Ordinal);
		}

		var player = Assert.IsType<TextResourceContents>(Assert.Single((await mcp.ReadResourceAsync(Widgets.ClipPlayer)).Contents));
		Assert.Contains("customElements.define('pa-player'", player.Text, StringComparison.Ordinal);

		var tools = (await mcp.ListToolsAsync()).ToDictionary(t => t.Name, t => t.ProtocolTool.Meta);
		foreach (var (tool, uri) in new[]
		{
			("get_conversation", Widgets.ConversationCard),
			("get_day", Widgets.DayTimeline),
			("list_days", Widgets.DayTimeline),
			("get_audio", Widgets.ClipPlayer),
		})
		{
			var meta = tools[tool]!;
			Assert.Equal(uri, meta["ui"]?["resourceUri"]?.GetValue<string>());
			Assert.Equal(uri, meta["openai/outputTemplate"]?.GetValue<string>());
		}

		Assert.Null(tools["search"]?["ui"]);
	}

	private static void AssertCsp(JsonObject? meta)
	{
		var ui = meta?["ui"]!;
		Assert.Null(ui["domain"]);
		Assert.Empty(ui["csp"]!["connectDomains"]!.AsArray());
		Assert.Equal([ArchiveServerFactory.PublicOrigin], ui["csp"]!["resourceDomains"]!.AsArray().Select(d => d!.GetValue<string>()));
	}

	private async Task<HttpClient> SignedInAsync(Guid userId)
	{
		var client = factory.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
		var signIn = await client.GetAsync($"{TestSignIn.Path}?userId={userId}");
		Assert.Equal(HttpStatusCode.OK, signIn.StatusCode);
		return client;
	}

	/// <summary>A page as the person reads it: 200, with its HTML entities decoded.</summary>
	private static async Task<string> PageAsync(HttpClient client, string path)
	{
		var response = await client.GetAsync(path);
		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		return WebUtility.HtmlDecode(await response.Content.ReadAsStringAsync());
	}

	private static async Task<JsonElement> ClipAsync(HttpClient client, string path, string csrf, object body)
	{
		using var request = new HttpRequestMessage(HttpMethod.Post, path) { Content = JsonContent.Create(body) };
		request.Headers.Add("RequestVerificationToken", csrf);
		var response = await client.SendAsync(request);
		Assert.Equal(HttpStatusCode.OK, response.StatusCode);
		return JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.Clone();
	}

	[GeneratedRegex("""<script type="application/json" id="cv-model">(?<json>.*?)</script>""", RegexOptions.Singleline)]
	private static partial Regex Model();

	[GeneratedRegex("""<meta name="csrf-token" content="(?<token>[^"]+)">""")]
	private static partial Regex Csrf();
}
