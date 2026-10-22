using System.Text.Json.Serialization;

namespace PebbleAudio.Server.Mcp;

// The structured content of every tool, field for field as docs/tool-results.md gives it. Declaration order is
// the JSON order, so Summary always comes first. A null field is left out of the JSON.

// Shared objects

public sealed record SpeakerOut(string Label, string? Name, string? PersonId);

public sealed record ConversationCard(
	string Id,
	string? Title,
	string Url,
	DateOnly Day,
	DateTimeOffset StartedAt,
	DateTimeOffset? EndedAt,
	string TimeZone,
	double Minutes,
	double RecordedMinutes,
	string? Overview,
	IReadOnlyList<string> Tags,
	IReadOnlyList<SpeakerOut> People,
	string Kind,
	string? Descriptor,
	string State,
	bool Provisional,
	bool HasTranscript,
	bool ExpiredOnPhone,
	double QuietMinutes,
	double LostMinutes);

/// <summary>One quiet or interrupted row, as the phone's transcript shows it.</summary>
/// <param name="Minutes">The stretch the row covers.</param>
/// <param name="MissingMinutes">On a lost row: the audio genuinely missing inside it, which brief drops spread over a
/// long stretch can make far less than <paramref name="Minutes"/>.</param>
/// <param name="Label">The row in the app's words: <c>audio interrupted for 1 min over 14 min (watch buffer filled while
/// disconnected)</c>, <c>quiet for 3 min</c>.</param>
public sealed record GapOut(
	string Kind,
	DateTimeOffset StartedAt,
	DateTimeOffset EndedAt,
	int T,
	double Minutes,
	double? MissingMinutes,
	string? Origin,
	string? Reason,
	string Label);

public sealed record TranscriptItemOut(
	string Kind,
	int T,
	DateTimeOffset At,
	DateTimeOffset? EndAt,
	double? Minutes,
	string? Speaker,
	string? Name,
	string? Text,
	double? Confidence,
	string? Origin,
	string? Descriptor)
{
	/// <summary>Quiet and lost items: the row in the app's words, as on <see cref="GapOut.Label"/>.</summary>
	public string? Label { get; init; }

	/// <summary>Lost items: the audio genuinely missing inside the row.</summary>
	public double? MissingMinutes { get; init; }
}

public sealed record FollowUpSourceOut(string ConversationId, string? Title, DateTimeOffset? At, int? T, string Url, bool Approximate);

public sealed record FollowUpOut(
	string Id,
	string Text,
	string Url,
	string? Quote,
	string? Why,
	DateTimeOffset? DueAt,
	string Priority,
	string Status,
	bool Done,
	DateTimeOffset? CompletedAt,
	DateTimeOffset? SnoozedUntil,
	DateTimeOffset? ArchivedAt,
	string Origin,
	DateTimeOffset CreatedAt,
	FollowUpSourceOut? Source,
	bool WaitingForPhone);

public sealed record CitationOut(string ConversationId, DateTimeOffset At, int T, string Url);

public sealed record NoteOut(
	string Id,
	string? ConversationId,
	string? Title,
	string Body,
	string Url,
	string Origin,
	DateTimeOffset CreatedAt,
	DateTimeOffset? EditedAt,
	IReadOnlyList<CitationOut> Citations,
	bool WaitingForPhone);

// get_status

public sealed record CountsOut(int Conversations, int Transcripts, int Recaps, int Briefs, int FollowUps, int Notes, int People, int CoverageDays);

public sealed record SharingOut(string Kind, DateTimeOffset? Since, int? Days, DateTimeOffset? From);

public sealed record AllowedOut(bool Clips, bool Edits);

public sealed record StatusResult(
	string Summary,
	string? Url,
	DateTimeOffset ServerTime,
	string TimeZone,
	DateOnly? FirstDay,
	DateOnly? LastDay,
	DateTimeOffset? LastSyncAt,
	CountsOut Counts,
	int PendingRequests,
	int LinkedPhones,
	string ServerVersion,
	SharingOut Sharing,
	AllowedOut Allowed,
	bool CanWrite) : IToolResult;

// list_days, get_day

public sealed record DayOut(
	DateOnly Day,
	string Weekday,
	string Url,
	string? Headline,
	string? LineSummary,
	int ConversationCount,
	double RecordedMinutes,
	double QuietMinutes,
	double LostMinutes,
	bool HasRecap);

public sealed record ListDaysResult(
	string Summary,
	DateOnly From,
	DateOnly To,
	string TimeZone,
	IReadOnlyList<DayOut> Days,
	bool Truncated,
	NextCall? Next) : IToolResult;

public sealed record RecapOut(string? Headline, string? LineSummary, string? Text);

public sealed record CoverageSpanOut(string Kind, DateTimeOffset StartedAt, DateTimeOffset EndedAt, double Minutes);

public sealed record CoverageOut(double RecordedMinutes, double QuietMinutes, double LostMinutes, IReadOnlyList<CoverageSpanOut> Spans, bool SpansOmitted = false);

public sealed record DayCandidate(DateOnly Day, string Weekday, string Url, string? Headline, int ConversationCount);

public sealed record GetDayResult(
	string Summary,
	bool Found,
	DateOnly? Day,
	string? Weekday,
	string? Url,
	string TimeZone,
	RecapOut? Recap,
	CoverageOut? Coverage,
	IReadOnlyList<ConversationCard> Conversations,
	IReadOnlyList<FollowUpOut> FollowUps,
	bool Truncated,
	NextCall? Next,
	IReadOnlyList<DayCandidate>? Candidates) : IToolResult;

// get_brief

public sealed record BriefCandidate(string Kind, string Key, DateOnly StartDay, DateOnly EndDay, string Url, string? Headline);

public sealed record GetBriefResult(
	string Summary,
	bool Found,
	string Kind,
	string? Key,
	DateOnly? StartDay,
	DateOnly? EndDay,
	string? Url,
	string? Headline,
	string? LineSummary,
	string? Text,
	IReadOnlyList<BriefCandidate>? Candidates) : IToolResult;

// list_conversations

public sealed record ConversationFilters(DateOnly? From, DateOnly? To, string? Tag, string? Person, string? PersonId, string? Query);

public sealed record FilterCandidate(string Kind, string Value, string? PersonId, int ConversationCount, DateOnly? LastDay, string? Example);

public sealed record ListConversationsResult(
	string Summary,
	ConversationFilters Filters,
	IReadOnlyList<ConversationCard> Conversations,
	bool Truncated,
	NextCall? Next,
	IReadOnlyList<FilterCandidate>? Candidates) : IToolResult;

// get_conversation

public sealed record TranscriptOut(
	DateTimeOffset From,
	DateTimeOffset To,
	int ItemCount,
	int ShownCount,
	string? Provider,
	string? Model,
	string? Language,
	IReadOnlyList<TranscriptItemOut> Items);

public sealed record ConversationCandidate(string Id, string? Title, string Url, DateOnly Day, DateTimeOffset StartedAt);

public sealed record GetConversationResult(
	string Summary,
	bool Found,
	string Id,
	string? Title,
	string? Url,
	DateOnly? Day,
	DateTimeOffset? StartedAt,
	DateTimeOffset? EndedAt,
	string? TimeZone,
	double? Minutes,
	double? RecordedMinutes,
	string? Overview,
	IReadOnlyList<string>? Tags,
	IReadOnlyList<SpeakerOut>? People,
	string? Kind,
	string? Descriptor,
	string? State,
	bool Provisional,
	bool HasTranscript,
	bool ExpiredOnPhone,
	double? QuietMinutes,
	double? LostMinutes,
	IReadOnlyList<GapOut>? Gaps,
	IReadOnlyList<FollowUpOut>? FollowUps,
	IReadOnlyList<NoteOut>? Notes,
	TranscriptOut? Transcript,
	bool Truncated,
	NextCall? Next,
	IReadOnlyList<ConversationCandidate>? Candidates) : IToolResult;

// search, fetch

public sealed record SearchHit(
	string Id,
	string Title,
	string Url,
	string Kind,
	DateOnly? Day,
	DateTimeOffset? At,
	string? Snippet);

public sealed record SearchResult(
	string Summary,
	string Query,
	IReadOnlyList<SearchHit> Results,
	bool Truncated) : IToolResult;

public sealed record FetchResult(
	string Summary,
	string Id,
	string Title,
	string Text,
	string Url,
	IReadOnlyDictionary<string, object> Metadata) : IToolResult;

// list_follow_ups

public sealed record ListFollowUpsResult(
	string Summary,
	string Status,
	IReadOnlyList<FollowUpOut> FollowUps,
	bool Truncated,
	NextCall? Next) : IToolResult;

// get_people, get_tags

public sealed record PersonOut(string Name, string? PersonId, int ConversationCount, DateOnly? LastDay);

public sealed record PeopleResult(string Summary, IReadOnlyList<PersonOut> People, bool Truncated) : IToolResult;

public sealed record TagOut(string Tag, int ConversationCount, DateOnly? LastDay);

public sealed record TagsResult(string Summary, IReadOnlyList<TagOut> Tags, bool Truncated) : IToolResult;

// get_audio

public sealed record LostSpanOut(DateTimeOffset StartedAt, DateTimeOffset EndedAt, double Minutes);

public sealed record AudioResult(
	string Summary,
	string Status,
	string? Reason,
	string ConversationId,
	string? Title,
	string? Url,
	DateTimeOffset? StartedAt,
	DateTimeOffset? EndedAt,
	string? AudioUrl,
	DateTimeOffset? AudioExpiresAt,
	DateTimeOffset? CoveredFrom,
	DateTimeOffset? CoveredTo,
	double? Minutes,
	IReadOnlyList<LostSpanOut> Lost,
	Guid? RequestId,
	DateTimeOffset? WaitingUntil) : IToolResult
{
	/// <summary>Stretches inside the clip with no audio on purpose (the watch's skipped silence, its power-save pause):
	/// not lost, and not in the file, so a player can place the audio on the conversation's clock.</summary>
	public IReadOnlyList<LostSpanOut> Quiet { get; init; } = [];
}

// The write tools

public sealed record FollowUpWriteResult(string Summary, string Status, FollowUpOut? FollowUp, Guid? RequestId) : IToolResult;

public sealed record NoteWriteResult(string Summary, string Status, NoteOut? Note, Guid? RequestId) : IToolResult;

/// <summary>A span of a conversation a new note cites.</summary>
public sealed record CitationArgument(
	[property: JsonPropertyName("at")] string At,
	[property: JsonPropertyName("end_at")] string? EndAt = null);
