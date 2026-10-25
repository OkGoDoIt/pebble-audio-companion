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
	private List<VoiceEvidence>? _voiceEvidence = [];
	// Older JSON rows have no such collection; EF materializes the absent field as null.
	public List<VoiceEvidence> VoiceEvidence { get => _voiceEvidence ??= []; set => _voiceEvidence = value; }
}

/// <summary>
/// One quiet or interrupted row of a conversation, as the phone's Conversation screen shows it (sync-protocol.md
/// §2.1). Quiet and lost stay distinct. A row from a phone before the gap change has no <see cref="Label"/>: it is a
/// single gap record, and <see cref="Mcp.GapRows"/> reads it the app's way.
/// </summary>
public sealed class ConversationGap
{
	/// <summary>Where the stretch the row covers starts. For an interruption this is not how much is missing: brief
	/// drops a few seconds apart are one row over the whole stretch (<see cref="MissingMs"/> is the loss).</summary>
	public DateTimeOffset StartedAt { get; set; }

	public DateTimeOffset EndedAt { get; set; }

	public GapKind Kind { get; set; }

	/// <summary>Where a loss happened: <c>watch</c>, <c>link</c> (it never reached the phone), or <c>unknown</c>.</summary>
	public string? Origin { get; set; }

	/// <summary>Why a quiet stretch has no audio, when the phone says: <c>watchPause</c> for the watch's own
	/// power-save pause.</summary>
	public string? Reason { get; set; }

	/// <summary>On a lost row: the audio genuinely missing inside it, in milliseconds.</summary>
	public long? MissingMs { get; set; }

	/// <summary>The row's own words without its cause, in the app's wording: <c>audio interrupted for 1 min over 14
	/// min</c>, <c>quiet for 3 min</c>.</summary>
	public string? Label { get; set; }

	/// <summary>On a lost row: the cause it names, in the app's words (<c>watch buffer filled while
	/// disconnected</c>), or <c>2 reasons</c> when <see cref="Causes"/> has the breakdown.</summary>
	public string? Cause { get; set; }

	/// <summary>On a lost row with more than one cause: each, largest first.</summary>
	public List<GapCause> Causes { get; set; } = [];

	/// <summary>False for an interruption too brief for a transcript row (under 10 seconds): it still counts and still
	/// marks the strip. Null (a phone before the gap change) is decided by <see cref="Mcp.GapRows"/>.</summary>
	public bool? Shown { get; set; }
}

/// <summary>One cause of a mixed interruption row.</summary>
public sealed class GapCause
{
	/// <summary>A stable code: <c>spoolOverflow</c>, <c>transportReset</c>, <c>phoneMissed</c>, <c>powerSave</c>, …</summary>
	public string Code { get; set; } = "";

	/// <summary>The app's words for it.</summary>
	public string Text { get; set; } = "";

	public long Ms { get; set; }

	public int Count { get; set; }
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

	public string? PersonId { get; set; }
	public string? SegmentId { get; set; }
	public long? StartMediaMs { get; set; }
	public long? EndMediaMs { get; set; }
	/// <summary>True includes an explicit unnamed decision; readers must not restore a broad label name.</summary>
	public bool? IdentityResolved { get; set; }
	private List<VoiceEvidence>? _voiceEvidence = [];
	public List<VoiceEvidence> VoiceEvidence { get => _voiceEvidence ??= []; set => _voiceEvidence = value; }

	public string? Text { get; set; }

	public double? Confidence { get; set; }

	/// <summary>Where a loss happened (lost items).</summary>
	public string? Origin { get; set; }

	/// <summary>What was masked, for example <c>music</c> (masked items).</summary>
	public string? Descriptor { get; set; }

	/// <summary>Quiet and lost items: the row's words and cause, as on <see cref="ConversationGap"/>.</summary>
	public string? Label { get; set; }

	public string? Cause { get; set; }

	/// <summary>Lost items: the audio genuinely missing inside the row, in milliseconds.</summary>
	public long? MissingMs { get; set; }

	/// <summary>Quiet items: <c>watchPause</c> for the watch's own power-save pause.</summary>
	public string? Reason { get; set; }
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
/// A stretch inside an uploaded clip with no audio (the <c>X-Clip-Gaps</c> header): lost, or with
/// <see cref="Kind"/> <c>quiet</c> the silence the watch skipped or its power-save pause.
/// </summary>
public sealed class ClipGap
{
	public DateTimeOffset StartedAt { get; set; }

	public DateTimeOffset EndedAt { get; set; }

	/// <summary>Null for lost audio; <c>quiet</c> for audio the watch did not send on purpose.</summary>
	public string? Kind { get; set; }

	public bool IsLost => Kind is null or "lost";
}
