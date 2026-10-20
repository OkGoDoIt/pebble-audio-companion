using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Events;
using PebbleAudio.Server.Jobs;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// What the person decides on the phone for the whole account: the sharing scope (sync-protocol.md §5), unlinking
/// (§1), and what their changes announce to subscribed assistants.
/// </summary>
[Collection(ServerCollection.Name)]
public sealed class AccountTests(ArchiveServerFactory factory)
{
	private const long V = ArchiveFixture.V;

	[Fact]
	public async Task The_sharing_scope_hides_old_items_from_tools_drops_them_from_batches_and_the_nightly_job_deletes_them()
	{
		var (phone, fx) = await ArchiveFixture.SeedAsync(factory, clips: true);
		using var linked = phone;
		var old = fx.Today.AddDays(-60);
		var oldWeek = old.AddDays(-(int)old.DayOfWeek);
		JsonObject[] oldItems =
		[
			ArchiveFixture.Item("conversation", "conv-old", ArchiveFixture.Conversation(old, ArchiveFixture.At(old, 9, 0), ArchiveFixture.At(old, 9, 30), "Measuring the old kitchen", "Sam measures the kitchen walls.", ["kitchen renovation"], [ArchiveFixture.Speaker("2", "person-sam", "Sam")], [], 30)),
			ArchiveFixture.Item("transcript", "conv-old", ArchiveFixture.Transcript("conv-old", [ArchiveFixture.Turn(ArchiveFixture.At(old, 9, 1), "2", "Sam", "The wall is three meters forty.", 0.9)])),
			// A transcript whose conversation never came: dated by its first item.
			ArchiveFixture.Item("transcript", "conv-old-alone", ArchiveFixture.Transcript("conv-old-alone", [ArchiveFixture.Turn(ArchiveFixture.At(old, 11, 0), "2", "Sam", "The grout should be grey.", 0.9)])),
			ArchiveFixture.Item("recap", ArchiveFixture.Key(old), ArchiveFixture.Recap(old, "Measurements", "Measuring the kitchen.", "A morning of measuring.", ["conv-old"])),
			ArchiveFixture.Item("brief", $"week:{ArchiveFixture.Key(oldWeek)}", ArchiveFixture.Brief("week", $"week:{ArchiveFixture.Key(oldWeek)}", oldWeek, oldWeek.AddDays(6), "Measuring week", "Measurements.", "A week of measuring.")),
			ArchiveFixture.Item("followUp", "fu-old", ArchiveFixture.FollowUp("Order the wall paint", "conv-old", ArchiveFixture.At(old, 9, 10), ArchiveFixture.At(old, 9, 40))),
			ArchiveFixture.Item("followUp", "fu-old-loose", ArchiveFixture.FollowUp("Call the plumber", null, null, ArchiveFixture.At(old, 12, 0))),
			// Said in the old conversation, written down only recently: dated by when it was said.
			ArchiveFixture.Item("followUp", "fu-old-said", ArchiveFixture.FollowUp("Return the tile samples", "conv-old", ArchiveFixture.At(old, 9, 20), ArchiveFixture.At(fx.Today.AddDays(-1), 12, 0))),
			ArchiveFixture.Item("note", "note-old", ArchiveFixture.Note("conv-old", "Sizes", "Three meters forty.", ArchiveFixture.At(old, 9, 1), ArchiveFixture.At(old, 10, 0))),
			ArchiveFixture.Item("coverage", ArchiveFixture.Key(old), fx.Coverage(old)),
		];
		Assert.Equal(oldItems.Length, (await phone.BatchAsync(oldItems)).GetProperty("accepted").GetArrayLength());

		// A clip of the old conversation, on disk.
		string clipFile;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var clip = await scope.ServiceProvider.GetRequiredService<PhoneRequestService>()
				.RequestClipAsync(phone.UserId, "conv-old", ArchiveFixture.At(old, 9, 0), ArchiveFixture.At(old, 9, 1), CancellationToken.None);
			Assert.Equal(HttpStatusCode.Created, (await phone.SendAsync(HttpMethod.Put, $"/sync/clips/{clip.RequestId}", SyncTests.Clip(OggSpeexFile.FromFixture()))).StatusCode);
			clipFile = Directory.GetFiles(Path.Combine(factory.ClipsPath, phone.UserId.ToString("N"))).Single();
			await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Jobs.Where(j => j.UserId == phone.UserId).ExecuteDeleteAsync();
		}

		await using var mcp = await ArchiveFixture.ConnectAsync(factory, phone.UserId, TokenAccess.Read);
		Assert.Equal(7, (await ArchiveFixture.CallAsync(mcp, "get_status")).GetProperty("counts").GetProperty("conversations").GetInt32());

		// The phone shrinks the scope to 30 days: the answer carries it, and what is older is gone at once.
		var put = await phone.SendAsync(HttpMethod.Put, "/sync/preferences", Phone.Json(new JsonObject { ["scope"] = new JsonObject { ["kind"] = "lastDays", ["days"] = 30 } }));
		Assert.Equal(HttpStatusCode.OK, put.StatusCode);
		var stored = JsonDocument.Parse(await put.Content.ReadAsStringAsync()).RootElement;
		Assert.Equal("""{"kind":"lastDays","days":30}""", stored.GetProperty("scope").GetRawText());
		Assert.True(stored.GetProperty("clips").GetBoolean(), "A scope change leaves the other choices alone.");
		Assert.Equal("""{"kind":"lastDays","days":30}""", (await phone.GetJsonAsync("/sync/preferences")).GetProperty("scope").GetRawText());
		Assert.Equal(HttpStatusCode.BadRequest, (await phone.SendAsync(HttpMethod.Put, "/sync/preferences", Phone.Json(new JsonObject { ["scope"] = new JsonObject { ["kind"] = "lastDays", ["days"] = 0 } }))).StatusCode);
		Assert.Equal(HttpStatusCode.BadRequest, (await phone.SendAsync(HttpMethod.Put, "/sync/preferences", Phone.Json(new JsonObject { ["scope"] = new JsonObject { ["kind"] = "forever" } }))).StatusCode);
		// A start in the future would delete everything and hold back every batch until then.
		var later = Wire.T(DateTimeOffset.UtcNow.AddDays(2));
		Assert.Equal(HttpStatusCode.BadRequest, (await phone.SendAsync(HttpMethod.Put, "/sync/preferences", Phone.Json(new JsonObject { ["scope"] = new JsonObject { ["kind"] = "since", ["since"] = later } }))).StatusCode);
		Assert.Equal(6, (await ArchiveFixture.CallAsync(mcp, "get_status")).GetProperty("counts").GetProperty("conversations").GetInt32());

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var u = phone.UserId;
			Assert.False(await db.Conversations.AnyAsync(c => c.UserId == u && c.Id == "conv-old"));
			Assert.False(await db.Transcripts.AnyAsync(t => t.UserId == u && (t.ConversationId == "conv-old" || t.ConversationId == "conv-old-alone")));
			Assert.False(await db.SyncItems.AnyAsync(s => s.UserId == u && s.EntityId == "conv-old-alone"));
			Assert.False(await db.Recaps.AnyAsync(r => r.UserId == u && r.DayKey == old));
			Assert.False(await db.Briefs.AnyAsync(b => b.UserId == u && b.PeriodKey == $"week:{ArchiveFixture.Key(oldWeek)}"));
			Assert.False(await db.FollowUps.AnyAsync(f => f.UserId == u && (f.Id == "fu-old" || f.Id == "fu-old-loose" || f.Id == "fu-old-said")));
			Assert.False(await db.Notes.AnyAsync(n => n.UserId == u && n.Id == "note-old"));
			Assert.False(await db.CoverageDays.AnyAsync(c => c.UserId == u && c.DayKey == old));
			Assert.False(await db.Clips.AnyAsync(c => c.UserId == u));
			Assert.False(await db.SyncItems.AnyAsync(s => s.UserId == u && s.EntityId == "conv-old"));
			// What is inside the window stays.
			Assert.Equal(6, await db.Conversations.CountAsync(c => c.UserId == u));
			Assert.True(await db.Recaps.AnyAsync(r => r.UserId == u && r.DayKey == fx.Day));
			var preferences = await db.SyncPreferences.AsNoTracking().SingleAsync(p => p.UserId == u);
			Assert.Equal(ArchiveFixture.Zone, preferences.TimeZone);
			Assert.Equal(new TimeSpan(3, 30, 0), preferences.ScopeSweptFor!.Value.ToOffset(ArchiveFixture.Offset).TimeOfDay);
		}

		Assert.False(File.Exists(clipFile));

		// A batch drops what is outside, without entering it in the ledger, and takes the rest.
		var resent = await phone.BatchAsync(oldItems[0], ArchiveFixture.Item("person", "person-mai", ArchiveFixture.Person("Mai")));
		Assert.Equal(["conversation:conv-old"], Phone.Ids(resent, "ignored"));
		Assert.Equal(BatchApplier.OutsideScope, resent.GetProperty("ignored")[0].GetProperty("reason").GetString());
		Assert.Equal(["person:person-mai"], Phone.Ids(resent, "accepted"));

		// Between nightly runs the window moves on: a conversation that has just fallen out is never shown.
		var edge = fx.Today.AddDays(-31);
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var row = TestData.Conversation(phone.UserId, "conv-edge", "Grout colors with Sam");
			row.StartedAt = ArchiveFixture.At(edge, 9, 0);
			row.EndedAt = ArchiveFixture.At(edge, 9, 20);
			row.DayKey = edge;
			row.TimeZone = ArchiveFixture.Zone;
			db.Conversations.Add(row);
			db.Recaps.Add(new Recap { UserId = phone.UserId, DayKey = edge, TimeZone = ArchiveFixture.Zone, Headline = "Grout", Text = "Grout colors.", Version = V, ChangedAt = DateTimeOffset.UtcNow, ReceivedAt = DateTimeOffset.UtcNow });
			await db.SaveChangesAsync();
		}

		var status = await ArchiveFixture.CallAsync(mcp, "get_status");
		Assert.Equal(6, status.GetProperty("counts").GetProperty("conversations").GetInt32());
		Assert.Equal(("lastDays", 30), (status.GetProperty("sharing").GetProperty("kind").GetString(), status.GetProperty("sharing").GetProperty("days").GetInt32()));
		Assert.Contains("You share the last 30 days.", status.GetProperty("summary").GetString());
		Assert.DoesNotContain("conv-edge", (await ArchiveFixture.CallAsync(mcp, "list_conversations")).GetProperty("conversations").EnumerateArray().Select(c => c.GetProperty("id").GetString()));
		var grout = (await ArchiveFixture.CallAsync(mcp, "search", new() { ["query"] = "grout" })).GetProperty("results").EnumerateArray().Select(r => r.GetProperty("id").GetString()).ToList();
		Assert.Contains("conv-kitchen", grout);
		Assert.DoesNotContain("conv-edge", grout);
		Assert.DoesNotContain($"recap:{ArchiveFixture.Key(edge)}", grout);
		var outside = await ArchiveFixture.CallAsync(mcp, "get_day", new() { ["date"] = ArchiveFixture.Key(edge) });
		Assert.False(outside.GetProperty("found").GetBoolean());
		Assert.EndsWith("is before what you share with assistants.", outside.GetProperty("summary").GetString());
		Assert.False((await ArchiveFixture.CallAsync(mcp, "get_conversation", new() { ["id"] = "conv-edge" })).GetProperty("found").GetBoolean());

		// The nightly deletion is queued once a night, at 03:30 where the person is, and removes it.
		var runner = factory.Services.GetRequiredService<JobRunner>();
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var schedule = scope.ServiceProvider.GetRequiredService<ScopeSweepSchedule>();
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			Assert.Equal(0, await QueuedFor(db, schedule, DateTimeOffset.UtcNow, phone.UserId));
			var tomorrow = SharingScopes.LatestSweepSlot(DateTimeOffset.UtcNow, LogicalDays.Zone(ArchiveFixture.Zone)).AddDays(1).AddMinutes(1);
			Assert.Equal(1, await QueuedFor(db, schedule, tomorrow, phone.UserId));
			Assert.Equal(0, await QueuedFor(db, schedule, tomorrow.AddMinutes(30), phone.UserId));
			var job = await db.Jobs.AsNoTracking().SingleAsync(j => j.UserId == phone.UserId && j.Type == ScopeSweepJob.Type);
			Assert.Equal(JobState.Pending, job.State);
		}

		for (var i = 0; i < 20 && await runner.RunNextAsync(CancellationToken.None); i++)
		{
		}

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			Assert.False(await db.Conversations.AnyAsync(c => c.UserId == phone.UserId && c.Id == "conv-edge"));
			Assert.False(await db.Recaps.AnyAsync(r => r.UserId == phone.UserId && r.DayKey == edge));
			Assert.Equal(JobState.Succeeded, (await db.Jobs.AsNoTracking().SingleAsync(j => j.UserId == phone.UserId && j.Type == ScopeSweepJob.Type)).State);
		}

		// "From today on": everything before goes, the phone's later items stay; widening brings nothing back by itself,
		// and the phone's resend of an earlier version is taken as new.
		var since = ArchiveFixture.At(fx.Day.AddDays(1), 6, 0);
		var sinceAnswer = await phone.SendAsync(HttpMethod.Put, "/sync/preferences", Phone.Json(new JsonObject { ["scope"] = new JsonObject { ["kind"] = "since", ["since"] = Wire.T(since) } }));
		Assert.Equal(Wire.T(since), JsonDocument.Parse(await sinceAnswer.Content.ReadAsStringAsync()).RootElement.GetProperty("scope").GetProperty("since").GetString());
		var after = await ArchiveFixture.CallAsync(mcp, "list_conversations");
		Assert.Equal(["conv-launch-2"], after.GetProperty("conversations").EnumerateArray().Select(c => c.GetProperty("id").GetString()));

		// On the day the window opens, coverage before its start is not shown: spans are cut at it.
		var firstDay = fx.Day.AddDays(1);
		var firstCoverage = new JsonObject
		{
			["dayKey"] = ArchiveFixture.Key(firstDay),
			["missingMs"] = 0,
			["quietMs"] = 0,
			["recordedMs"] = 7_200_000,
			["spans"] = new JsonArray(
				new JsonObject { ["endedAt"] = Wire.T(ArchiveFixture.At(firstDay, 5, 30)), ["kind"] = "recorded", ["startedAt"] = Wire.T(ArchiveFixture.At(firstDay, 5, 0)) },
				new JsonObject { ["endedAt"] = Wire.T(ArchiveFixture.At(firstDay, 7, 0)), ["kind"] = "recorded", ["startedAt"] = Wire.T(ArchiveFixture.At(firstDay, 5, 45)) }),
			["timeZone"] = ArchiveFixture.Zone,
		};
		Assert.Single(Phone.Ids(await phone.BatchAsync(ArchiveFixture.Item("coverage", ArchiveFixture.Key(firstDay), firstCoverage)), "accepted"));
		var spans = (await ArchiveFixture.CallAsync(mcp, "get_day", new() { ["date"] = ArchiveFixture.Key(firstDay) })).GetProperty("coverage").GetProperty("spans");
		var span = Assert.Single(spans.EnumerateArray());
		Assert.Equal((Wire.T(since), 60.0), (Wire.T(span.GetProperty("startedAt").GetDateTimeOffset()), span.GetProperty("minutes").GetDouble()));
		Assert.Equal(HttpStatusCode.OK, (await phone.SendAsync(HttpMethod.Put, "/sync/preferences", Phone.Json(new JsonObject { ["scope"] = new JsonObject { ["kind"] = "all" } }))).StatusCode);
		Assert.Single((await ArchiveFixture.CallAsync(mcp, "list_conversations")).GetProperty("conversations").EnumerateArray());
		var kitchen = fx.Items().Single(i => i["kind"]!.GetValue<string>() == "conversation" && i["id"]!.GetValue<string>() == "conv-kitchen");
		Assert.Equal(["conversation:conv-kitchen"], Phone.Ids(await phone.BatchAsync(kitchen), "accepted"));

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Jobs.Where(j => j.UserId == phone.UserId).ExecuteDeleteAsync();
		}
	}

	[Fact]
	public async Task Unlinking_deletes_the_archive_and_ends_every_assistants_access()
	{
		var (phone, fx) = await ArchiveFixture.SeedAsync(factory, clips: true, edits: true);
		using var linked = phone;
		using var otherPhone = await Phone.LinkAsync(factory, phone.UserId, "Roger's iPad");
		var userId = phone.UserId;
		string personal, oauthAccess;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var tokens = scope.ServiceProvider.GetRequiredService<ApiTokenService>();
			var (token, secret) = await tokens.CreateAsync(userId, "Codex on the test Mac", TokenAccess.ReadWrite, CancellationToken.None);
			personal = secret;

			// An OAuth connection with a live access token, and an event subscription through each kind of access.
			var client = new OAuthClient { Id = Guid.CreateVersion7(), ClientId = $"dcr_{Guid.NewGuid():N}", Kind = OAuthClientKind.Registered, Name = "ChatGPT", RedirectUris = ["https://chatgpt.com/connector/oauth/test"], CreatedAt = DateTimeOffset.UtcNow };
			var grant = new OAuthGrant { Id = Guid.CreateVersion7(), UserId = userId, OAuthClientId = client.Id, Scopes = [ArchiveScopes.Read], Resource = $"{ArchiveServerFactory.PublicOrigin}/mcp", RedirectUri = client.RedirectUris[0], CreatedAt = DateTimeOffset.UtcNow, ExpiresAt = DateTimeOffset.UtcNow.AddDays(30) };
			oauthAccess = $"{OAuthServer.AccessTokenPrefix}{Guid.NewGuid():N}";
			db.OAuthClients.Add(client);
			db.OAuthGrants.Add(grant);
			db.OAuthTokens.Add(new OAuthToken { Id = Guid.CreateVersion7(), GrantId = grant.Id, Kind = OAuthTokenKind.Access, TokenHash = OAuthTokenService.Hash(oauthAccess), CreatedAt = DateTimeOffset.UtcNow, ExpiresAt = DateTimeOffset.UtcNow.AddHours(1) });
			db.EventSubscriptions.Add(Subscription(userId, EventCatalog.DayRecapReady, grantId: grant.Id));
			db.EventSubscriptions.Add(Subscription(userId, EventCatalog.FollowUpCreated, tokenId: token.Id));
			await db.SaveChangesAsync();

			var clip = await scope.ServiceProvider.GetRequiredService<PhoneRequestService>()
				.RequestClipAsync(userId, "conv-kitchen", fx.At(10, 5), fx.At(10, 6), CancellationToken.None);
			Assert.Equal(HttpStatusCode.Created, (await phone.SendAsync(HttpMethod.Put, $"/sync/clips/{clip.RequestId}", SyncTests.Clip(OggSpeexFile.FromFixture()))).StatusCode);
		}

		using var api = factory.CreateClient();
		Assert.Equal(HttpStatusCode.OK, (await api.SendAsync(McpTests.McpPost(personal))).StatusCode);
		Assert.Equal(HttpStatusCode.OK, (await api.SendAsync(McpTests.McpPost(oauthAccess))).StatusCode);
		Assert.Equal(2, (await phone.GetJsonAsync("/sync/status")).GetProperty("access").GetArrayLength());
		Assert.True(Directory.Exists(Path.Combine(factory.ClipsPath, userId.ToString("N"))));

		// The admin area unlinks an old phone while others stay linked: only its token ends.
		using (var oldPhone = await Phone.LinkAsync(factory, userId, "An old iPhone"))
		{
			await using var scope = factory.Services.CreateAsyncScope();
			Assert.True(await scope.ServiceProvider.GetRequiredService<ArchiveWipe>().UnlinkFromAdminAsync(userId, oldPhone.DeviceId, CancellationToken.None));
			Assert.Equal(HttpStatusCode.Unauthorized, (await oldPhone.SendAsync(HttpMethod.Get, "/sync/status")).StatusCode);
			Assert.True(await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Conversations.AnyAsync(c => c.UserId == userId));
			Assert.Equal(2, (await phone.GetJsonAsync("/sync/status")).GetProperty("access").GetArrayLength());
		}

		// The person unlinks on the phone.
		Assert.Equal(HttpStatusCode.NoContent, (await phone.SendAsync(HttpMethod.Delete, "/link")).StatusCode);

		Assert.Equal(HttpStatusCode.Unauthorized, (await phone.SendAsync(HttpMethod.Get, "/sync/status")).StatusCode);
		Assert.Equal(HttpStatusCode.Unauthorized, (await api.SendAsync(McpTests.McpPost(personal))).StatusCode);
		Assert.Equal(HttpStatusCode.Unauthorized, (await api.SendAsync(McpTests.McpPost(oauthAccess))).StatusCode);
		Assert.False(Directory.Exists(Path.Combine(factory.ClipsPath, userId.ToString("N"))));
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			Assert.Equal(0, await db.Conversations.CountAsync(c => c.UserId == userId));
			Assert.Equal(0, await db.Transcripts.CountAsync(t => t.UserId == userId));
			Assert.Equal(0, await db.Recaps.CountAsync(r => r.UserId == userId));
			Assert.Equal(0, await db.FollowUps.CountAsync(f => f.UserId == userId));
			Assert.Equal(0, await db.Notes.CountAsync(n => n.UserId == userId));
			Assert.Equal(0, await db.People.CountAsync(p => p.UserId == userId));
			Assert.Equal(0, await db.SyncItems.CountAsync(s => s.UserId == userId));
			Assert.Equal(0, await db.Clips.CountAsync(c => c.UserId == userId));
			Assert.Equal(0, await db.Requests.CountAsync(r => r.UserId == userId));
			Assert.Equal(0, await db.AiReads.CountAsync(a => a.UserId == userId));
			Assert.Equal(0, await db.OAuthGrants.CountAsync(g => g.UserId == userId));
			Assert.Equal(0, await db.EventSubscriptions.CountAsync(s => s.UserId == userId));
			Assert.Equal(0, await db.ApiTokens.CountAsync(t => t.UserId == userId && t.RevokedAt == null));
		}

		// The other phone stays linked, with an empty archive and nobody reading it.
		var remaining = await otherPhone.GetJsonAsync("/sync/status");
		Assert.Equal(0, remaining.GetProperty("counts").GetProperty("conversation").GetInt32());
		Assert.Equal(0, remaining.GetProperty("access").GetArrayLength());

		// It syncs again and an assistant connects; the admin area then unlinks it, the last phone, which clears the
		// server as unlinking on the phone does.
		await otherPhone.BatchAsync(fx.Items());
		string again;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			(_, again) = await scope.ServiceProvider.GetRequiredService<ApiTokenService>().CreateAsync(userId, "Codex again", TokenAccess.Read, CancellationToken.None);
			Assert.True(await scope.ServiceProvider.GetRequiredService<ArchiveWipe>().UnlinkFromAdminAsync(userId, otherPhone.DeviceId, CancellationToken.None));
			Assert.False(await scope.ServiceProvider.GetRequiredService<ArchiveWipe>().UnlinkFromAdminAsync(userId, otherPhone.DeviceId, CancellationToken.None));
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			Assert.Equal(0, await db.Conversations.CountAsync(c => c.UserId == userId));
			Assert.Equal(0, await db.SyncItems.CountAsync(s => s.UserId == userId));
		}

		Assert.Equal(HttpStatusCode.Unauthorized, (await otherPhone.SendAsync(HttpMethod.Get, "/sync/status")).StatusCode);
		Assert.Equal(HttpStatusCode.Unauthorized, (await api.SendAsync(McpTests.McpPost(again))).StatusCode);
	}

	[Fact]
	public async Task Batches_announce_changed_recaps_and_follow_ups_the_phone_adds()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			db.EventSubscriptions.Add(Subscription(userId, EventCatalog.DayRecapReady));
			db.EventSubscriptions.Add(Subscription(userId, EventCatalog.FollowUpCreated));
			await db.SaveChangesAsync();
		}

		var fx = new ArchiveFixture();
		var yesterday = fx.Today.AddDays(-1);
		var now = DateTimeOffset.UtcNow;
		JsonObject Recap(string text, long version, DateOnly? day = null) =>
			ArchiveFixture.Item("recap", ArchiveFixture.Key(day ?? yesterday), ArchiveFixture.Recap(day ?? yesterday, "Tiles", "Tiles with Sam.", text, []), version);

		// A new recap, the same text again, a changed text, and an old day the phone is catching up on.
		await phone.BatchAsync(Recap("Tiles with Sam.", V));
		Assert.Equal([EventCatalog.DayRecapReady], await EventsAsync(userId));
		await phone.BatchAsync(Recap("Tiles with Sam.", V + 1));
		Assert.Single(await EventsAsync(userId));
		await phone.BatchAsync(Recap("Tiles with Sam, and the grout.", V + 2));
		Assert.Equal(2, (await EventsAsync(userId)).Count);
		await phone.BatchAsync(Recap("An old day.", V, fx.Today.AddDays(-10)));
		Assert.Equal(2, (await EventsAsync(userId)).Count);

		// A follow-up the phone adds is announced once; an edit of it, an old one, and an assistant's are not.
		await phone.BatchAsync(ArchiveFixture.Item("followUp", "fu-new", ArchiveFixture.FollowUp("Send Sam the samples", null, null, now.AddMinutes(-5))));
		Assert.Equal(EventCatalog.FollowUpCreated, (await EventsAsync(userId))[^1]);
		await phone.BatchAsync(ArchiveFixture.Item("followUp", "fu-new", ArchiveFixture.FollowUp("Send Sam the tile samples", null, null, now.AddMinutes(-5)), V + 1));
		await phone.BatchAsync(ArchiveFixture.Item("followUp", "fu-history", ArchiveFixture.FollowUp("Measure the kitchen", null, null, now.AddDays(-10))));
		await phone.BatchAsync(ArchiveFixture.Item("followUp", "fu-assistant", ArchiveFixture.FollowUp("Call the tile shop", null, null, now, origin: "assistant")));
		var events = await EventsAsync(userId);
		Assert.Equal([EventCatalog.DayRecapReady, EventCatalog.DayRecapReady, EventCatalog.FollowUpCreated], events);

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var delivery = await db.Jobs.AsNoTracking().Where(j => j.UserId == userId && j.Type == EventDeliveryJob.Type).OrderBy(j => j.Id).FirstAsync();
			var data = delivery.Payload!.RootElement.GetProperty("data");
			Assert.Equal(ArchiveFixture.Key(yesterday), data.GetProperty("day").GetString());
			Assert.Equal($"{ArchiveServerFactory.PublicOrigin}/d/{ArchiveFixture.Key(yesterday)}", data.GetProperty("url").GetString());
			await db.Jobs.Where(j => j.UserId == userId).ExecuteDeleteAsync();
		}
	}

	private async Task<List<string>> EventsAsync(Guid userId)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		var jobs = await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Jobs.AsNoTracking()
			.Where(j => j.UserId == userId && j.Type == EventDeliveryJob.Type)
			.OrderBy(j => j.Id)
			.ToListAsync();
		return [.. jobs.Select(j => j.Payload!.RootElement.GetProperty("name").GetString()!)];
	}

	private static async Task<int> QueuedFor(ArchiveDbContext db, ScopeSweepSchedule schedule, DateTimeOffset now, Guid userId)
	{
		var before = await db.Jobs.CountAsync(j => j.UserId == userId && j.Type == ScopeSweepJob.Type);
		await schedule.QueueDueAsync(now, CancellationToken.None);
		db.ChangeTracker.Clear();
		return await db.Jobs.CountAsync(j => j.UserId == userId && j.Type == ScopeSweepJob.Type) - before;
	}

	private static EventSubscription Subscription(Guid userId, string eventName, Guid? grantId = null, Guid? tokenId = null) => new()
	{
		Id = $"sub_{Guid.NewGuid():N}",
		UserId = userId,
		EventName = eventName,
		CallbackUrl = "https://receiver.test/events",
		ProtectedSecret = "unused",
		ClientName = "ChatGPT",
		GrantId = grantId,
		ApiTokenId = tokenId,
		CreatedAt = DateTimeOffset.UtcNow,
		RenewedAt = DateTimeOffset.UtcNow,
		VerifiedAt = DateTimeOffset.UtcNow,
	};
}
