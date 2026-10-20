using System.ComponentModel;
using System.Globalization;
using System.Text;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>Conversations: <c>list_conversations</c> and <c>get_conversation</c>.</summary>
[McpServerToolType]
public sealed class ConversationTools
{
	/// <summary>How many quiet minutes make a quiet gap worth listing on its own; shorter ones count in quietMinutes.</summary>
	private const double ListedQuietMinutes = 1.0;

	[McpServerTool(
		Name = "list_conversations",
		Title = "List conversations",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(ListConversationsResult))]
	[McpMeta("openai/toolInvocation/invoking", "Listing your conversations…")]
	[McpMeta("openai/toolInvocation/invoked", "Listed your conversations")]
	[Description(
		"Conversation cards, newest first, filtered by days, a tag, a person, or words (full-text over titles, " +
		"overviews, tags, and transcripts). Metadata only: title, times, overview, tags, people, quiet and lost minutes. " +
		"When a person's name or a tag matches more than one, it answers with candidates instead of guessing.")]
	public static async Task<CallToolResult> ListConversations(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		ArchiveSearch search,
		[Description("First day, yyyy-MM-dd, today, or yesterday.")] string? from = null,
		[Description("Last day, yyyy-MM-dd, today, or yesterday.")] string? to = null,
		[Description("A tag, as get_tags lists them.")] string? tag = null,
		[Description("A person's name or person id, as get_people lists them.")] string? person = null,
		[Description("Words to look for.")] string? query = null,
		[Description("The cursor from a previous result's next.")] string? cursor = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		DateOnly? first = null, last = null;
		if (!string.IsNullOrWhiteSpace(from))
		{
			if (!Days.TryParse(from, call.Today, out var day))
			{
				return ToolResults.Error(DayTools.DayHelp);
			}

			first = day;
		}

		if (!string.IsNullOrWhiteSpace(to))
		{
			if (!Days.TryParse(to, call.Today, out var day))
			{
				return ToolResults.Error(DayTools.DayHelp);
			}

			last = day;
		}

		Cursor? after = null;
		if (!string.IsNullOrWhiteSpace(cursor))
		{
			if (Cursor.Read(cursor) is not { } read)
			{
				return ToolResults.Error("That cursor is not one this tool gave; leave it out to start from the newest.");
			}

			after = read;
		}

		var range = archive.Conversations(call);
		if (first is { } f)
		{
			range = range.Where(c => c.DayKey >= f);
		}

		if (last is { } l)
		{
			range = range.Where(c => c.DayKey <= l);
		}

		var rows = await range
			.Select(c => new Row(c.Id, c.StartedAt, c.DayKey, c.Title, c.Tags, c.People))
			.ToListAsync(cancellationToken);
		var filters = new ConversationFilters(first, last, null, null, null, ArchiveReader.Blank(query));

		// A tag: exactly, else the one tag that contains the words; more than one is a question back.
		if (ArchiveReader.Blank(tag) is { } wantedTag)
		{
			var tags = rows.SelectMany(r => r.Tags).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
			var matches = tags.Where(t => t.Equals(wantedTag, StringComparison.OrdinalIgnoreCase)).ToList();
			if (matches.Count == 0)
			{
				matches = [.. tags.Where(t => t.Contains(wantedTag, StringComparison.OrdinalIgnoreCase))];
			}

			if (matches.Count > 1)
			{
				var candidates = matches
					.Select(t => (Tag: t, Rows: rows.Where(r => r.Tags.Contains(t, StringComparer.OrdinalIgnoreCase)).ToList()))
					.OrderByDescending(m => m.Rows.Count)
					.Select(m => new FilterCandidate("tag", m.Tag, null, m.Rows.Count, m.Rows.Max(r => r.DayKey), m.Rows.MaxBy(r => r.StartedAt)?.Title))
					.ToList();
				return await AskAsync(archive, call, filters with { Tag = wantedTag }, $"More than one tag matches “{wantedTag}”: {Speak.List([.. candidates.Select(c => c.Value)], "or")}. Which one?", candidates, cancellationToken);
			}

			var resolved = matches.SingleOrDefault() ?? wantedTag;
			filters = filters with { Tag = resolved };
			rows = [.. rows.Where(r => r.Tags.Contains(resolved, StringComparer.OrdinalIgnoreCase))];
		}

		// A person: by id, else by name, exactly before partly; two people with one name are a question back.
		if (ArchiveReader.Blank(person) is { } wantedPerson)
		{
			var names = await archive.People(call).ToDictionaryAsync(p => p.Id, p => p.Name, cancellationToken);
			var identities = rows
				.SelectMany(r => r.People.Select(p => (Key: Identity(p), Name: Name(p, names), PersonId: ArchiveReader.Blank(p.PersonId), Row: r)))
				.Where(p => p.Name is not null || p.PersonId is not null)
				.GroupBy(p => p.Key)
				.Select(g => (Key: g.Key, g.First().Name, g.First().PersonId, Rows: g.Select(p => p.Row).DistinctBy(r => r.Id).ToList()))
				.ToList();
			var matches = identities.Where(i => i.PersonId == wantedPerson).ToList();
			if (matches.Count == 0)
			{
				matches = [.. identities.Where(i => string.Equals(i.Name, wantedPerson, StringComparison.OrdinalIgnoreCase))];
			}

			if (matches.Count == 0)
			{
				matches = [.. identities.Where(i => i.Name?.Contains(wantedPerson, StringComparison.OrdinalIgnoreCase) == true)];
			}

			if (matches.Count > 1)
			{
				var candidates = matches
					.OrderByDescending(m => m.Rows.Count)
					.Select(m => new FilterCandidate("person", m.Name ?? m.PersonId!, m.PersonId, m.Rows.Count, m.Rows.Max(r => r.DayKey), m.Rows.MaxBy(r => r.StartedAt)?.Title))
					.ToList();
				var sameName = candidates.Select(c => c.Value).Distinct(StringComparer.OrdinalIgnoreCase).Count() == 1;
				var question = sameName
					? $"{candidates.Count} people are called {candidates[0].Value}. Which one: {Speak.List([.. candidates.Select(c => $"the one from “{c.Example}”")], "or")}?"
					: $"More than one person matches “{wantedPerson}”: {Speak.List([.. candidates.Select(c => c.Value)], "or")}. Which one?";
				return await AskAsync(archive, call, filters with { Person = wantedPerson }, question, candidates, cancellationToken);
			}

			if (matches.SingleOrDefault() is { Key: not null } match)
			{
				var ids = match.Rows.Select(r => r.Id).ToHashSet();
				rows = [.. rows.Where(r => ids.Contains(r.Id))];
				filters = filters with { Person = match.Name ?? wantedPerson, PersonId = match.PersonId };
			}
			else
			{
				rows = [];
				filters = filters with { Person = wantedPerson };
			}
		}

		if (filters.Query is { } words)
		{
			var matching = (await search.MatchingConversationsAsync(call, words, cancellationToken)).ToHashSet();
			rows = [.. rows.Where(r => matching.Contains(r.Id))];
		}

		var ordered = rows.OrderByDescending(r => r.StartedAt).ThenByDescending(r => r.Id, StringComparer.Ordinal).ToList();
		var total = ordered.Count;
		if (after is { } position)
		{
			ordered = [.. ordered.Where(r => r.StartedAt < position.StartedAt || (r.StartedAt == position.StartedAt && string.CompareOrdinal(r.Id, position.Id) < 0))];
		}

		var limit = call.Settings.ToolMaxResults;
		var pageIds = ordered.Take(limit).Select(r => r.Id).ToList();
		var conversations = (await archive.Conversations(call).Where(c => pageIds.Contains(c.Id)).ToListAsync(cancellationToken))
			.OrderByDescending(c => c.StartedAt)
			.ThenByDescending(c => c.Id, StringComparer.Ordinal)
			.ToList();
		var cards = await archive.CardsAsync(call, conversations, cancellationToken);
		var describe = Describe(filters, call);

		ListConversationsResult Build(int n)
		{
			var more = n < ordered.Count;
			var shown = cards.GetRange(0, n);
			var summary = total == 0
				? $"No conversations {describe}."
				: $"{Speak.Count(total, "conversation", "conversations")} {describe}" +
					(more ? $"; here {(n == 1 ? "is" : "are")} {(after is null ? "the newest" : "the next")} {n}." : ".");
			NextCall? next = null;
			if (more && n > 0)
			{
				var arguments = new Dictionary<string, object> { ["cursor"] = new Cursor(conversations[n - 1].StartedAt, conversations[n - 1].Id).Write() };
				AddIf(arguments, "from", first is { } a ? Days.Key(a) : null);
				AddIf(arguments, "to", last is { } b ? Days.Key(b) : null);
				AddIf(arguments, "tag", filters.Tag);
				AddIf(arguments, "person", filters.PersonId ?? filters.Person);
				AddIf(arguments, "query", filters.Query);
				next = new NextCall("list_conversations", arguments);
			}

			return new ListConversationsResult(summary, filters, shown, more, next, null);
		}

		var result = Fit.Largest(cards.Count, Build, call.Settings.ToolMaxCharacters);
		await archive.LogAsync(call, "list_conversations", result.Conversations.Select(c => c.Id), cancellationToken);
		return ToolResults.Of(result);
	}

	[McpServerTool(
		Name = "get_conversation",
		Title = "Read a conversation",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(GetConversationResult))]
	[McpMeta("openai/toolInvocation/invoking", "Reading the conversation…")]
	[McpMeta("openai/toolInvocation/invoked", "Read the conversation")]
	[Description(
		"One conversation: title, times, the app's overview, tags, people, quiet and lost gaps, follow-ups said in it, " +
		"notes, and with include=transcript or both its speaker turns in time order, each with t (seconds from the " +
		"start, for the link ?t=) and the transcriber's confidence, plus quiet, lost, and masked markers. Long " +
		"transcripts are cut to max_chars and say how to read on with from_time.")]
	public static async Task<CallToolResult> GetConversation(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		ArchiveSearch search,
		[Description("The conversation's id.")] string id,
		[Description("summary (default), transcript, or both.")] string include = "summary",
		[Description("Read the transcript from this time: an RFC 3339 time or seconds from the start.")] string? from_time = null,
		[Description("Read the transcript up to this time: an RFC 3339 time or seconds from the start.")] string? to_time = null,
		[Description("The most characters of transcript to return. Default from the server's settings.")] int? max_chars = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		var mode = include?.Trim().ToLowerInvariant();
		if (mode is not ("summary" or "transcript" or "both"))
		{
			return ToolResults.Error("include is summary, transcript, or both.");
		}

		var conversationId = id.Trim();
		var conversation = await archive.Conversations(call).SingleOrDefaultAsync(c => c.Id == conversationId, cancellationToken);
		if (conversation is null)
		{
			var candidates = await CandidatesAsync(archive, search, call, conversationId, cancellationToken);
			var missing = NotFound(conversationId, candidates.Count == 0
				? "I could not find that conversation in what you share."
				: $"I could not find a conversation with that id; {(candidates.Count == 1 ? "this one has" : "these have")} a matching title.", candidates);
			await archive.LogAsync(call, "get_conversation", [], cancellationToken);
			return ToolResults.Of(missing);
		}

		var zone = LogicalDays.Zone(conversation.TimeZone);
		DateTimeOffset? windowFrom = null, windowTo = null;
		if (!string.IsNullOrWhiteSpace(from_time))
		{
			if (!Days.TryParseTime(from_time, conversation.StartedAt, zone, out var at))
			{
				return ToolResults.Error(TimeHelp("from_time"));
			}

			windowFrom = at;
		}

		if (!string.IsNullOrWhiteSpace(to_time))
		{
			if (!Days.TryParseTime(to_time, conversation.StartedAt, zone, out var at))
			{
				return ToolResults.Error(TimeHelp("to_time"));
			}

			windowTo = at;
		}

		var withSummary = mode is "summary" or "both";
		var withTranscript = mode is "transcript" or "both";
		var transcript = await archive.Transcripts(call).SingleOrDefaultAsync(t => t.ConversationId == conversationId, cancellationToken);
		var card = archive.Card(call, conversation, transcript is not null, overviewLength: call.Settings.ToolMaxCharacters / 4);
		var gaps = conversation.Gaps
			.Where(g => g.Kind == GapKind.Lost || (g.EndedAt - g.StartedAt).TotalMinutes >= ListedQuietMinutes)
			.OrderBy(g => g.StartedAt)
			.Select(g => archive.Gap(conversation, g))
			.ToList();
		List<FollowUpOut>? followUps = null;
		List<NoteOut>? notes = null;
		if (withSummary)
		{
			var rows = await archive.FollowUps(call).Where(f => f.SourceConversationId == conversationId).OrderBy(f => f.SourceAt ?? f.CreatedAt).ToListAsync(cancellationToken);
			followUps = await archive.FollowUpsAsync(call, rows, cancellationToken);
			notes = [.. (await archive.Notes(call).Where(n => n.ConversationId == conversationId).OrderBy(n => n.CreatedAt).ToListAsync(cancellationToken))
				.Select(n => archive.Note(call, n, conversation))];
		}

		var spoken = Spoken(conversation, call);
		var window = transcript is null || !withTranscript
			? []
			: transcript.Items
				.Where(i => (windowFrom is not { } a || i.At >= a) && (windowTo is not { } b || i.At <= b))
				.OrderBy(i => i.At)
				.ToList();
		var budget = Math.Clamp(max_chars ?? call.Settings.TranscriptReadCharacters, 1_000, call.Settings.ToolMaxCharacters);

		GetConversationResult Build(IReadOnlyList<TranscriptItemOut> items, bool cut, DateTimeOffset? resumeAt) => new(
			cut ? $"{spoken} Showing {items.Count} of {window.Count} transcript items; ask for the rest with from_time." : spoken,
			true,
			card.Id,
			card.Title,
			card.Url,
			card.Day,
			card.StartedAt,
			card.EndedAt,
			card.TimeZone,
			card.Minutes,
			card.RecordedMinutes,
			withSummary ? card.Overview : null,
			card.Tags,
			card.People,
			card.Kind,
			card.Descriptor,
			card.State,
			card.Provisional,
			card.HasTranscript,
			card.ExpiredOnPhone,
			card.QuietMinutes,
			card.LostMinutes,
			gaps,
			followUps,
			notes,
			withTranscript && transcript is not null
				? new TranscriptOut(
					Days.Local(windowFrom ?? conversation.StartedAt, zone),
					Days.Local(windowTo ?? conversation.EndedAt ?? window.LastOrDefault()?.At ?? conversation.StartedAt, zone),
					window.Count,
					items.Count,
					ArchiveReader.Blank(transcript.Provider),
					ArchiveReader.Blank(transcript.Model),
					ArchiveReader.Blank(transcript.Language),
					items)
				: null,
			cut,
			cut && resumeAt is { } resume
				? new NextCall("get_conversation", NextArguments(conversationId, Days.Local(resume, zone), windowTo is { } end ? Days.Local(end, zone) : null, max_chars))
				: null,
			null);

		// Items go in while they fit: in the asked length, and in what the rest of the answer leaves.
		var room = call.Settings.ToolMaxCharacters - ToolJson.Length(Build([], window.Count > 0, window.FirstOrDefault()?.At)) - 64;
		var allowance = Math.Min(budget, room);
		var shown = new List<TranscriptItemOut>();
		var used = 0;
		foreach (var item in window)
		{
			var output = archive.Item(conversation, zone, item);
			var length = ToolJson.Length(output) + 1;
			if (used + length > allowance)
			{
				if (shown.Count == 0)
				{
					// One turn longer than the whole allowance still comes back, cut, so reading on always moves forward.
					output = output with { Text = Speak.Cap(output.Text, Math.Max(200, allowance - 400)) };
					shown.Add(output);
				}

				break;
			}

			shown.Add(output);
			used += length;
		}

		var truncated = shown.Count < window.Count;
		var result = Build(shown, truncated, truncated ? window[shown.Count].At : null);
		await archive.LogAsync(call, "get_conversation", [conversationId], cancellationToken);
		return ToolResults.Of(result);
	}

	/// <summary><c>Kitchen tiles with Sam, Tuesday 10:05 AM to 10:41 AM, 36 minutes, 1 minute of lost audio.</c></summary>
	internal static string Spoken(Conversation c, ToolCall call)
	{
		var zone = LogicalDays.Zone(c.TimeZone);
		var start = Days.Local(c.StartedAt, zone);
		var title = ArchiveReader.Blank(c.Title) ?? "An untitled conversation";
		var when = $"{Speak.Day(c.DayKey, call.Today).Split(',')[0]} {Speak.Clock(start)}" +
			(c.EndedAt is { } ended ? $" to {Speak.Clock(Days.Local(ended, zone))}" : c.State == ConversationState.Live ? ", still going" : "");
		var minutes = Days.Minutes((c.EndedAt ?? call.Now) - c.StartedAt);
		var lost = ArchiveReader.GapMinutes(c, GapKind.Lost);
		var parts = new List<string> { Speak.Clause(title), when, Speak.Duration(minutes) };
		if (lost > 0)
		{
			parts.Add($"{Speak.Duration(lost)} of lost audio");
		}

		if (c.ContentKind == ContentKind.NoConversation)
		{
			parts.Add($"not a conversation ({c.ContentDescriptor ?? "other audio"})");
		}

		if (c.Provisional)
		{
			parts.Add("still being written");
		}

		return string.Join(", ", parts) + ".";
	}

	internal static Dictionary<string, object> NextArguments(string id, DateTimeOffset from, DateTimeOffset? to, int? maxChars)
	{
		var arguments = new Dictionary<string, object>
		{
			["id"] = id,
			["include"] = "transcript",
			["from_time"] = from.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture),
		};
		if (to is { } end)
		{
			arguments["to_time"] = end.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);
		}

		if (maxChars is { } max)
		{
			arguments["max_chars"] = max;
		}

		return arguments;
	}

	internal static string TimeHelp(string name) =>
		$"{name} is an RFC 3339 time (2026-10-14T10:05:00+07:00) or whole seconds from the conversation's start (812).";

	private static GetConversationResult NotFound(string id, string summary, IReadOnlyList<ConversationCandidate> candidates) => new(
		summary, false, id, null, null, null, null, null, null, null, null, null, null, null, null, null, null,
		false, false, false, null, null, null, null, null, null, false, null, candidates);

	/// <summary>Conversations whose title matches what was passed as an id, as when a model sends a title.</summary>
	private static async Task<List<ConversationCandidate>> CandidatesAsync(ArchiveReader archive, ArchiveSearch search, ToolCall call, string text, CancellationToken cancellationToken)
	{
		var words = text.Replace('-', ' ').Replace('_', ' ');
		if (words.StartsWith("conv ", StringComparison.OrdinalIgnoreCase))
		{
			return [];
		}

		var page = await search.SearchAsync(call, words, DateOnly.MinValue, DateOnly.MaxValue, new HashSet<string> { "conversation" }, 3, cancellationToken);
		var ids = page.Rows.Select(r => r.Id).ToList();
		var conversations = await archive.Conversations(call).Where(c => ids.Contains(c.Id)).ToListAsync(cancellationToken);
		return
		[
			.. ids.Select(i => conversations.FirstOrDefault(c => c.Id == i)).OfType<Conversation>().Select(c => new ConversationCandidate(
				c.Id,
				c.Title,
				archive.Links.Conversation(c.Id),
				c.DayKey,
				Days.Local(c.StartedAt, LogicalDays.Zone(c.TimeZone)))),
		];
	}

	private static async Task<CallToolResult> AskAsync(
		ArchiveReader archive,
		ToolCall call,
		ConversationFilters filters,
		string question,
		IReadOnlyList<FilterCandidate> candidates,
		CancellationToken cancellationToken)
	{
		await archive.LogAsync(call, "list_conversations", [], cancellationToken);
		return ToolResults.Of(new ListConversationsResult(question, filters, [], false, null, candidates));
	}

	private static string Describe(ConversationFilters filters, ToolCall call)
	{
		var parts = new List<string>();
		if (filters.Person is { } person)
		{
			parts.Add($"with {person}");
		}

		if (filters.Tag is { } tag)
		{
			parts.Add($"tagged {tag}");
		}

		if (filters.Query is { } query)
		{
			parts.Add($"mentioning “{query}”");
		}

		var dates = (filters.From, filters.To) switch
		{
			({ } from, { } to) when from == to => $"on {Speak.ShortDay(from, call.Today)}",
			({ } from, { } to) => $"from {Speak.ShortDay(from, call.Today)} to {Speak.ShortDay(to, call.Today)}",
			({ } from, null) => $"since {Speak.ShortDay(from, call.Today)}",
			(null, { } to) => $"up to {Speak.ShortDay(to, call.Today)}",
			(null, null) => null,
		};
		if (dates is not null)
		{
			parts.Add(dates);
		}

		return parts.Count == 0 ? "in your archive" : string.Join(" ", parts);
	}

	private static void AddIf(Dictionary<string, object> arguments, string name, string? value)
	{
		if (value is not null)
		{
			arguments[name] = value;
		}
	}

	private static string? Identity(ConversationSpeaker speaker) =>
		ArchiveReader.Blank(speaker.PersonId) is { } id ? $"id:{id}"
		: ArchiveReader.Blank(speaker.Name) is { } name ? $"name:{name.ToLowerInvariant()}"
		: null;

	private static string? Name(ConversationSpeaker speaker, IReadOnlyDictionary<string, string> names) =>
		speaker.PersonId is { } id && names.TryGetValue(id, out var known) && known.Length > 0 ? known : ArchiveReader.Blank(speaker.Name);

	private sealed record Row(string Id, DateTimeOffset StartedAt, DateOnly DayKey, string? Title, List<string> Tags, List<ConversationSpeaker> People);

	/// <summary>Where a page ended: the last card's start and id, base64url-encoded.</summary>
	private sealed record Cursor(DateTimeOffset StartedAt, string Id)
	{
		public string Write() =>
			WebEncoders.Base64UrlEncode(Encoding.UTF8.GetBytes($"{StartedAt.UtcTicks.ToString(CultureInfo.InvariantCulture)}|{Id}"));

		public static Cursor? Read(string text)
		{
			try
			{
				var decoded = Encoding.UTF8.GetString(WebEncoders.Base64UrlDecode(text.Trim()));
				var bar = decoded.IndexOf('|');
				return bar > 0 && long.TryParse(decoded[..bar], NumberStyles.None, CultureInfo.InvariantCulture, out var ticks)
					? new Cursor(new DateTimeOffset(ticks, TimeSpan.Zero), decoded[(bar + 1)..])
					: null;
			}
			catch (FormatException)
			{
				return null;
			}
		}
	}
}
