using System.Text.Json;

namespace PebbleAudio.Server.Data;

/// <summary>
/// Work the server asks the phone to do: send a clip, or create or update a follow-up or note
/// (sync-protocol.md §4). Stored in the <c>Requests</c> table.
/// </summary>
public sealed class PhoneRequest
{
	public Guid Id { get; set; }

	public Guid UserId { get; set; }

	public PhoneRequestKind Kind { get; set; }

	/// <summary>The request's payload as sync-protocol.md §4 gives it for its kind.</summary>
	public JsonDocument Payload { get; set; } = null!;

	public PhoneRequestState State { get; set; }

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset ExpiresAt { get; set; }

	/// <summary>When the phone first pulled it.</summary>
	public DateTimeOffset? DeliveredAt { get; set; }

	public DateTimeOffset? CompletedAt { get; set; }

	/// <summary>The phone's <c>detail</c> from its result, if any.</summary>
	public string? Detail { get; set; }
}
