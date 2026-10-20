using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.DataProtection;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Events;

/// <summary>
/// How a callback answered one signed POST.
/// </summary>
/// <param name="StatusCode">The HTTP status, or null when there was no answer.</param>
/// <param name="Body">The start of the answer's body.</param>
/// <param name="TimedOut">True when the callback did not answer in time.</param>
/// <param name="Error">Why there was no answer, in a few words.</param>
public sealed record WebhookAnswer(int? StatusCode, string? Body, bool TimedOut, string? Error)
{
	public bool IsSuccess => StatusCode is >= 200 and < 300;

	/// <summary>One line for the admin area.</summary>
	public string Describe() =>
		TimedOut ? "The callback did not answer in time."
		: StatusCode is { } status ? $"The callback answered {status}."
		: $"The callback could not be reached ({Error}).";
}

/// <summary>
/// Sends signed MCP Events POSTs (Standard Webhooks headers plus <c>X-MCP-Subscription-Id</c>) through
/// <see cref="PublicHttp"/>: https only, public addresses only, no redirects.
/// </summary>
public sealed class WebhookClient(IHttpClientFactory httpClients, TimeProvider time)
{
	public const string HttpClientName = "webhooks";

	public const string SubscriptionHeader = "X-MCP-Subscription-Id";

	/// <summary>The most one delivery may carry (262,144 bytes).</summary>
	public const int MaxBodyBytes = 256 * 1024;

	private const int MaxAnswerBytes = 16 * 1024;

	public async Task<WebhookAnswer> PostAsync(
		string url,
		string messageId,
		string subscriptionId,
		byte[] body,
		IReadOnlyList<byte[]> keys,
		TimeSpan timeout,
		CancellationToken cancellationToken)
	{
		// A fresh timestamp and signature on every attempt; the message id stays the same across retries.
		var timestamp = time.GetUtcNow().ToUnixTimeSeconds();
		using var request = new HttpRequestMessage(HttpMethod.Post, url)
		{
			Content = new ByteArrayContent(body) { Headers = { ContentType = new MediaTypeHeaderValue("application/json") } },
		};
		request.Headers.UserAgent.Add(PublicHttp.UserAgent);
		request.Headers.TryAddWithoutValidation(StandardWebhooks.IdHeader, messageId);
		request.Headers.TryAddWithoutValidation(StandardWebhooks.TimestampHeader, timestamp.ToString(CultureInfo.InvariantCulture));
		request.Headers.TryAddWithoutValidation(StandardWebhooks.SignatureHeader, StandardWebhooks.SignatureHeaderValue(keys, messageId, timestamp, body));
		request.Headers.TryAddWithoutValidation(SubscriptionHeader, subscriptionId);

		using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
		limit.CancelAfter(timeout);
		try
		{
			using var response = await httpClients.CreateClient(HttpClientName)
				.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, limit.Token);
			var answer = await ReadStartAsync(response.Content, limit.Token);
			return new WebhookAnswer((int)response.StatusCode, answer, TimedOut: false, Error: null);
		}
		catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
		{
			return new WebhookAnswer(null, null, TimedOut: true, Error: "timeout");
		}
		catch (Exception ex) when (ex is HttpRequestException or IOException)
		{
			return new WebhookAnswer(null, null, TimedOut: false, Error: ex.Message);
		}
	}

	/// <summary>True for an absolute https URL with a host and no user info or fragment.</summary>
	public static bool IsCallbackUrl(string? url) =>
		Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
		uri.Scheme == Uri.UriSchemeHttps &&
		uri.Host.Length > 0 &&
		string.IsNullOrEmpty(uri.UserInfo) &&
		uri.Fragment.Length == 0;

	private static async Task<string?> ReadStartAsync(HttpContent content, CancellationToken cancellationToken)
	{
		await using var stream = await content.ReadAsStreamAsync(cancellationToken);
		var buffer = new byte[MaxAnswerBytes];
		var read = 0;
		while (read < buffer.Length)
		{
			var count = await stream.ReadAsync(buffer.AsMemory(read), cancellationToken);
			if (count == 0)
			{
				break;
			}

			read += count;
		}

		return read == 0 ? null : Encoding.UTF8.GetString(buffer, 0, read);
	}
}

/// <summary>
/// Webhook signing secrets at rest: protected with ASP.NET Core Data Protection, unprotected only to sign.
/// </summary>
public sealed class EventSecrets(IDataProtectionProvider provider)
{
	/// <summary>How long deliveries are signed with both secrets after a renewal changes it.</summary>
	public static readonly TimeSpan RotationOverlap = TimeSpan.FromHours(1);

	private readonly IDataProtector _protector = provider.CreateProtector("PebbleAudio.Events.WebhookSecret");

	public string Protect(string secret) => _protector.Protect(secret);

	/// <summary>
	/// The secret, or null when it can no longer be read (the Data Protection keys it was protected with are gone).
	/// The assistant's next renewal brings a new one.
	/// </summary>
	public string? Unprotect(string protectedSecret)
	{
		try
		{
			return _protector.Unprotect(protectedSecret);
		}
		catch (System.Security.Cryptography.CryptographicException)
		{
			return null;
		}
	}

	/// <summary>
	/// The keys to sign with now: the current secret, and the previous one during the overlap. Empty when the
	/// current secret can no longer be read.
	/// </summary>
	public IReadOnlyList<byte[]> KeysFor(EventSubscription subscription, DateTimeOffset now)
	{
		List<byte[]> keys = [];
		if (StandardWebhooks.ParseSecret(Unprotect(subscription.ProtectedSecret)) is not { } key)
		{
			return keys;
		}

		keys.Add(key);
		if (subscription.ProtectedPreviousSecret is { } previous && subscription.PreviousSecretUntil > now &&
			StandardWebhooks.ParseSecret(Unprotect(previous)) is { } previousKey)
		{
			keys.Add(previousKey);
		}

		return keys;
	}
}

/// <summary>
/// One queued delivery: the event, for one subscription.
/// </summary>
public sealed record EventDelivery(string SubscriptionId, string EventId, string Name, DateTimeOffset Timestamp, JsonElement Data)
{
	/// <summary>
	/// The body: <c>{eventId, name, timestamp, data, cursor}</c>, compact JSON. Serialized once per attempt and sent
	/// as exactly the bytes that were signed.
	/// </summary>
	public byte[] Body() => Encoding.UTF8.GetBytes(new JsonObject
	{
		["eventId"] = EventId,
		["name"] = Name,
		["timestamp"] = Timestamp.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
		["data"] = JsonNode.Parse(Data.GetRawText()),
		["cursor"] = null,
	}.ToJsonString());
}
