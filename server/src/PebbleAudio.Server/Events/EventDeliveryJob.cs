using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Jobs;

namespace PebbleAudio.Server.Events;

/// <summary>
/// Delivers one event to one subscription. A 2xx is delivered. 410 means the receiver will not take this event (it is
/// stale, or it already has it: our timeout can fire after it accepted one), and 413 that it is too large; neither is
/// retried, and the subscription stays (MCP Events: 410 ends the delivery, never the subscription). Anything else
/// (an error status, a timeout, no connection) fails the attempt, and the queue retries it with exponential backoff
/// (30 s, doubling) up to the "Attempts for background work" setting, with a fresh timestamp and signature each time.
/// </summary>
public sealed class EventDeliveryJob(
	ArchiveDbContext db,
	WebhookClient webhooks,
	EventSecrets secrets,
	TimeProvider time,
	ILogger<EventDeliveryJob> logger)
	: IJobHandler
{
	public const string Type = "events.deliver";

	private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

	public async Task RunAsync(JobContext job, CancellationToken cancellationToken)
	{
		var delivery = job.GetPayload<EventDelivery>();
		var subscription = await db.EventSubscriptions.SingleOrDefaultAsync(s => s.Id == delivery.SubscriptionId, cancellationToken);
		var now = time.GetUtcNow();
		if (subscription is null || subscription.ExpiresAt <= now)
		{
			// Unsubscribed, disconnected, or not renewed since the event was queued.
			return;
		}

		if (subscription.ApiTokenId is { } tokenId &&
			await db.ApiTokens.AnyAsync(t => t.Id == tokenId && t.RevokedAt != null, cancellationToken))
		{
			db.EventSubscriptions.Remove(subscription);
			await db.SaveChangesAsync(cancellationToken);
			return;
		}

		var keys = secrets.KeysFor(subscription, now);
		if (keys.Count == 0)
		{
			await RecordErrorAsync(subscription, "The signing secret can no longer be read; waiting for the assistant to renew.", now, cancellationToken);
			return;
		}

		var body = delivery.Body();
		if (body.Length > WebhookClient.MaxBodyBytes)
		{
			await RecordErrorAsync(subscription, "An event was larger than 256 KiB and was not sent.", now, cancellationToken);
			logger.LogError("Event {EventId} is {Bytes} bytes, over the delivery limit; not sent.", delivery.EventId, body.Length);
			return;
		}

		var answer = await webhooks.PostAsync(
			subscription.CallbackUrl,
			delivery.EventId,
			subscription.Id,
			body,
			keys,
			Timeout,
			cancellationToken);

		switch (answer.StatusCode)
		{
			case >= 200 and < 300:
				subscription.LastDeliveredAt = time.GetUtcNow();
				subscription.LastError = null;
				subscription.LastErrorAt = null;
				await db.SaveChangesAsync(cancellationToken);
				return;
			case StatusCodes.Status410Gone:
				await RecordErrorAsync(subscription, "The assistant declined an event as already handled or out of date.", now, cancellationToken);
				logger.LogInformation(
					"The callback for subscription {SubscriptionId} declined event {EventId} with 410 Gone; it is not sent again.",
					subscription.Id,
					delivery.EventId);
				return;
			case StatusCodes.Status413PayloadTooLarge:
				await RecordErrorAsync(subscription, "The callback refused an event as too large.", now, cancellationToken);
				return;
			default:
				await RecordErrorAsync(subscription, answer.Describe(), now, cancellationToken);
				throw new WebhookDeliveryException(
					$"Event {delivery.EventId} to subscription {subscription.Id} was not delivered: {answer.Describe()}");
		}
	}

	private async Task RecordErrorAsync(EventSubscription subscription, string error, DateTimeOffset now, CancellationToken cancellationToken)
	{
		subscription.LastError = error;
		subscription.LastErrorAt = now;
		await db.SaveChangesAsync(cancellationToken);
	}
}

/// <summary>A delivery attempt failed in a way worth retrying.</summary>
public sealed class WebhookDeliveryException(string message) : Exception(message);
