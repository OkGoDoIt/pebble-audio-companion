namespace PebbleAudio.Server.Data;

/// <summary>
/// An assistant's MCP Events subscription: deliver one event type to a webhook. The id is derived from the user, the
/// callback URL, the event name, and the arguments, so subscribing again updates the same row.
/// </summary>
public sealed class EventSubscription
{
	/// <summary><c>sub_</c> and 32 hex characters.</summary>
	public string Id { get; set; } = "";

	public Guid UserId { get; set; }

	/// <summary>For example <c>day_recap.ready</c>.</summary>
	public string EventName { get; set; } = "";

	/// <summary>The subscription arguments as canonical JSON (sorted keys, no whitespace).</summary>
	public string ArgumentsJson { get; set; } = "{}";

	public string CallbackUrl { get; set; } = "";

	/// <summary>The <c>whsec_</c> signing secret, protected with ASP.NET Core Data Protection.</summary>
	public string ProtectedSecret { get; set; } = "";

	/// <summary>The secret a renewal replaced; deliveries are signed with both until <see cref="PreviousSecretUntil"/>.</summary>
	public string? ProtectedPreviousSecret { get; set; }

	public DateTimeOffset? PreviousSecretUntil { get; set; }

	/// <summary>The app's name when it subscribed, for the admin area.</summary>
	public string ClientName { get; set; } = "";

	/// <summary>The OAuth connection it came through; disconnecting the app deletes the subscription.</summary>
	public Guid? GrantId { get; set; }

	/// <summary>The access token it came through; revoking the token stops deliveries.</summary>
	public Guid? ApiTokenId { get; set; }

	public DateTimeOffset CreatedAt { get; set; }

	/// <summary>When the assistant last subscribed or renewed.</summary>
	public DateTimeOffset RenewedAt { get; set; }

	/// <summary>When the callback last answered the signed challenge.</summary>
	public DateTimeOffset VerifiedAt { get; set; }

	/// <summary>The <c>refreshBefore</c> the assistant was given; null when it asked for no expiry.</summary>
	public DateTimeOffset? ExpiresAt { get; set; }

	public DateTimeOffset? LastDeliveredAt { get; set; }

	public string? LastError { get; set; }

	public DateTimeOffset? LastErrorAt { get; set; }
}
