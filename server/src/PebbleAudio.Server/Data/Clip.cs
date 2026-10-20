namespace PebbleAudio.Server.Data;

/// <summary>
/// A stretch of a conversation's audio, requested from the phone and served from disk once transcoded.
/// </summary>
public sealed class Clip
{
	public Guid Id { get; set; }

	public Guid UserId { get; set; }

	/// <summary>The phone request that asked for it.</summary>
	public Guid RequestId { get; set; }

	public string ConversationId { get; set; } = "";

	/// <summary>The span that was asked for.</summary>
	public DateTimeOffset StartAt { get; set; }

	public DateTimeOffset EndAt { get; set; }

	/// <summary>The span the upload actually covers, which may be shorter when audio was lost.</summary>
	public DateTimeOffset? CoveredStartAt { get; set; }

	public DateTimeOffset? CoveredEndAt { get; set; }

	/// <summary>Lost spans inside the uploaded audio.</summary>
	public List<ClipGap> Gaps { get; set; } = [];

	/// <summary>The audio file, relative to <c>PebbleAudio:ClipsPath</c>.</summary>
	public string? Path { get; set; }

	public long? ByteCount { get; set; }

	public long? DurationMs { get; set; }

	public ClipStatus Status { get; set; }

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset? UploadedAt { get; set; }

	public DateTimeOffset? ReadyAt { get; set; }

	public string? Error { get; set; }
}
