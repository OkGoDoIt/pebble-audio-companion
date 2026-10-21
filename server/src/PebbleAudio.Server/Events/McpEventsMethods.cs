using System.Buffers.Text;
using System.Globalization;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Events;

/// <summary>
/// The MCP Events methods, as ChatGPT implements them (developers.openai.com/plugins/build/mcp-events, protocol
/// 2026-07-28): <c>events/list</c>, <c>events/subscribe</c>, and <c>events/unsubscribe</c>, on the same
/// authenticated <c>/mcp</c> endpoint as the tools. Webhook delivery only.
/// </summary>
public sealed class McpEventsMethods(
	ArchiveDbContext db,
	WebhookClient webhooks,
	EventSecrets secrets,
	SettingsService settings,
	TimeProvider time,
	ILogger<McpEventsMethods> logger)
{
	/// <summary>
	/// CallbackEndpointError, the code ChatGPT documents for a callback that fails verification. The draft
	/// (SEP-3415) renumbered it to -32027 on 2026-10-08; switch when ChatGPT does.
	/// </summary>
	public const int CallbackEndpointError = -32015;

	/// <summary>Forbidden in the events error range.</summary>
	public const int Forbidden = -32024;

	public static readonly TimeSpan VerificationTimeout = TimeSpan.FromSeconds(5);

	private static readonly TimeSpan ShortestLifetime = TimeSpan.FromMinutes(1);

	public Task<JsonNode> ListAsync(ClaimsPrincipal user, JsonObject? parameters, CancellationToken cancellationToken)
	{
		_ = RequireUser(user);
		var events = new JsonArray();
		foreach (var definition in EventCatalog.All)
		{
			events.Add(new JsonObject
			{
				["name"] = definition.Name,
				["description"] = definition.Description,
				["delivery"] = new JsonArray("webhook"),
				["inputSchema"] = definition.InputSchema.DeepClone(),
				["payloadSchema"] = definition.PayloadSchema.DeepClone(),
			});
		}

		return Task.FromResult<JsonNode>(new JsonObject { ["resultType"] = "complete", ["events"] = events });
	}

	/// <summary>
	/// Creates or renews a subscription. A new callback, or a new secret, is verified first with a signed challenge
	/// it must echo; a failure is <see cref="CallbackEndpointError"/> and nothing is stored.
	/// </summary>
	public async Task<JsonNode> SubscribeAsync(ClaimsPrincipal user, JsonObject? parameters, CancellationToken cancellationToken)
	{
		var userId = RequireUser(user);
		var (definition, arguments, url) = ReadIdentity(parameters);
		var delivery = parameters!["delivery"]!.AsObject();
		var secret = delivery["secret"] is JsonValue s && s.TryGetValue<string>(out var text) ? text : null;
		if (StandardWebhooks.ParseSecret(secret) is null)
		{
			throw InvalidParams("delivery.secret must be whsec_ and base64 of 24 to 64 bytes.");
		}

		// The "Event subscriptions" setting is the default and the ceiling: a request for no expiry (ttlMs null) gets
		// it too, so every subscription has a refreshBefore and lapses when the assistant stops renewing it.
		var config = await settings.GetAsync(cancellationToken);
		var lifetime = config.EventSubscriptionLifetime;
		if (parameters.TryGetPropertyValue("ttlMs", out var ttl))
		{
			lifetime = ttl switch
			{
				null => config.EventSubscriptionLifetime,
				JsonValue value when value.TryGetValue<long>(out var ms) && ms >= 0 => Clamp(TimeSpan.FromMilliseconds(ms), config.EventSubscriptionLifetime),
				_ => throw InvalidParams("ttlMs must be a number of milliseconds, or null."),
			};
		}

		var id = SubscriptionId(userId, url, definition.Name, arguments);
		var now = time.GetUtcNow();
		var existing = await db.EventSubscriptions.SingleOrDefaultAsync(e => e.Id == id, cancellationToken);
		if (!await IsVerifiedAsync(userId, url, secret!, cancellationToken))
		{
			await VerifyAsync(url, id, secret!, cancellationToken);
		}

		var subscription = existing ?? new EventSubscription
		{
			Id = id,
			UserId = userId,
			EventName = definition.Name,
			ArgumentsJson = arguments,
			CallbackUrl = url,
			CreatedAt = now,
		};
		if (existing is null)
		{
			subscription.ProtectedSecret = secrets.Protect(secret!);
			db.EventSubscriptions.Add(subscription);
		}
		else if (secrets.Unprotect(existing.ProtectedSecret) != secret)
		{
			existing.ProtectedPreviousSecret = existing.ProtectedSecret;
			existing.PreviousSecretUntil = now + EventSecrets.RotationOverlap;
			existing.ProtectedSecret = secrets.Protect(secret!);
		}

		subscription.ClientName = user.ClientName();
		subscription.GrantId = user.GrantId();
		subscription.ApiTokenId = user.TokenId();
		subscription.RenewedAt = now;
		subscription.VerifiedAt = now;
		subscription.ExpiresAt = now + lifetime;
		await db.SaveChangesAsync(cancellationToken);
		logger.LogInformation(
			"{Client} subscribed to {Event} at {CallbackHost}{Renewed}.",
			subscription.ClientName,
			definition.Name,
			new Uri(url).Host,
			existing is null ? "" : " (renewed)");

		return new JsonObject
		{
			["resultType"] = "complete",
			["id"] = id,
			["refreshBefore"] = subscription.ExpiresAt?.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
			["cursor"] = null,
			["truncated"] = false,
		};
	}

	/// <summary>Removes a subscription, identified the same way it was created. Removing one that is gone is fine.</summary>
	public async Task<JsonNode> UnsubscribeAsync(ClaimsPrincipal user, JsonObject? parameters, CancellationToken cancellationToken)
	{
		var userId = RequireUser(user);
		var (definition, arguments, url) = ReadIdentity(parameters);
		var id = SubscriptionId(userId, url, definition.Name, arguments);
		await db.EventSubscriptions.Where(s => s.Id == id && s.UserId == userId).ExecuteDeleteAsync(cancellationToken);
		return new JsonObject { ["resultType"] = "complete" };
	}

	/// <summary>
	/// <c>sub_</c> and 32 hex characters of SHA-256 over the user, the callback URL, the event name, and the canonical
	/// arguments, so the same subscription always has the same id.
	/// </summary>
	public static string SubscriptionId(Guid userId, string url, string name, string canonicalArguments)
	{
		var hash = SHA256.HashData(Encoding.UTF8.GetBytes($"{userId:N}\n{url}\n{name}\n{canonicalArguments}"));
		return "sub_" + Convert.ToHexStringLower(hash)[..32];
	}

	/// <summary>JSON with object keys sorted and no whitespace, so equal arguments compare equal.</summary>
	public static string CanonicalJson(JsonNode? node)
	{
		return Canonical(node)?.ToJsonString() ?? "null";

		static JsonNode? Canonical(JsonNode? node) => node switch
		{
			JsonObject obj => new JsonObject(obj
				.OrderBy(p => p.Key, StringComparer.Ordinal)
				.Select(p => KeyValuePair.Create(p.Key, Canonical(p.Value)))),
			JsonArray array => new JsonArray([.. array.Select(Canonical)]),
			null => null,
			_ => node.DeepClone(),
		};
	}

	private (EventDefinition Definition, string Arguments, string Url) ReadIdentity(JsonObject? parameters)
	{
		if (parameters is null)
		{
			throw InvalidParams("params are required.");
		}

		var name = parameters["name"] is JsonValue n && n.TryGetValue<string>(out var value) ? value : null;
		var definition = EventCatalog.Find(name)
			?? throw InvalidParams($"Unknown event '{name}'. events/list names the events this server emits.");

		var arguments = parameters["arguments"] switch
		{
			null => new JsonObject(),
			JsonObject obj => obj,
			_ => throw InvalidParams("arguments must be an object."),
		};

		// Both events take no arguments (their inputSchema allows no properties).
		if (arguments.Count > 0)
		{
			throw InvalidParams($"{definition.Name} takes no arguments.");
		}

		if (parameters["delivery"] is not JsonObject delivery ||
			delivery["mode"] is not JsonValue mode || !mode.TryGetValue<string>(out var modeText) || modeText != "webhook")
		{
			throw InvalidParams("delivery.mode must be webhook.");
		}

		var url = delivery["url"] is JsonValue u && u.TryGetValue<string>(out var urlText) ? urlText : null;
		if (!WebhookClient.IsCallbackUrl(url))
		{
			throw InvalidParams("delivery.url must be an absolute https URL.");
		}

		return (definition, CanonicalJson(arguments), url!);
	}

	/// <summary>
	/// True when this user already has a verified subscription to this callback with this secret, so a renewal or a
	/// second event on the same callback does not need the challenge again.
	/// </summary>
	private async Task<bool> IsVerifiedAsync(Guid userId, string url, string secret, CancellationToken cancellationToken)
	{
		var sameCallback = await db.EventSubscriptions.AsNoTracking()
			.Where(s => s.UserId == userId && s.CallbackUrl == url)
			.Select(s => s.ProtectedSecret)
			.ToListAsync(cancellationToken);
		return sameCallback.Any(protectedSecret => secrets.Unprotect(protectedSecret) == secret);
	}

	private async Task VerifyAsync(string url, string subscriptionId, string secret, CancellationToken cancellationToken)
	{
		var challenge = Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(16));
		var body = Encoding.UTF8.GetBytes(new JsonObject { ["type"] = "verification", ["challenge"] = challenge }.ToJsonString());
		var messageId = "msg_verification_" + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(8));
		var answer = await webhooks.PostAsync(
			url,
			messageId,
			subscriptionId,
			body,
			[StandardWebhooks.ParseSecret(secret)!],
			VerificationTimeout,
			cancellationToken);

		if (answer.TimedOut)
		{
			logger.LogInformation("The callback at {CallbackHost} did not answer the challenge in time.", new Uri(url).Host);
			throw CallbackFailed("timeout", "The callback did not answer the verification challenge in time.");
		}

		if (!answer.IsSuccess || !EchoesChallenge(answer.Body, challenge))
		{
			logger.LogInformation("The callback at {CallbackHost} failed the challenge: {Answer}", new Uri(url).Host, answer.Describe());
			throw CallbackFailed("challenge_failed", "The callback did not echo the verification challenge.");
		}
	}

	private static bool EchoesChallenge(string? body, string challenge)
	{
		try
		{
			using var document = JsonDocument.Parse(body ?? "");
			return document.RootElement.ValueKind == JsonValueKind.Object &&
				document.RootElement.TryGetProperty("challenge", out var echoed) &&
				echoed.ValueKind == JsonValueKind.String &&
				CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(echoed.GetString()!), Encoding.UTF8.GetBytes(challenge));
		}
		catch (JsonException)
		{
			return false;
		}
	}

	private static Guid RequireUser(ClaimsPrincipal user) =>
		user.UserId() ?? throw new McpProtocolException("This request is not signed in to an archive.", (McpErrorCode)Forbidden);

	private static TimeSpan Clamp(TimeSpan requested, TimeSpan longest) =>
		requested < ShortestLifetime ? ShortestLifetime : requested > longest ? longest : requested;

	private static McpProtocolException InvalidParams(string message) => new(message, McpErrorCode.InvalidParams);

	private static McpProtocolException CallbackFailed(string reason, string message)
	{
		var exception = new McpProtocolException(message, (McpErrorCode)CallbackEndpointError);
		exception.Data["reason"] = reason;
		return exception;
	}
}
