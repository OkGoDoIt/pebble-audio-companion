using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Tests;

[Collection(ServerCollection.Name)]
public sealed class SyncTests(ArchiveServerFactory factory)
{
	private const long V = 1_791_999_175_292;

	[Fact]
	public async Task A_linked_phone_syncs_every_kind_and_a_replayed_batch_changes_nothing()
	{
		var userId = await factory.CreateUserAsync();
		using var anonymous = factory.CreateClient();

		// Codes: a wrong one, one replaced by a newer one, and a used one are all refused.
		Assert.Equal(HttpStatusCode.Conflict, (await anonymous.SendAsync(Phone.LinkRequest("AAAA-AAAA"))).StatusCode);
		string replaced, code;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var links = scope.ServiceProvider.GetRequiredService<PhoneLinkService>();
			replaced = (await links.MintAsync(userId, CancellationToken.None)).Code;
			var minted = await links.MintAsync(userId, CancellationToken.None);
			code = minted.Code;
			Assert.Equal(SyncProtocol.LinkCodeLength, code.Length);
			Assert.InRange(minted.ExpiresAt - DateTimeOffset.UtcNow, TimeSpan.FromMinutes(9), TimeSpan.FromMinutes(10));
		}

		Assert.Equal(HttpStatusCode.Conflict, (await anonymous.SendAsync(Phone.LinkRequest(replaced))).StatusCode);
		// Typed the way a person might: lower case, with the dash the admin page shows.
		var linked = await anonymous.SendAsync(Phone.LinkRequest(PhoneLinkService.Display(code).ToLowerInvariant()));
		Assert.Equal(HttpStatusCode.Created, linked.StatusCode);
		Assert.Equal(HttpStatusCode.Conflict, (await anonymous.SendAsync(Phone.LinkRequest(code))).StatusCode);
		using var body = JsonDocument.Parse(await linked.Content.ReadAsStringAsync());
		var token = body.RootElement.GetProperty("deviceToken").GetString()!;
		Assert.StartsWith(SyncAuth.TokenPrefix, token);
		using var phone = new Phone(factory, token, Guid.Parse(body.RootElement.GetProperty("deviceId").GetString()!), userId);

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var device = await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Devices.AsNoTracking().SingleAsync(d => d.Id == phone.DeviceId);
			Assert.Equal("Roger's iPhone", device.Name);
			Assert.Equal(("1.4", "812"), (device.AppVersion, device.AppBuild));
			Assert.Equal(SyncAuth.Hash(token), device.TokenHash);
		}

		// Guessing is slowed per address; right codes are not counted.
		using (var limiter = new LinkAttemptLimiter())
		{
			for (var i = 0; i < LinkAttemptLimiter.FailuresPerWindow; i++)
			{
				Assert.False(limiter.IsBlocked("203.0.113.9"));
				limiter.RecordFailure("203.0.113.9");
			}

			Assert.True(limiter.IsBlocked("203.0.113.9"));
			Assert.False(limiter.IsBlocked("198.51.100.1"));
		}

		// An app that does not say its protocol is told the minimum.
		var unversioned = new HttpRequestMessage(HttpMethod.Get, "/sync/status");
		unversioned.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
		var tooOld = await phone.SendAsync(unversioned);
		Assert.Equal(HttpStatusCode.UpgradeRequired, tooOld.StatusCode);
		Assert.Equal(1, JsonDocument.Parse(await tooOld.Content.ReadAsStringAsync()).RootElement.GetProperty("minimum").GetInt32());

		// One batch of every kind, as the phone builds it, with two items the phone got wrong.
		var conversationId = $"conv-seg-{Guid.NewGuid():N}";
		var broken = Wire.Conversation("No pieces");
		broken.Remove("pieces");
		JsonObject[] batch =
		[
			Wire.Item("conversation", conversationId, V, payload: Wire.Conversation("Stale audiobook playback on the watch")),
			Wire.Item("transcript", conversationId, V + 1, payload: Wire.Transcript(conversationId, "BookPlayer keeps publishing a playback rate of one while paused.")),
			Wire.Item("recap", "2026-10-14", V + 2, payload: Wire.Recap(conversationId)),
			Wire.Item("brief", "week:2026-10-11", V + 3, payload: Wire.Brief()),
			Wire.Item("followUp", $"fu-{conversationId}", V + 4, payload: Wire.FollowUp("Check the AMS playback rate", conversationId)),
			Wire.Item("note", $"note-{conversationId}", V + 5, payload: Wire.Note(conversationId, "Rate 1.0 while paused.")),
			Wire.Item("person", "person-roger", V + 6, payload: Wire.Person("Roger")),
			Wire.Item("coverage", "2026-10-14", V + 7, payload: Wire.Coverage()),
			Wire.Item("conversation", "conv-broken", V, payload: broken),
			Wire.Item("gadget", "g-1", V, payload: new JsonObject()),
		];
		var answer = await phone.BatchAsync(batch);
		Assert.Equal(8, answer.GetProperty("accepted").GetArrayLength());
		Assert.Equal(0, answer.GetProperty("ignored").GetArrayLength());
		var rejected = answer.GetProperty("rejected").EnumerateArray().ToList();
		Assert.Equal(["conversation:conv-broken", "gadget:g-1"], Phone.Ids(answer, "rejected"));
		Assert.Equal("payload: pieces missing", rejected[0].GetProperty("reason").GetString());
		Assert.Equal(0, answer.GetProperty("pendingRequests").GetInt32());
		Assert.EndsWith("Z", answer.GetProperty("serverTime").GetString());

		DateTimeOffset receivedAt;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var conversation = await db.Conversations.AsNoTracking().SingleAsync(c => c.UserId == userId && c.Id == conversationId);
			receivedAt = conversation.ReceivedAt;
			Assert.Equal(V, conversation.Version);
			Assert.Equal(Wire.Start, conversation.StartedAt);
			Assert.Equal(new DateOnly(2026, 10, 14), conversation.DayKey);
			// A whole-segment piece arrives as startMediaMs 0 with no end.
			Assert.Equal((0L, (long?)null), (conversation.Pieces[0].StartMediaMs, conversation.Pieces[0].EndMediaMs));
			Assert.Equal(480_000, conversation.Pieces[1].EndMediaMs);
			Assert.Equal([GapKind.Lost, GapKind.Lost, GapKind.Quiet, GapKind.Quiet], conversation.Gaps.Select(g => g.Kind));
			Assert.Equal(["link", "unknown", null, null], conversation.Gaps.Select(g => g.Origin));
			Assert.Equal([null, null, "watchPause", null], conversation.Gaps.Select(g => g.Reason));

			var transcript = await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == userId && t.ConversationId == conversationId);
			Assert.Null(transcript.Language);
			Assert.Equal([TranscriptItemKind.Turn, TranscriptItemKind.Lost, TranscriptItemKind.Quiet, TranscriptItemKind.Masked], transcript.Items.Select(i => i.Kind));
			Assert.Equal("link", transcript.Items[1].Origin);

			Assert.Equal(conversationId, (await db.FollowUps.AsNoTracking().SingleAsync(f => f.UserId == userId)).SourceConversationId);
			Assert.Equal(ContentOrigin.User, (await db.Notes.AsNoTracking().SingleAsync(n => n.UserId == userId)).Origin);
			Assert.Equal([conversationId], (await db.Recaps.AsNoTracking().SingleAsync(r => r.UserId == userId)).ConversationIds);
			Assert.Equal(BriefKind.Week, (await db.Briefs.AsNoTracking().SingleAsync(b => b.UserId == userId)).Kind);
			Assert.Equal("Roger", (await db.People.AsNoTracking().SingleAsync(p => p.UserId == userId)).Name);
			Assert.Equal(
				[CoverageKind.Recorded, CoverageKind.Paused, CoverageKind.Off],
				(await db.CoverageDays.AsNoTracking().SingleAsync(c => c.UserId == userId)).Spans.Select(s => s.Kind));
			Assert.Equal(8, await db.SyncItems.CountAsync(s => s.UserId == userId));
		}

		// The same batch again: every item is already held, nothing is written.
		var replay = await phone.BatchAsync(batch);
		Assert.Equal(0, replay.GetProperty("accepted").GetArrayLength());
		Assert.Equal(8, replay.GetProperty("ignored").GetArrayLength());
		Assert.All(replay.GetProperty("ignored").EnumerateArray(), i => Assert.Equal("duplicate", i.GetProperty("reason").GetString()));
		Assert.Equal(2, replay.GetProperty("rejected").GetArrayLength());

		// An older version is stale; a newer one replaces the row and its search terms.
		var stale = await phone.BatchAsync(Wire.Item("conversation", conversationId, V - 5, payload: Wire.Conversation("An older title")));
		Assert.Equal("stale", stale.GetProperty("ignored")[0].GetProperty("reason").GetString());
		var newer = await phone.BatchAsync(Wire.Item("conversation", conversationId, V + 100, payload: Wire.Conversation("Why BookPlayer lies about playback")));
		Assert.Equal([$"conversation:{conversationId}"], Phone.Ids(newer, "accepted"));
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var conversation = await db.Conversations.AsNoTracking().SingleAsync(c => c.UserId == userId && c.Id == conversationId);
			Assert.Equal("Why BookPlayer lies about playback", conversation.Title);
			Assert.Equal(V + 100, conversation.Version);
			Assert.True(conversation.ReceivedAt > receivedAt);
			Assert.Equal([conversationId], await SearchAsync(db, userId, "lies"));
			Assert.Empty(await SearchAsync(db, userId, "stale"));
		}

		// Over the limits: 201 items, or more than 8 MB.
		var tooMany = await phone.SendAsync(
			HttpMethod.Put,
			"/sync/batch",
			Phone.BatchBody(phone.DeviceId, Enumerable.Range(0, SyncProtocol.MaxBatchItems + 1).Select(i => Wire.Item("person", $"p-{i}", V, payload: Wire.Person("Someone")))));
		Assert.Equal(HttpStatusCode.RequestEntityTooLarge, tooMany.StatusCode);
		var huge = await phone.SendAsync(
			HttpMethod.Put,
			"/sync/batch",
			Phone.BatchBody(phone.DeviceId, [Wire.Item("transcript", conversationId, V + 200, payload: Wire.Transcript(conversationId, new string('a', 9 * 1024 * 1024)))]));
		Assert.Equal(HttpStatusCode.RequestEntityTooLarge, huge.StatusCode);

		var status = await phone.GetJsonAsync("/sync/status");
		var counts = status.GetProperty("counts");
		foreach (var kind in new[] { "conversation", "transcript", "recap", "brief", "followUp", "note", "person", "coverage" })
		{
			Assert.Equal(1, counts.GetProperty(kind).GetInt32());
		}

		Assert.True(DateTimeOffset.UtcNow - status.GetProperty("lastBatchAt").GetDateTimeOffset() < TimeSpan.FromMinutes(1));
		Assert.Equal(0, status.GetProperty("pendingRequests").GetInt32());
		Assert.Equal(0, status.GetProperty("aiReads").GetArrayLength());
		Assert.Equal(0, status.GetProperty("access").GetArrayLength());

		// Unlinked: the token stops working at once (what goes with it is AccountTests').
		Assert.Equal(HttpStatusCode.NoContent, (await phone.SendAsync(HttpMethod.Delete, "/link")).StatusCode);
		Assert.Equal(HttpStatusCode.Unauthorized, (await phone.SendAsync(HttpMethod.Get, "/sync/status")).StatusCode);
	}

	[Fact]
	public async Task A_delete_removes_what_derives_from_a_conversation_and_an_expire_keeps_it()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		await phone.AllowAsync(clips: true, edits: true);
		var deleted = $"conv-seg-{Guid.NewGuid():N}";
		var expired = $"conv-seg-{Guid.NewGuid():N}";
		await phone.BatchAsync(
			Wire.Item("conversation", deleted, V, payload: Wire.Conversation("Pebble firmware review")),
			Wire.Item("transcript", deleted, V, payload: Wire.Transcript(deleted, "The firmware review went long.")),
			Wire.Item("note", "note-deleted", V, payload: Wire.Note(deleted, "Review notes.")),
			Wire.Item("followUp", "fu-deleted", V, payload: Wire.FollowUp("Send the review notes", deleted)),
			Wire.Item("conversation", expired, V, payload: Wire.Conversation("Lunch plans", start: Wire.Start.AddHours(2))),
			Wire.Item("transcript", expired, V, payload: Wire.Transcript(expired, "Noodles again.")));

		// A clip of the conversation, uploaded, and an assistant that read both conversations.
		Guid requestId;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var requests = scope.ServiceProvider.GetRequiredService<PhoneRequestService>();
			var clip = await requests.RequestClipAsync(userId, deleted, Wire.Start.AddMinutes(1), Wire.Start.AddMinutes(2), CancellationToken.None);
			Assert.Equal(ClipOutcome.Waiting, clip.Outcome);
			requestId = clip.RequestId!.Value;
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			db.AiReads.Add(new AiRead { UserId = userId, At = DateTimeOffset.UtcNow, Client = "Claude", Tool = "search", EntityIds = [deleted, expired] });
			await db.SaveChangesAsync();
		}

		var upload = await phone.SendAsync(HttpMethod.Put, $"/sync/clips/{requestId}", Clip(OggSpeexFile.FromFixture()));
		Assert.Equal(HttpStatusCode.Created, upload.StatusCode);
		var clipFile = Directory.GetFiles(Path.Combine(factory.ClipsPath, userId.ToString("N"))).Single();

		// The person deletes the conversation; the phone sends its delete and its transcript's.
		var deletes = await phone.BatchAsync(
			Wire.Item("conversation", deleted, V + 10, "delete"),
			Wire.Item("transcript", deleted, V + 10, "delete"));
		Assert.Equal(2, deletes.GetProperty("accepted").GetArrayLength());
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			Assert.False(await db.Conversations.AnyAsync(c => c.UserId == userId && c.Id == deleted));
			Assert.False(await db.Transcripts.AnyAsync(t => t.UserId == userId && t.ConversationId == deleted));
			Assert.False(await db.Notes.AnyAsync(n => n.UserId == userId));
			Assert.False(await db.Clips.AnyAsync(c => c.UserId == userId));
			Assert.False(await db.Requests.AnyAsync(r => r.UserId == userId));
			var followUp = await db.FollowUps.AsNoTracking().SingleAsync(f => f.UserId == userId);
			Assert.Equal("Send the review notes", followUp.Text);
			Assert.Null(followUp.SourceConversationId);
			Assert.Null(followUp.SourceAt);
			Assert.Equal([expired], (await db.AiReads.AsNoTracking().SingleAsync(a => a.UserId == userId)).EntityIds);
			var ledger = await db.SyncItems.AsNoTracking().SingleAsync(s => s.UserId == userId && s.Kind == SyncKind.Conversation && s.EntityId == deleted);
			Assert.Equal((SyncOp.Delete, V + 10), (ledger.Op, ledger.Version));
		}

		Assert.False(File.Exists(clipFile));

		// A late copy of the old upsert does not bring it back.
		var late = await phone.BatchAsync(Wire.Item("conversation", deleted, V, payload: Wire.Conversation("Pebble firmware review")));
		Assert.Equal("stale", late.GetProperty("ignored")[0].GetProperty("reason").GetString());

		// Retention ages the other one out: the server keeps it and knows the phone no longer has its audio.
		var changedAt = DateTimeOffset.FromUnixTimeMilliseconds(V + 20);
		await phone.BatchAsync(
			Wire.Item("conversation", expired, V + 20, "expire"),
			Wire.Item("transcript", expired, V + 20, "expire"));
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			var kept = await db.Conversations.AsNoTracking().SingleAsync(c => c.UserId == userId && c.Id == expired);
			Assert.Equal("Lunch plans", kept.Title);
			Assert.Equal(changedAt, kept.ExpiredOnPhoneAt);
			Assert.Equal(changedAt, (await db.Transcripts.AsNoTracking().SingleAsync(t => t.UserId == userId && t.ConversationId == expired)).ExpiredOnPhoneAt);

			var clip = await scope.ServiceProvider.GetRequiredService<PhoneRequestService>()
				.RequestClipAsync(userId, expired, Wire.Start.AddHours(2), Wire.Start.AddHours(2).AddMinutes(1), CancellationToken.None);
			Assert.Equal(ClipOutcome.Unavailable, clip.Outcome);
			Assert.Null(clip.RequestId);
			Assert.False(await db.Requests.AnyAsync(r => r.UserId == userId));
		}
	}

	[Fact]
	public async Task A_transcript_that_arrives_first_is_found_once_its_conversation_comes()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		var id = $"conv-seg-{Guid.NewGuid():N}";

		var first = await phone.BatchAsync(Wire.Item("transcript", id, V + 1, payload: Wire.Transcript(id, "The quarterly numbers came in under the forecast.")));
		Assert.Equal([$"transcript:{id}"], Phone.Ids(first, "accepted"));
		var status = await phone.GetJsonAsync("/sync/status");
		Assert.Equal((1, 0), (status.GetProperty("counts").GetProperty("transcript").GetInt32(), status.GetProperty("counts").GetProperty("conversation").GetInt32()));
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			Assert.Empty(await SearchAsync(scope.ServiceProvider.GetRequiredService<ArchiveDbContext>(), userId, "forecast"));
		}

		await phone.BatchAsync(Wire.Item("conversation", id, V, payload: Wire.Conversation("Budget review")));
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			Assert.Equal([id], await SearchAsync(db, userId, "forecast"));
			Assert.Equal([id], await SearchAsync(db, userId, "budget"));
		}
	}

	[Fact]
	public async Task Device_tokens_and_access_tokens_never_open_each_others_surface()
	{
		var userId = await factory.CreateUserAsync();
		var otherUserId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		string secret;
		Guid tokenId, otherTokenId;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var tokens = scope.ServiceProvider.GetRequiredService<ApiTokenService>();
			var (token, created) = await tokens.CreateAsync(userId, "Codex on the test Mac", TokenAccess.ReadWrite, CancellationToken.None);
			(secret, tokenId) = (created, token.Id);
			otherTokenId = (await tokens.CreateAsync(otherUserId, "Someone else's Claude", TokenAccess.Read, CancellationToken.None)).Token.Id;
		}

		using var client = factory.CreateClient();
		Assert.Equal(HttpStatusCode.Unauthorized, (await client.SendAsync(McpTests.McpPost(phone.Token))).StatusCode);
		Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(McpTests.McpPost(secret))).StatusCode);
		foreach (var bearer in new[] { secret, null, "pad_this-token-was-never-issued" })
		{
			var request = new HttpRequestMessage(HttpMethod.Get, "/sync/status");
			request.Headers.Add(SyncProtocol.VersionHeader, "1");
			if (bearer is not null)
			{
				request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearer);
			}

			Assert.Equal(HttpStatusCode.Unauthorized, (await client.SendAsync(request)).StatusCode);
		}

		// The phone sees who can read the archive, by name, and can take that access away.
		var access = Assert.Single((await phone.GetJsonAsync("/sync/status")).GetProperty("access").EnumerateArray());
		Assert.Equal("token", access.GetProperty("kind").GetString());
		Assert.Equal(tokenId.ToString(), access.GetProperty("id").GetString());
		Assert.Equal("Codex on the test Mac", access.GetProperty("name").GetString());
		Assert.Equal([ArchiveScopes.Read, ArchiveScopes.Write], access.GetProperty("scopes").EnumerateArray().Select(s => s.GetString()));
		Assert.NotEqual(JsonValueKind.Null, access.GetProperty("lastUsedAt").ValueKind);

		Assert.Equal(HttpStatusCode.NotFound, (await phone.SendAsync(HttpMethod.Delete, $"/sync/access/token/{otherTokenId}")).StatusCode);
		Assert.Equal(HttpStatusCode.NotFound, (await phone.SendAsync(HttpMethod.Delete, $"/sync/access/oauth/{tokenId}")).StatusCode);
		Assert.Equal(HttpStatusCode.NoContent, (await phone.SendAsync(HttpMethod.Delete, $"/sync/access/token/{tokenId}")).StatusCode);
		Assert.Equal(HttpStatusCode.NotFound, (await phone.SendAsync(HttpMethod.Delete, $"/sync/access/token/{tokenId}")).StatusCode);
		Assert.Equal(HttpStatusCode.Unauthorized, (await client.SendAsync(McpTests.McpPost(secret))).StatusCode);
		Assert.Equal(0, (await phone.GetJsonAsync("/sync/status")).GetProperty("access").GetArrayLength());
	}

	[Fact]
	public async Task A_wipe_deletes_everything_of_that_user_and_nothing_of_anyone_else()
	{
		var userId = await factory.CreateUserAsync();
		var otherUserId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		using var other = await Phone.LinkAsync(factory, otherUserId, "Someone else's iPhone");
		var id = $"conv-seg-{Guid.NewGuid():N}";
		JsonObject[] items =
		[
			Wire.Item("conversation", id, V, payload: Wire.Conversation("Moving apartments")),
			Wire.Item("transcript", id, V, payload: Wire.Transcript(id, "The movers come on Thursday.")),
			Wire.Item("followUp", "fu-movers", V, payload: Wire.FollowUp("Confirm the movers", id)),
			Wire.Item("person", "person-roger", V, payload: Wire.Person("Roger")),
		];
		await phone.BatchAsync(items);
		await other.BatchAsync(items);
		await phone.AllowAsync(clips: true, edits: false);

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var clip = await scope.ServiceProvider.GetRequiredService<PhoneRequestService>()
				.RequestClipAsync(userId, id, Wire.Start, Wire.Start.AddMinutes(1), CancellationToken.None);
			Assert.Equal(HttpStatusCode.Created, (await phone.SendAsync(HttpMethod.Put, $"/sync/clips/{clip.RequestId}", Clip(OggSpeexFile.FromFixture()))).StatusCode);
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			db.AiReads.Add(new AiRead { UserId = userId, At = DateTimeOffset.UtcNow, Client = "Claude", Tool = "fetch", EntityIds = [id] });
			db.AiReads.Add(new AiRead { UserId = otherUserId, At = DateTimeOffset.UtcNow, Client = "ChatGPT", Tool = "fetch", EntityIds = [id] });
			await db.SaveChangesAsync();
		}

		Assert.True(Directory.Exists(Path.Combine(factory.ClipsPath, userId.ToString("N"))));
		Assert.Equal(HttpStatusCode.BadRequest, (await phone.SendAsync(HttpMethod.Post, "/sync/wipe", Phone.Json(new JsonObject { ["confirm"] = "yes" }))).StatusCode);
		Assert.Equal(HttpStatusCode.OK, (await phone.SendAsync(HttpMethod.Post, "/sync/wipe", Phone.Json(new JsonObject { ["confirm"] = "wipe" }))).StatusCode);

		await using (var scope = factory.Services.CreateAsyncScope())
		{
			var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
			Assert.Equal(0, await db.Conversations.CountAsync(c => c.UserId == userId));
			Assert.Equal(0, await db.Transcripts.CountAsync(t => t.UserId == userId));
			Assert.Equal(0, await db.FollowUps.CountAsync(f => f.UserId == userId));
			Assert.Equal(0, await db.People.CountAsync(p => p.UserId == userId));
			Assert.Equal(0, await db.SyncItems.CountAsync(s => s.UserId == userId));
			Assert.Equal(0, await db.Requests.CountAsync(r => r.UserId == userId));
			Assert.Equal(0, await db.Clips.CountAsync(c => c.UserId == userId));
			Assert.Equal(0, await db.Jobs.CountAsync(j => j.UserId == userId));
			Assert.Equal(0, await db.AiReads.CountAsync(a => a.UserId == userId));

			Assert.Equal(1, await db.Conversations.CountAsync(c => c.UserId == otherUserId));
			Assert.Equal(1, await db.Transcripts.CountAsync(t => t.UserId == otherUserId));
			Assert.Equal(1, await db.FollowUps.CountAsync(f => f.UserId == otherUserId));
			Assert.Equal(4, await db.SyncItems.CountAsync(s => s.UserId == otherUserId));
			Assert.Equal(1, await db.AiReads.CountAsync(a => a.UserId == otherUserId));
		}

		Assert.False(Directory.Exists(Path.Combine(factory.ClipsPath, userId.ToString("N"))));

		// The phone stays linked with its choices, and what it sends next is taken as new.
		Assert.True((await phone.GetJsonAsync("/sync/preferences")).GetProperty("clips").GetBoolean());
		Assert.Equal(0, (await phone.GetJsonAsync("/sync/status")).GetProperty("counts").GetProperty("conversation").GetInt32());
		Assert.Equal(4, (await phone.BatchAsync(items)).GetProperty("accepted").GetArrayLength());
	}

	[Fact]
	public async Task Assistant_writes_wait_for_the_persons_permission_and_round_trip_through_the_phone()
	{
		var userId = await factory.CreateUserAsync();
		using var phone = await Phone.LinkAsync(factory, userId);
		var id = $"conv-seg-{Guid.NewGuid():N}";
		await phone.BatchAsync(
			Wire.Item("conversation", id, V, payload: Wire.Conversation("Planning the trip")),
			Wire.Item("followUp", "fu-phone", V, payload: Wire.FollowUp("Book the train", id)));

		await using var scope = factory.Services.CreateAsyncScope();
		var requests = scope.ServiceProvider.GetRequiredService<PhoneRequestService>();
		var db = scope.ServiceProvider.GetRequiredService<ArchiveDbContext>();
		var none = CancellationToken.None;
		var draft = new FollowUpDraft("Ask Mai about the hotel", Quote: "Mai knows a place.", SourceConversationId: id, SourceAt: Wire.Start.AddMinutes(3));

		// Until the phone allows it, nothing is stored or asked.
		var preferences = await phone.GetJsonAsync("/sync/preferences");
		Assert.False(preferences.GetProperty("clips").GetBoolean());
		Assert.False(preferences.GetProperty("edits").GetBoolean());
		Assert.Equal(ClipOutcome.NotAllowed, (await requests.RequestClipAsync(userId, id, Wire.Start, Wire.Start.AddMinutes(1), none)).Outcome);
		Assert.Equal(PhoneWriteOutcome.NotAllowed, (await requests.CreateFollowUpAsync(userId, draft, none)).Outcome);
		Assert.Equal(PhoneWriteOutcome.NotAllowed, (await requests.UpdateFollowUpAsync(userId, "fu-phone", new FollowUpChange { Done = true }, none)).Outcome);
		Assert.Equal(PhoneWriteOutcome.NotAllowed, (await requests.CreateNoteAsync(userId, new NoteDraft(id, "Trip", "Hotel near the station."), none)).Outcome);
		Assert.False(await db.Requests.AnyAsync(r => r.UserId == userId));

		// Edits only: clips stay off.
		var put = await phone.SendAsync(HttpMethod.Put, "/sync/preferences", Phone.Json(new JsonObject { ["edits"] = true }));
		Assert.Equal(HttpStatusCode.OK, put.StatusCode);
		preferences = await phone.GetJsonAsync("/sync/preferences");
		Assert.Equal((false, true), (preferences.GetProperty("clips").GetBoolean(), preferences.GetProperty("edits").GetBoolean()));
		Assert.Equal(ClipOutcome.NotAllowed, (await requests.RequestClipAsync(userId, id, Wire.Start, Wire.Start.AddMinutes(1), none)).Outcome);

		var created = await requests.CreateFollowUpAsync(userId, draft, none);
		Assert.Equal(PhoneWriteOutcome.Queued, created.Outcome);
		Assert.Equal((ContentOrigin.Assistant, 0L), (created.Item!.Origin, created.Item.Version));
		var note = await requests.CreateNoteAsync(userId, new NoteDraft(id, "Trip", "Hotel near the station.", [new NoteCitationDraft(null, Wire.Start.AddMinutes(3))]), none);
		Assert.Equal(PhoneWriteOutcome.Queued, note.Outcome);
		Assert.Equal(PhoneWriteOutcome.NotFound, (await requests.CreateNoteAsync(userId, new NoteDraft("conv-nowhere", "x", "y"), none)).Outcome);
		var done = await requests.UpdateFollowUpAsync(userId, "fu-phone", new FollowUpChange { Done = true, DueAt = new Settable<DateTimeOffset?>(null) }, none);
		Assert.Equal(PhoneWriteOutcome.Queued, done.Outcome);
		Assert.True(done.Item!.Done);
		Assert.Equal(PhoneWriteOutcome.Unchanged, (await requests.UpdateFollowUpAsync(userId, "fu-phone", new FollowUpChange(), none)).Outcome);
		Assert.Equal(PhoneWriteOutcome.NotFound, (await requests.UpdateFollowUpAsync(userId, "fu-nowhere", new FollowUpChange { Done = true }, none)).Outcome);

		// The phone pulls them in order, again on every pull until it answers.
		var pulled = (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests").EnumerateArray().ToList();
		Assert.Equal(["followUp.create", "note.create", "followUp.update"], pulled.Select(r => r.GetProperty("kind").GetString()));
		Assert.Equal(3, (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests").GetArrayLength());
		var createPayload = pulled[0].GetProperty("payload");
		Assert.Equal(created.Item.Id, createPayload.GetProperty("id").GetString());
		Assert.Equal("assistant", createPayload.GetProperty("origin").GetString());
		Assert.Equal("Ask Mai about the hotel", createPayload.GetProperty("text").GetString());
		Assert.Equal(Wire.T(Wire.Start.AddMinutes(3)), createPayload.GetProperty("sourceAt").GetString());
		Assert.Equal(JsonValueKind.Null, createPayload.GetProperty("dueAt").ValueKind);
		Assert.Equal(id, pulled[1].GetProperty("payload").GetProperty("citations")[0].GetProperty("conversationId").GetString());
		var update = pulled[2].GetProperty("payload");
		// Only what changed, and null to clear (jsonb keeps the keys in its own order).
		Assert.Equal(["completedAt", "done", "dueAt", "id"], update.EnumerateObject().Select(p => p.Name).Order());
		Assert.Equal(JsonValueKind.Null, update.GetProperty("dueAt").ValueKind);
		Assert.True(pulled.All(r => r.GetProperty("expiresAt").GetDateTimeOffset() > DateTimeOffset.UtcNow.AddHours(23)));

		// The phone's answers: added, could not add the note, changed.
		string Result(int index) => $"/sync/requests/{pulled[index].GetProperty("id").GetString()}/result";
		Assert.Equal(HttpStatusCode.BadRequest, (await phone.SendAsync(HttpMethod.Post, Result(0), Phone.Json(new JsonObject { ["status"] = "maybe" }))).StatusCode);
		Assert.Equal(HttpStatusCode.NotFound, (await phone.SendAsync(HttpMethod.Post, $"/sync/requests/{Guid.NewGuid()}/result", Phone.Json(new JsonObject { ["status"] = "done" }))).StatusCode);
		Assert.Equal(HttpStatusCode.NoContent, (await phone.SendAsync(HttpMethod.Post, Result(0), Phone.Json(new JsonObject { ["status"] = "done", ["detail"] = null }))).StatusCode);
		Assert.Equal(HttpStatusCode.NoContent, (await phone.SendAsync(HttpMethod.Post, Result(1), Phone.Json(new JsonObject { ["status"] = "unavailable", ["detail"] = "This phone does not have that conversation." }))).StatusCode);
		Assert.Equal(HttpStatusCode.NoContent, (await phone.SendAsync(HttpMethod.Post, Result(2), Phone.Json(new JsonObject { ["status"] = "done" }))).StatusCode);
		Assert.Equal(0, (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests").GetArrayLength());
		Assert.False(await db.Notes.AnyAsync(n => n.UserId == userId), "A note the phone could not add is not kept.");

		// The phone syncs the follow-up it added back as its own upsert, which replaces the unconfirmed row.
		var echoed = await phone.BatchAsync(Wire.Item("followUp", created.Item.Id, V + 50, payload: Wire.FollowUp("Ask Mai about the hotel", id, origin: "assistant")));
		Assert.Equal(1, echoed.GetProperty("accepted").GetArrayLength());
		Assert.Equal(0, echoed.GetProperty("pendingRequests").GetInt32());
		var confirmed = await db.FollowUps.AsNoTracking().SingleAsync(f => f.UserId == userId && f.Id == created.Item.Id);
		Assert.Equal((V + 50, ContentOrigin.Assistant), (confirmed.Version, confirmed.Origin));

		// A request the phone never picks up expires, and its unconfirmed row goes with it.
		var unanswered = await requests.CreateFollowUpAsync(userId, draft with { Text = "Pack the charger" }, none);
		Assert.Equal(1, (await phone.GetJsonAsync("/sync/status")).GetProperty("pendingRequests").GetInt32());
		await db.Requests.Where(r => r.Id == unanswered.RequestId).ExecuteUpdateAsync(s => s.SetProperty(r => r.ExpiresAt, DateTimeOffset.UtcNow.AddSeconds(-1)));
		Assert.Equal(0, (await phone.GetJsonAsync("/sync/requests")).GetProperty("requests").GetArrayLength());
		Assert.Equal(PhoneRequestState.Expired, (await db.Requests.AsNoTracking().SingleAsync(r => r.Id == unanswered.RequestId)).State);
		Assert.False(await db.FollowUps.AnyAsync(f => f.UserId == userId && f.Id == unanswered.Item!.Id));
	}

	internal static HttpContent Clip(byte[] ogg, DateTimeOffset? start = null, DateTimeOffset? end = null, string gaps = "[]")
	{
		var content = new ByteArrayContent(ogg);
		content.Headers.ContentType = new MediaTypeHeaderValue("audio/ogg");
		content.Headers.Add("X-Clip-Start-At", Wire.T(start ?? Wire.Start));
		content.Headers.Add("X-Clip-End-At", Wire.T(end ?? Wire.Start.AddMinutes(1)));
		content.Headers.Add("X-Clip-Gaps", gaps);
		return content;
	}

	/// <summary>Search across both halves of the vector: the conversation's and its transcript's.</summary>
	internal static Task<List<string>> SearchAsync(ArchiveDbContext db, Guid userId, string terms) =>
		(
			from conversation in db.Conversations
			join transcript in db.Transcripts
				on new { conversation.UserId, ConversationId = conversation.Id } equals new { transcript.UserId, transcript.ConversationId }
				into transcripts
			from transcript in transcripts.DefaultIfEmpty()
			where conversation.UserId == userId &&
				(conversation.SearchVector.Matches(EF.Functions.WebSearchToTsQuery("english", terms)) ||
					(transcript != null && transcript.SearchVector.Matches(EF.Functions.WebSearchToTsQuery("english", terms))))
			select conversation.Id)
			.ToListAsync();
}
