using System.Text.Json;

namespace PebbleAudio.Server.Data;

/// <summary>
/// A row of the background task queue (see <c>Jobs/</c>).
/// </summary>
public sealed class Job
{
	public long Id { get; set; }

	/// <summary>The user the work is for, when it is for one.</summary>
	public Guid? UserId { get; set; }

	/// <summary>The registered handler's name, for example <c>noop</c>.</summary>
	public string Type { get; set; } = "";

	public JsonDocument? Payload { get; set; }

	public JobState State { get; set; }

	/// <summary>How many times a worker has started it.</summary>
	public int Attempts { get; set; }

	/// <summary>The earliest time a worker may start it.</summary>
	public DateTimeOffset RunAfter { get; set; }

	public string? LockedBy { get; set; }

	public DateTimeOffset? LockedAt { get; set; }

	/// <summary>The last failure.</summary>
	public string? Error { get; set; }

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset? CompletedAt { get; set; }
}
