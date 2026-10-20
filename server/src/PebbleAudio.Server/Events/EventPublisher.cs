using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Jobs;

namespace PebbleAudio.Server.Events;

/// <summary>
/// What other modules call when something happens that assistants may have subscribed to. Each call queues one
/// delivery per live subscription on the job queue; nothing is sent inline. Like <see cref="IJobQueue"/>, it saves
/// the database context, so it commits together with the caller's pending changes.
/// </summary>
public interface IEventPublisher
{
	/// <summary>
	/// A day's recap arrived from the phone, or changed. The event id comes from the day and the recap's version,
	/// so the same version announced twice is one event to a receiver that dedupes.
	/// </summary>
	Task DayRecapReadyAsync(Recap recap, CancellationToken cancellationToken);

	/// <summary>
	/// A follow-up was created. One an assistant created (origin <c>assistant</c>) is not announced, so an
	/// assistant's own write never wakes an assistant.
	/// </summary>
	Task FollowUpCreatedAsync(FollowUp followUp, CancellationToken cancellationToken);
}

public sealed class EventPublisher(
	ArchiveDbContext db,
	IJobQueue jobs,
	OAuthUrls urls,
	TimeProvider time,
	ILogger<EventPublisher> logger)
	: IEventPublisher
{
	private const int SummaryLength = 1000;
	private const int TextLength = 2000;

	internal static readonly JsonSerializerOptions DataJson = new(JsonSerializerDefaults.Web)
	{
		DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
	};

	public Task DayRecapReadyAsync(Recap recap, CancellationToken cancellationToken)
	{
		var day = recap.DayKey.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
		var data = new DayRecapReadyData(
			day,
			NullIfBlank(recap.TimeZone),
			NullIfBlank(recap.Headline),
			Cap(NullIfBlank(recap.LineSummary) ?? NullIfBlank(recap.ShortText), SummaryLength),
			recap.ConversationIds.Count,
			$"{urls.Issuer}/d/{day}");
		return PublishAsync(recap.UserId, EventCatalog.DayRecapReady, $"{day}:{recap.Version}", data, cancellationToken);
	}

	public Task FollowUpCreatedAsync(FollowUp followUp, CancellationToken cancellationToken)
	{
		if (followUp.Origin == ContentOrigin.Assistant)
		{
			return Task.CompletedTask;
		}

		var data = new FollowUpCreatedData(
			followUp.Id,
			Cap(followUp.Text, TextLength)!,
			Cap(NullIfBlank(followUp.Why), TextLength),
			followUp.DueAt,
			followUp.SourceConversationId,
			followUp.SourceConversationId is { } conversationId ? $"{urls.Issuer}/c/{Uri.EscapeDataString(conversationId)}" : null);
		return PublishAsync(followUp.UserId, EventCatalog.FollowUpCreated, followUp.Id, data, cancellationToken);
	}

	private async Task PublishAsync(Guid userId, string name, string occurrence, object data, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		var subscriptions = await db.EventSubscriptions.AsNoTracking()
			.Where(s => s.UserId == userId && s.EventName == name && (s.ExpiresAt == null || s.ExpiresAt > now))
			.Select(s => s.Id)
			.ToListAsync(cancellationToken);
		if (subscriptions.Count == 0)
		{
			return;
		}

		var eventId = EventId(name, occurrence);
		var payload = JsonSerializer.SerializeToElement(data, data.GetType(), DataJson);
		foreach (var subscriptionId in subscriptions)
		{
			await jobs.EnqueueAsync(
				EventDeliveryJob.Type,
				new EventDelivery(subscriptionId, eventId, name, now, payload),
				userId: userId,
				cancellationToken: cancellationToken);
		}

		logger.LogInformation("Queued {Event} {EventId} for {Count} subscription(s).", name, eventId, subscriptions.Count);
	}

	/// <summary>
	/// <c>evt_</c> and 32 hex characters, derived from what happened, so a retry or a repeat has the same id
	/// (receivers dedupe on it) and the id never contains the dot that Standard Webhooks signing separates on.
	/// </summary>
	public static string EventId(string name, string occurrence) =>
		"evt_" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes($"{name}\n{occurrence}")))[..32];

	private static string? NullIfBlank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

	private static string? Cap(string? value, int length) => value is { } v && v.Length > length ? v[..(length - 1)] + "…" : value;
}
