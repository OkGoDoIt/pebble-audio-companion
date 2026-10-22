using PebbleAudio.Server.Data;
using PebbleAudio.Server.Mcp;

namespace PebbleAudio.Server.Pages.View;

// What the viewer pages render. Every time is already in the conversation's (or the day's) zone, and every
// sentence is already worded (ViewText), so the Razor files only lay things out.

/// <summary>A day in a list: the home page and a brief's days.</summary>
public sealed record DayRow(
	DateOnly Day,
	string Url,
	string WeekdayShort,
	string Numeral,
	string Month,
	string? Headline,
	string? Line,
	string Meta,
	string? MissingText);

public sealed record HomeView(IReadOnlyList<DayRow> Days, string? ScopeLine);

/// <summary>One speaker lane of a conversation's strip: who spoke when.</summary>
/// <param name="Css">The lane's color: <c>s0</c>, <c>s1</c>, <c>s2</c> for named voices (tint, teal, rose), <c>s3</c> (gray) for an
/// unnamed voice and for the lane of other voices.</param>
public sealed record LaneView(int Index, string Name, string Css);

/// <summary>
/// A mark on the conversation's strip: <c>quiet</c>, <c>paused</c> (the watch saving power), <c>lost</c>, or <c>masked</c>.
/// Quiet, paused, and masked cover their stretch, and so does a lost mark for a hole. A lost row of brief drops spread
/// over a stretch is a one-second mark where it starts — the app's amber tick on its scrubber — so it is not painted as
/// fourteen minutes of missing audio over words that are all there.
/// </summary>
public sealed record MarkView(string Kind, int S, int E, string Label);

public enum RowKind
{
	Turn,
	Run,
	Quiet,
	Paused,
	Lost,
	Masked,
}

/// <summary>One spoken turn, or one bit of a run of short ones.</summary>
/// <param name="Unnamed">A voice nobody has named: the app draws its name gray after a small dot in its captured color.</param>
public sealed record BitView(int Lane, string Who, string Text, int S, int E, bool LowConfidence, bool Unnamed = false);

/// <summary>A transcript row: a turn, a run of short turns, or a stretch set where it happened.</summary>
/// <param name="Stamp">The margin's clock, <c>10:18</c>; shown only on the first row of a minute.</param>
/// <param name="StampLabel">What the stamp button says to a screen reader: <c>Play from 10:18:42 AM</c>.</param>
public sealed record RowView(
	RowKind Kind,
	int S,
	int E,
	string Stamp,
	bool NewMinute,
	string StampLabel,
	IReadOnlyList<BitView> Bits,
	string? Text,
	string? Detail);

public sealed record NeighborView(string Title, string Url, string Time);

/// <summary>
/// Where the clip around the moment stands, in the get_audio vocabulary: <c>ready</c>, <c>requested</c>,
/// <c>notAllowed</c>, <c>unavailable</c> (with <c>reason</c>), or <c>none</c> (nothing asked yet). Times are seconds
/// from the conversation's start.
/// </summary>
public sealed record ClipState(
	string Status,
	string? Reason,
	Guid? RequestId,
	string? AudioUrl,
	DateTimeOffset? ExpiresAt,
	int From,
	int To,
	int? CoveredFrom,
	int? CoveredTo,
	IReadOnlyList<int[]> Lost,
	long? DurationMs,
	DateTimeOffset? WaitingUntil)
{
	/// <summary>What the clip skipped on purpose (the watch's silence, its power-save pause), for the player's clock.</summary>
	public IReadOnlyList<int[]> Quiet { get; init; } = [];
}

public sealed record ConversationView(
	Conversation Row,
	string Title,
	bool HasTitle,
	string? Summary,
	IReadOnlyList<string> Tags,
	DateOnly Day,
	string DayName,
	string DayUrl,
	string ZoneId,
	DateTimeOffset Start,
	DateTimeOffset End,
	int DurationSec,
	string DateText,
	string RangeText,
	string DurationText,
	string? MissingText,
	string? PeopleLine,
	IReadOnlyList<LaneView> Lanes,
	IReadOnlyList<(int Lane, int S, int E)> Turns,
	IReadOnlyList<MarkView> Marks,
	IReadOnlyList<MarkView> Holes,
	IReadOnlyList<RowView> Rows,
	int? CitedIndex,
	int? T,
	bool HasTranscript,
	bool Live,
	IReadOnlyList<FollowUpOut> FollowUps,
	IReadOnlyList<NoteOut> Notes,
	NeighborView? Previous,
	NeighborView? Next,
	ClipState Clip);

/// <summary>A conversation on its day: text first, then the time.</summary>
public sealed record CardView(
	string Id,
	string Url,
	string Title,
	bool HasTitle,
	string? Summary,
	string Start,
	string TimeText,
	string? MissingText,
	IReadOnlyList<string> Tags,
	IReadOnlyList<string> People,
	bool Compact,
	IReadOnlyList<(string Text, bool Done)> Reminders);

/// <summary>A calm line between two conversations: what the time between them was.</summary>
/// <param name="Bar">The shape on the axis: <c>paused</c>, <c>missing</c>, <c>off</c>, <c>background</c>, or <c>quiet</c> (the bare axis).</param>
public sealed record StretchView(string Bar, string Name, string? Rest, string? Detail, string? MissingText, int Minutes);

/// <summary>One item of the day's column: a card or a stretch.</summary>
public sealed record TimelineItem(CardView? Card, StretchView? Stretch);

/// <summary>A piece of the day strip, placed in percent of the axis.</summary>
public sealed record StripPiece(string Kind, double Left, double Width, string Title, string? Url);

public sealed record StripTick(double Left, string Label);

public sealed record DayStripView(IReadOnlyList<StripPiece> Spans, IReadOnlyList<StripPiece> Blocks, IReadOnlyList<StripTick> Ticks, string Label);

/// <summary>A total under the day strip: <c>Quiet 2 hr 30 min</c>.</summary>
public sealed record TotalView(string Kind, string Name, string Value);

public enum DayState
{
	Found,
	Nothing,
	OutsideScope,
}

public sealed record DayView(
	DateOnly Day,
	DayState State,
	string Weekday,
	string DateText,
	string Place,
	string? Headline,
	string? Line,
	string? RecapText,
	DayStripView? Strip,
	IReadOnlyList<TotalView> Totals,
	IReadOnlyList<TimelineItem> Items,
	int ReminderTotal,
	int ReminderOpen,
	DateOnly? Previous,
	DateOnly? Next,
	string WeekUrl,
	string? ScopeLine);

public sealed record BriefView(
	BriefKind Kind,
	DateOnly Start,
	DateOnly End,
	string Title,
	string RangeText,
	bool InScope,
	bool Found,
	string? Headline,
	string? Line,
	string? Text,
	IReadOnlyList<DayRow> Days,
	string PreviousUrl,
	string NextUrl,
	string? ScopeLine);
