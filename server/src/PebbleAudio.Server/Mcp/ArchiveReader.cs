using System.Security.Claims;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Settings;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// One tool call: who is asking, the sharing scope at this moment, and the settings that cap the answer.
/// </summary>
public sealed record ToolCall(Guid UserId, AccountScope Scope, ArchiveSettings Settings, ClaimsPrincipal User)
{
	/// <summary>Earlier than anything the phone records, for an unbounded scope in SQL.</summary>
	public static readonly DateTimeOffset Earliest = new(1900, 1, 1, 0, 0, 0, TimeSpan.Zero);

	/// <summary>The earliest instant the archive may show now.</summary>
	public DateTimeOffset From => Scope.From ?? Earliest;

	/// <summary>The earliest logical day the archive may show now.</summary>
	public DateOnly FromDay => Scope.FromDay ?? DateOnly.MinValue;

	public TimeZoneInfo Zone => Scope.TimeZone;

	public DateOnly Today => Scope.Today;

	public DateTimeOffset Now => Scope.Now;
}

/// <summary>
/// Everything the tools read goes through here, so every query is the user's own and inside the sharing scope
/// (sync-protocol.md §5), and every row becomes the shapes of docs/tool-results.md the same way.
/// </summary>
public sealed class ArchiveReader(
	ArchiveDbContext db,
	SharingScopes scopes,
	SettingsService settings,
	ViewerLinks links,
	AiReadLog reads)
{
	/// <summary>The most characters of a conversation's overview in a list.</summary>
	public const int ListOverviewLength = 400;

	public ViewerLinks Links => links;

	public ArchiveDbContext Db => db;

	public async Task<ToolCall> BeginAsync(ClaimsPrincipal? user, CancellationToken cancellationToken)
	{
		var userId = user.UserId() ?? throw new McpException("This request is not signed in to an archive.");
		return new ToolCall(userId, await scopes.GetAsync(userId, cancellationToken), await settings.GetAsync(cancellationToken), user!);
	}

	/// <summary>Notes the call in the AI-read log the phone shows: which assistant, which tool, which ids it was given.</summary>
	public Task LogAsync(ToolCall call, string tool, IEnumerable<string> ids, CancellationToken cancellationToken) =>
		reads.RecordAsync(call.User, tool, [.. ids.Distinct().Take(200)], cancellationToken);

	// The user's rows inside the scope

	public IQueryable<Conversation> Conversations(ToolCall call)
	{
		var (userId, from) = (call.UserId, call.From);
		return db.Conversations.AsNoTracking().Where(c => c.UserId == userId && c.StartedAt >= from);
	}

	public IQueryable<Transcript> Transcripts(ToolCall call)
	{
		var (userId, from) = (call.UserId, call.From);
		return db.Transcripts.AsNoTracking().Where(t =>
			t.UserId == userId &&
			db.Conversations.Any(c => c.UserId == userId && c.Id == t.ConversationId && c.StartedAt >= from));
	}

	public IQueryable<Recap> Recaps(ToolCall call)
	{
		var (userId, fromDay) = (call.UserId, call.FromDay);
		return db.Recaps.AsNoTracking().Where(r => r.UserId == userId && r.DayKey >= fromDay);
	}

	public IQueryable<Brief> Briefs(ToolCall call)
	{
		var (userId, fromDay) = (call.UserId, call.FromDay);
		return db.Briefs.AsNoTracking().Where(b => b.UserId == userId && b.EndDay >= fromDay);
	}

	public IQueryable<CoverageDay> Coverage(ToolCall call)
	{
		var (userId, fromDay) = (call.UserId, call.FromDay);
		return db.CoverageDays.AsNoTracking().Where(c => c.UserId == userId && c.DayKey >= fromDay);
	}

	public IQueryable<FollowUp> FollowUps(ToolCall call)
	{
		var (userId, from) = (call.UserId, call.From);
		return db.FollowUps.AsNoTracking().Where(f => f.UserId == userId && (f.SourceAt ?? f.CreatedAt) >= from);
	}

	/// <summary>Notes dated by their conversation, or by when they were written when it is not here.</summary>
	public IQueryable<Note> Notes(ToolCall call)
	{
		var (userId, from) = (call.UserId, call.From);
		return db.Notes.AsNoTracking().Where(n =>
			n.UserId == userId &&
			(db.Conversations.Any(c => c.UserId == userId && c.Id == n.ConversationId && c.StartedAt >= from) ||
				(!db.Conversations.Any(c => c.UserId == userId && c.Id == n.ConversationId) && n.CreatedAt >= from)));
	}

	public IQueryable<Person> People(ToolCall call)
	{
		var userId = call.UserId;
		return db.People.AsNoTracking().Where(p => p.UserId == userId);
	}

	/// <summary>Which of these conversations have a transcript.</summary>
	public async Task<HashSet<string>> WithTranscriptsAsync(ToolCall call, IReadOnlyCollection<string> ids, CancellationToken cancellationToken)
	{
		var userId = call.UserId;
		return [.. await db.Transcripts.Where(t => t.UserId == userId && ids.Contains(t.ConversationId)).Select(t => t.ConversationId).ToListAsync(cancellationToken)];
	}

	/// <summary>Cards for these conversations, in the order given.</summary>
	public async Task<List<ConversationCard>> CardsAsync(ToolCall call, IReadOnlyList<Conversation> conversations, CancellationToken cancellationToken)
	{
		var withTranscripts = await WithTranscriptsAsync(call, [.. conversations.Select(c => c.Id)], cancellationToken);
		return [.. conversations.Select(c => Card(call, c, withTranscripts.Contains(c.Id), ListOverviewLength))];
	}

	// Rows into result shapes

	public ConversationCard Card(ToolCall call, Conversation c, bool hasTranscript, int? overviewLength)
	{
		var zone = LogicalDays.Zone(c.TimeZone);
		var end = End(c, call.Now);
		return new ConversationCard(
			c.Id,
			c.Title,
			links.Conversation(c.Id),
			c.DayKey,
			Days.Local(c.StartedAt, zone),
			Days.Local(c.EndedAt, zone),
			ZoneName(c.TimeZone),
			Days.Minutes(end - c.StartedAt),
			Days.Minutes(c.RecordedMs),
			overviewLength is { } length ? Speak.Cap(Blank(c.Summary), length) : Blank(c.Summary),
			c.Tags,
			[.. c.People.Select(p => new SpeakerOut(p.Label, Blank(p.Name), Blank(p.PersonId)))],
			c.ContentKind.ToWire(),
			c.ContentKind == ContentKind.NoConversation ? Blank(c.ContentDescriptor) : null,
			c.State.ToWire(),
			c.Provisional,
			hasTranscript,
			c.ExpiredOnPhoneAt is not null,
			GapMinutes(c, GapKind.Quiet),
			GapMinutes(c, GapKind.Lost));
	}

	/// <summary>
	/// Where a conversation ends for its length: its end time; now while it is live; else, closed without one, its
	/// start plus the audio it recorded.
	/// </summary>
	public static DateTimeOffset End(Conversation c, DateTimeOffset now) =>
		c.EndedAt ?? (c.State == ConversationState.Live ? now : c.StartedAt + TimeSpan.FromMilliseconds(c.RecordedMs));

	public GapOut Gap(Conversation c, ConversationGap g)
	{
		var zone = LogicalDays.Zone(c.TimeZone);
		return new GapOut(
			g.Kind.ToWire(),
			Days.Local(g.StartedAt, zone),
			Days.Local(g.EndedAt, zone),
			Days.Offset(g.StartedAt, c.StartedAt),
			Days.Minutes(g.EndedAt - g.StartedAt),
			g.Kind == GapKind.Lost ? Blank(g.Origin) ?? "unknown" : null,
			g.Kind == GapKind.Quiet ? Blank(g.Reason) : null);
	}

	public TranscriptItemOut Item(Conversation c, TimeZoneInfo zone, TranscriptItem i) => i.Kind switch
	{
		TranscriptItemKind.Turn => new TranscriptItemOut(
			"turn",
			Days.Offset(i.At, c.StartedAt),
			Days.Local(i.At, zone),
			null,
			null,
			Blank(i.Speaker),
			Blank(i.Name),
			i.Text ?? "",
			i.Confidence is { } confidence ? Math.Round(confidence, 2) : null,
			null,
			null),
		TranscriptItemKind.Quiet or TranscriptItemKind.Lost or TranscriptItemKind.Masked => new TranscriptItemOut(
			i.Kind.ToWire(),
			Days.Offset(i.At, c.StartedAt),
			Days.Local(i.At, zone),
			Days.Local(i.EndAt, zone),
			i.EndAt is { } end ? Days.Minutes(end - i.At) : null,
			null,
			null,
			null,
			null,
			i.Kind == TranscriptItemKind.Lost ? Blank(i.Origin) ?? "unknown" : null,
			i.Kind == TranscriptItemKind.Masked ? Blank(i.Descriptor) ?? "music" : null),
	};

	/// <summary>
	/// A follow-up, linked to the moment it was said when its conversation is in <paramref name="sources"/> (that is,
	/// inside the scope), else to its day.
	/// </summary>
	public FollowUpOut FollowUp(ToolCall call, FollowUp f, IReadOnlyDictionary<string, Conversation> sources)
	{
		var source = f.SourceConversationId is { } sourceId && sources.TryGetValue(sourceId, out var found) ? found : null;
		var zone = source is null ? call.Zone : LogicalDays.Zone(source.TimeZone);
		FollowUpSourceOut? sourceOut = null;
		string url;
		if (source is not null)
		{
			int? t = f.SourceAt is { } at ? Days.Offset(at, source.StartedAt) : null;
			url = t is { } seconds ? links.Moment(source.Id, seconds) : links.Conversation(source.Id);
			sourceOut = new FollowUpSourceOut(source.Id, source.Title, Days.Local(f.SourceAt, zone), t, url, f.SourceApproximate);
		}
		else
		{
			url = links.Day(LogicalDays.Of(f.SourceAt ?? f.CreatedAt, zone));
		}

		return new FollowUpOut(
			f.Id,
			f.Text,
			url,
			Blank(f.Quote),
			Blank(f.Why),
			Days.Local(f.DueAt, zone),
			f.Priority switch
			{
				<= 0 => "low",
				1 => "normal",
				_ => "high",
			},
			FollowUpStatus(f, call.Now),
			f.Done,
			Days.Local(f.CompletedAt, zone),
			Days.Local(f.SnoozedUntil, zone),
			Days.Local(f.ArchivedAt, zone),
			f.Origin.ToWire(),
			Days.Local(f.CreatedAt, zone),
			sourceOut,
			f.Origin == ContentOrigin.Assistant && f.Version == 0);
	}

	/// <summary>Follow-ups with their sources looked up in the scope.</summary>
	public async Task<List<FollowUpOut>> FollowUpsAsync(ToolCall call, IReadOnlyList<FollowUp> followUps, CancellationToken cancellationToken)
	{
		var ids = followUps.Select(f => f.SourceConversationId).OfType<string>().Distinct().ToList();
		var sources = await Conversations(call).Where(c => ids.Contains(c.Id)).ToDictionaryAsync(c => c.Id, cancellationToken);
		return [.. followUps.Select(f => FollowUp(call, f, sources))];
	}

	public NoteOut Note(ToolCall call, Note n, Conversation? conversation)
	{
		var zone = conversation is null ? call.Zone : LogicalDays.Zone(conversation.TimeZone);
		return new NoteOut(
			n.Id,
			conversation?.Id,
			Blank(n.Title),
			n.Body,
			conversation is null ? links.Day(LogicalDays.Of(n.CreatedAt, zone)) : links.Conversation(conversation.Id),
			n.Origin.ToWire(),
			Days.Local(n.CreatedAt, zone),
			Days.Local(n.EditedAt, zone),
			[
				.. n.Citations
					.Where(c => conversation is not null && c.ConversationId == conversation.Id)
					.Select(c => new CitationOut(
						c.ConversationId,
						Days.Local(c.At, zone),
						Days.Offset(c.At, conversation!.StartedAt),
						links.Moment(c.ConversationId, Days.Offset(c.At, conversation.StartedAt)))),
			],
			n.Origin == ContentOrigin.Assistant && n.Version == 0);
	}

	public static string FollowUpStatus(FollowUp f, DateTimeOffset now) =>
		f.ArchivedAt is not null ? "archived"
		: f.Done ? "done"
		: f.SnoozedUntil > now ? "snoozed"
		: "open";

	public static double GapMinutes(Conversation c, GapKind kind) =>
		Days.Minutes(TimeSpan.FromTicks(c.Gaps.Where(g => g.Kind == kind).Sum(g => Math.Max(0, (g.EndedAt - g.StartedAt).Ticks))));

	/// <summary>The zone's id as the phone sent it, or UTC.</summary>
	public static string ZoneName(string? zone) => string.IsNullOrWhiteSpace(zone) ? "UTC" : zone;

	public static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
