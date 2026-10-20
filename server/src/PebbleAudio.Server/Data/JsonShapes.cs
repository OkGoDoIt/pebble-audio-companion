namespace PebbleAudio.Server.Data;

// The structured values stored as jsonb columns (EF Core complex collections mapped with ToJson).
// Their shapes follow sync-protocol.md; instants are UTC, media offsets integer milliseconds.

/// <summary>
/// One cut of a recording segment that belongs to a conversation (sync-protocol.md §2.1).
/// </summary>
public sealed class ConversationPiece
{
	public int Ordinal { get; set; }

	public string SegmentId { get; set; } = "";

	public long StartMediaMs { get; set; }

	/// <summary>Null when the piece runs to the end of its segment.</summary>
	public long? EndMediaMs { get; set; }

	public DateTimeOffset StartedAt { get; set; }

	public DateTimeOffset? EndedAt { get; set; }
}

/// <summary>
/// A speaker label in a conversation and the person it was matched to, if any.
/// </summary>
public sealed class ConversationSpeaker
{
	public string Label { get; set; } = "";

	public string? PersonId { get; set; }

	public string? Name { get; set; }
}

/// <summary>
/// A stretch inside a conversation with no stored audio. Quiet and lost stay distinct.
/// </summary>
public sealed class ConversationGap
{
	public DateTimeOffset StartedAt { get; set; }

	public DateTimeOffset EndedAt { get; set; }

	public GapKind Kind { get; set; }

	/// <summary>Where a loss happened: <c>watch</c>, <c>link</c> (it never reached the phone), or <c>unknown</c>.</summary>
	public string? Origin { get; set; }

	/// <summary>Why a quiet stretch has no audio, when the phone says: <c>watchPause</c> for the watch's own
	/// power-save pause.</summary>
	public string? Reason { get; set; }
}

/// <summary>
/// One item of a transcript, in time order: a spoken turn or an honest marker (sync-protocol.md §2.2).
/// </summary>
public sealed class TranscriptItem
{
	public TranscriptItemKind Kind { get; set; }

	public DateTimeOffset At { get; set; }

	public DateTimeOffset? EndAt { get; set; }

	public string? Speaker { get; set; }

	public string? Name { get; set; }

	public string? Text { get; set; }

	public double? Confidence { get; set; }

	/// <summary>Where a loss happened (lost items).</summary>
	public string? Origin { get; set; }

	/// <summary>What was masked, for example <c>music</c> (masked items).</summary>
	public string? Descriptor { get; set; }
}

/// <summary>
/// One stretch of a day's coverage (sync-protocol.md §2.7).
/// </summary>
public sealed class CoverageSpan
{
	public DateTimeOffset StartedAt { get; set; }

	public DateTimeOffset EndedAt { get; set; }

	public CoverageKind Kind { get; set; }
}

/// <summary>
/// A span of a conversation a note cites (sync-protocol.md §2.6).
/// </summary>
public sealed class NoteCitation
{
	public string ConversationId { get; set; } = "";

	public DateTimeOffset At { get; set; }

	public DateTimeOffset? EndAt { get; set; }
}

/// <summary>
/// A lost span inside an uploaded clip (the <c>X-Clip-Gaps</c> header).
/// </summary>
public sealed class ClipGap
{
	public DateTimeOffset StartedAt { get; set; }

	public DateTimeOffset EndedAt { get; set; }
}
