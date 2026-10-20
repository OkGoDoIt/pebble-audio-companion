using System.Globalization;
using System.Net;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Events;
using PebbleAudio.Server.Jobs;

namespace PebbleAudio.Server.Tests;

/// <summary>
/// MCP Events as ChatGPT drives them: discover, list, subscribe with a signed challenge, signed deliveries from the
/// job queue, retries, and a 410 that ends the subscription.
/// </summary>
[Collection(ServerCollection.Name)]
public sealed class EventsTests(ArchiveServerFactory factory)
{
	private const string Receiver = "https://receiver.test/mcp-events/7f3a9c";

	/// <summary>The research reference's example secret: base64 of the bytes 0x00 to 0x1f.</summary>
	private const string Secret = "whsec_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";

	[Fact]
	public void Signatures_match_the_Standard_Webhooks_test_vector()
	{
		// standard-webhooks/standard-webhooks, libraries/python/tests/test_webhooks.py (test_sign_function).
		var vectorKey = StandardWebhooks.ParseSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")!;
		Assert.Equal(
			"v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=",
			StandardWebhooks.Sign(vectorKey, "msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330, """{"test": 2432232314}"""u8));

		// The verification example in research-verified-2026-10-20.md §4, computed independently.
		var key = StandardWebhooks.ParseSecret(Secret)!;
		var verification = """{"type":"verification","challenge":"q8Zr3mX0b1V2nYk7"}"""u8.ToArray();
		Assert.Equal(
			"v1,L7hCZcdxlvfgE1cAGcQWXPt1+D1GgWcwMQIjbGo1tKs=",
			StandardWebhooks.Sign(key, "msg_verification_7f3a9c", 1792521727, verification));

		// During a rotation both secrets sign, space-separated.
		Assert.Equal(
			"v1,L7hCZcdxlvfgE1cAGcQWXPt1+D1GgWcwMQIjbGo1tKs= " + StandardWebhooks.Sign(vectorKey, "msg_verification_7f3a9c", 1792521727, verification),
			StandardWebhooks.SignatureHeaderValue([key, vectorKey], "msg_verification_7f3a9c", 1792521727, verification));

		// Secrets are whsec_ and 24 to 64 bytes.
		Assert.Null(StandardWebhooks.ParseSecret("whsec_" + Convert.ToBase64String(new byte[23])));
		Assert.NotNull(StandardWebhooks.ParseSecret("whsec_" + Convert.ToBase64String(new byte[64])));
		Assert.Null(StandardWebhooks.ParseSecret("whsec_" + Convert.ToBase64String(new byte[65])));
		Assert.Null(StandardWebhooks.ParseSecret(Secret[6..]));
	}

	[Fact]
	public async Task ChatGPT_subscribes_after_a_signed_challenge_gets_signed_events_and_a_410_ends_the_subscription()
	{
		var userId = await factory.CreateUserAsync();
		var runner = factory.Services.GetRequiredService<JobRunner>();
		string token;
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Jobs.ExecuteDeleteAsync();
			(_, token) = await scope.ServiceProvider.GetRequiredService<ApiTokenService>()
				.CreateAsync(userId, "ChatGPT", TokenAccess.Read, CancellationToken.None);
		}

		using var api = factory.CreateClient();

		// server/discover (2026-07-28) advertises events at the top level, as ChatGPT reads it, and as the SEP's extension.
		var discover = await McpRpc.ResultAsync(await api.SendAsync(McpRpc.Request(token, "server/discover", null, perRequestMetadata: true)));
		var capabilities = discover.GetProperty("capabilities");
		Assert.Equal(JsonValueKind.Object, capabilities.GetProperty("events").ValueKind);
		Assert.Equal(JsonValueKind.Object, capabilities.GetProperty("extensions").GetProperty(McpEvents.ExtensionId).ValueKind);
		Assert.True(capabilities.TryGetProperty("tools", out _));

		var listed = await McpRpc.ResultAsync(await api.SendAsync(McpRpc.Request(token, "events/list", null, perRequestMetadata: true)));
		Assert.Equal("complete", listed.GetProperty("resultType").GetString());
		var events = listed.GetProperty("events").EnumerateArray().ToList();
		Assert.Equal([EventCatalog.DayRecapReady, EventCatalog.FollowUpCreated], events.Select(e => e.GetProperty("name").GetString()));
		Assert.All(events, e => Assert.Equal("webhook", Assert.Single(e.GetProperty("delivery").EnumerateArray()).GetString()));
		Assert.All(events, e => Assert.Equal("object", e.GetProperty("payloadSchema").GetProperty("type").GetString()));

		// A secret that does not decode to 24 to 64 bytes is invalid params.
		var badSecret = await McpRpc.ErrorAsync(await api.SendAsync(Subscribe(token, EventCatalog.DayRecapReady, "whsec_" + Convert.ToBase64String(new byte[16]))));
		Assert.Equal(-32602, badSecret.GetProperty("code").GetInt32());

		// A callback that does not echo the challenge: CallbackEndpointError, and nothing is stored.
		factory.Http.On(Receiver, (_, _) => StubHttp.Json("""{"challenge":"something else"}"""));
		var refused = await McpRpc.ErrorAsync(await api.SendAsync(Subscribe(token, EventCatalog.DayRecapReady)));
		Assert.Equal(McpEventsMethods.CallbackEndpointError, refused.GetProperty("code").GetInt32());
		Assert.Equal("challenge_failed", refused.GetProperty("data").GetProperty("reason").GetString());
		Assert.False(await AnySubscriptionAsync(userId));

		// A receiver that checks the signature and echoes the challenge.
		var verifications = 0;
		var deliveries = new List<(HttpRequestMessage Request, byte[] Body)>();
		var answer = HttpStatusCode.OK;
		factory.Http.On(Receiver, (request, body) =>
		{
			AssertSigned(request, body);
			using var json = JsonDocument.Parse(body);
			if (json.RootElement.TryGetProperty("type", out var type) && type.GetString() == "verification")
			{
				verifications++;
				Assert.StartsWith("msg_verification_", Header(request, StandardWebhooks.IdHeader));
				return StubHttp.Json(JsonSerializer.Serialize(new { challenge = json.RootElement.GetProperty("challenge").GetString() }));
			}

			deliveries.Add((request, body));
			return new HttpResponseMessage(answer);
		});

		var subscribed = await McpRpc.ResultAsync(await api.SendAsync(Subscribe(token, EventCatalog.DayRecapReady, ttlMs: 3_600_000)));
		var subscriptionId = subscribed.GetProperty("id").GetString()!;
		Assert.StartsWith("sub_", subscriptionId);
		Assert.Equal("complete", subscribed.GetProperty("resultType").GetString());
		Assert.Equal(JsonValueKind.Null, subscribed.GetProperty("cursor").ValueKind);
		Assert.False(subscribed.GetProperty("truncated").GetBoolean());
		var refreshBefore = DateTimeOffset.Parse(subscribed.GetProperty("refreshBefore").GetString()!, CultureInfo.InvariantCulture);
		Assert.InRange(refreshBefore - DateTimeOffset.UtcNow, TimeSpan.FromMinutes(55), TimeSpan.FromMinutes(61));
		Assert.Equal(1, verifications);

		// Renewing is the same subscription and needs no second challenge.
		var renewed = await McpRpc.ResultAsync(await api.SendAsync(Subscribe(token, EventCatalog.DayRecapReady, ttlMs: 3_600_000)));
		Assert.Equal(subscriptionId, renewed.GetProperty("id").GetString());
		Assert.Equal(1, verifications);

		// A recap arrives: one signed delivery from the queue, with the event and the subscription in the headers.
		await PublishRecapAsync(userId, version: 1);
		Assert.True(await runner.RunNextAsync(CancellationToken.None));
		var (request, body) = Assert.Single(deliveries);
		Assert.Equal(subscriptionId, Header(request, WebhookClient.SubscriptionHeader));
		using (var delivered = JsonDocument.Parse(body))
		{
			var root = delivered.RootElement;
			Assert.Equal(Header(request, StandardWebhooks.IdHeader), root.GetProperty("eventId").GetString());
			Assert.StartsWith("evt_", root.GetProperty("eventId").GetString());
			Assert.Equal(EventCatalog.DayRecapReady, root.GetProperty("name").GetString());
			Assert.EndsWith("Z", root.GetProperty("timestamp").GetString());
			Assert.Equal(JsonValueKind.Null, root.GetProperty("cursor").ValueKind);
			var data = root.GetProperty("data");
			Assert.Equal("2026-10-20", data.GetProperty("day").GetString());
			Assert.Equal("Roof quote and the watch firmware", data.GetProperty("headline").GetString());
			Assert.Equal(2, data.GetProperty("conversationCount").GetInt32());
			Assert.Equal($"{ArchiveServerFactory.PublicOrigin}/d/2026-10-20", data.GetProperty("url").GetString());
		}

		Assert.NotNull((await SubscriptionAsync(subscriptionId))!.LastDeliveredAt);

		// The receiver fails: the attempt is retried later with the same event id.
		answer = HttpStatusCode.ServiceUnavailable;
		await PublishRecapAsync(userId, version: 2);
		Assert.True(await runner.RunNextAsync(CancellationToken.None));
		var retrying = await JobAsync(EventDeliveryJob.Type, JobState.Pending);
		Assert.Equal(1, retrying.Attempts);
		Assert.Equal("The callback answered 503.", (await SubscriptionAsync(subscriptionId))!.LastError);

		// The retry gets 410 Gone: the subscription is deleted, and the event is not tried again.
		answer = HttpStatusCode.Gone;
		await MakeDueAsync(retrying.Id);
		Assert.True(await runner.RunNextAsync(CancellationToken.None));
		Assert.Equal(JobState.Succeeded, (await JobByIdAsync(retrying.Id)).State);
		Assert.Null(await SubscriptionAsync(subscriptionId));
		Assert.Equal(3, deliveries.Count);
		Assert.Equal(Header(deliveries[1].Request, StandardWebhooks.IdHeader), Header(deliveries[2].Request, StandardWebhooks.IdHeader));
		Assert.False(await runner.RunNextAsync(CancellationToken.None));

		// A follow-up an assistant wrote is never announced; unsubscribing removes the subscription by its identity.
		answer = HttpStatusCode.OK;
		await McpRpc.ResultAsync(await api.SendAsync(Subscribe(token, EventCatalog.FollowUpCreated)));
		await using (var scope = factory.Services.CreateAsyncScope())
		{
			await scope.ServiceProvider.GetRequiredService<IEventPublisher>().FollowUpCreatedAsync(
				new FollowUp { UserId = userId, Id = "fu-assistant-1", Text = "Send Dana the start date", Origin = ContentOrigin.Assistant },
				CancellationToken.None);
		}

		Assert.False(await runner.RunNextAsync(CancellationToken.None));
		var unsubscribed = await McpRpc.ResultAsync(await api.SendAsync(McpRpc.Request(
			token,
			"events/unsubscribe",
			new { name = EventCatalog.FollowUpCreated, arguments = new { }, delivery = new { mode = "webhook", url = Receiver } },
			perRequestMetadata: true)));
		Assert.Equal("complete", unsubscribed.GetProperty("resultType").GetString());
		Assert.False(await AnySubscriptionAsync(userId));
	}

	private static HttpRequestMessage Subscribe(string token, string name, string secret = Secret, long? ttlMs = null)
	{
		var parameters = new Dictionary<string, object?>
		{
			["name"] = name,
			["arguments"] = new { },
			["cursor"] = null,
			["delivery"] = new { mode = "webhook", url = Receiver, secret },
		};
		if (ttlMs is not null)
		{
			parameters["ttlMs"] = ttlMs;
		}

		return McpRpc.Request(token, "events/subscribe", parameters, perRequestMetadata: true);
	}

	private static void AssertSigned(HttpRequestMessage request, byte[] body)
	{
		var id = Header(request, StandardWebhooks.IdHeader);
		var timestamp = long.Parse(Header(request, StandardWebhooks.TimestampHeader), CultureInfo.InvariantCulture);
		Assert.InRange(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - timestamp, 0, 300);
		var expected = StandardWebhooks.Sign(StandardWebhooks.ParseSecret(Secret)!, id, timestamp, body);
		Assert.Contains(expected, Header(request, StandardWebhooks.SignatureHeader).Split(' '));
		Assert.Equal("application/json", request.Content!.Headers.ContentType!.MediaType);
	}

	private static string Header(HttpRequestMessage request, string name) =>
		request.Headers.TryGetValues(name, out var values) ? values.Single() : "";

	private async Task PublishRecapAsync(Guid userId, long version)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		await scope.ServiceProvider.GetRequiredService<IEventPublisher>().DayRecapReadyAsync(
			new Recap
			{
				UserId = userId,
				Version = version,
				DayKey = new DateOnly(2026, 10, 20),
				TimeZone = "Asia/Jakarta",
				Headline = "Roof quote and the watch firmware",
				LineSummary = "Dana quoted the roof repair; the stale now-playing bug turned out to be BookPlayer.",
				ConversationIds = ["conv-1", "conv-2"],
			},
			CancellationToken.None);
	}

	private async Task<bool> AnySubscriptionAsync(Guid userId)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		return await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().EventSubscriptions.AnyAsync(s => s.UserId == userId);
	}

	private async Task<EventSubscription?> SubscriptionAsync(string id)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		return await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().EventSubscriptions.AsNoTracking().SingleOrDefaultAsync(s => s.Id == id);
	}

	private async Task<Job> JobAsync(string type, JobState state)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		return await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Jobs.AsNoTracking().SingleAsync(j => j.Type == type && j.State == state);
	}

	private async Task<Job> JobByIdAsync(long id)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		return await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Jobs.AsNoTracking().SingleAsync(j => j.Id == id);
	}

	private async Task MakeDueAsync(long id)
	{
		await using var scope = factory.Services.CreateAsyncScope();
		await scope.ServiceProvider.GetRequiredService<ArchiveDbContext>().Jobs
			.Where(j => j.Id == id)
			.ExecuteUpdateAsync(s => s.SetProperty(j => j.RunAfter, DateTimeOffset.UtcNow.AddSeconds(-1)));
	}
}
