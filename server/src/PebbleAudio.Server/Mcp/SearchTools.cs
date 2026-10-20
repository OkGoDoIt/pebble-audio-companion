using System.ComponentModel;
using System.Globalization;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// <c>search</c> and <c>fetch</c>, in the shapes ChatGPT's connectors and deep research expect (results of
/// <c>{id, title, url}</c>; a document of <c>{id, title, text, url, metadata}</c>) with the archive's own fields added.
/// </summary>
[McpServerToolType]
public sealed class SearchTools
{
	public const string RecapPrefix = "recap:";
	public const string BriefPrefix = "brief:";
	public const string FollowUpPrefix = "followUp:";
	public const string NotePrefix = "note:";

	private static readonly string[] AllKinds = ["conversation", "recap", "brief", "followUp", "note"];

	[McpServerTool(
		Name = "search",
		Title = "Search the archive",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(SearchResult))]
	[McpMeta("openai/toolInvocation/invoking", "Searching your conversations…")]
	[McpMeta("openai/toolInvocation/invoked", "Searched your conversations")]
	[Description(
		"Full-text search over the person's recorded conversations (titles, overviews, tags, transcripts), day recaps, " +
		"week and month briefs, follow-ups, and notes. Best matches first, each with an id for fetch, a title, a " +
		"snippet with the matched words in **bold**, and a link to the moment. Try several phrasings (names, places, " +
		"products) when the first search is thin. Quotes match a phrase, -word leaves a word out.")]
	public static async Task<CallToolResult> Search(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		ArchiveSearch search,
		[Description("What to look for.")] string query,
		[Description("First day, yyyy-MM-dd, today, or yesterday.")] string? from = null,
		[Description("Last day, yyyy-MM-dd, today, or yesterday.")] string? to = null,
		[Description("Any of conversation, recap, brief, followUp, note. Default: all.")] string[]? kinds = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		var text = query?.Trim() ?? "";
		if (text.Length == 0)
		{
			return ToolResults.Error("Send the words to look for in query.");
		}

		var first = DateOnly.MinValue;
		var last = DateOnly.MaxValue;
		if (!string.IsNullOrWhiteSpace(from) && !Days.TryParse(from, call.Today, out first))
		{
			return ToolResults.Error(DayTools.DayHelp);
		}

		if (!string.IsNullOrWhiteSpace(to) && !Days.TryParse(to, call.Today, out last))
		{
			return ToolResults.Error(DayTools.DayHelp);
		}

		var wanted = new HashSet<string>(StringComparer.Ordinal);
		foreach (var kind in kinds is { Length: > 0 } ? kinds : AllKinds)
		{
			var known = AllKinds.FirstOrDefault(k => k.Equals(kind?.Trim(), StringComparison.OrdinalIgnoreCase));
			if (known is null)
			{
				return ToolResults.Error("kinds are any of conversation, recap, brief, followUp, and note.");
			}

			wanted.Add(known);
		}

		var page = await search.SearchAsync(call, text, first, last, wanted, call.Settings.ToolMaxResults, cancellationToken);
		var hits = page.Rows.Select(row => Hit(archive, call, row)).ToList();

		SearchResult Build(int n)
		{
			var shown = hits.GetRange(0, n);
			var summary = page.Total == 0
				? $"Nothing matched “{text}”."
				: $"{Speak.Count(page.Total, "match", "matches")} for “{text}”; the best is {Speak.Clause(shown.FirstOrDefault()?.Title ?? hits[0].Title)}" +
					(shown.FirstOrDefault()?.Day is { } day ? $" on {Speak.ShortDay(day, call.Today)}." : ".");
			if (page.Total > n)
			{
				summary += $" Showing the best {n}; narrow the words, the days, or the kinds to see others.";
			}

			return new SearchResult(summary, text, shown, page.Total > n);
		}

		var result = Fit.Largest(hits.Count, Build, call.Settings.ToolMaxCharacters);
		await archive.LogAsync(call, "search", result.Results.Select(r => r.Id), cancellationToken);
		return ToolResults.Of(result);
	}

	[McpServerTool(
		Name = "fetch",
		Title = "Fetch an item",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(FetchResult))]
	[McpMeta("openai/toolInvocation/invoking", "Opening it…")]
	[McpMeta("openai/toolInvocation/invoked", "Opened it")]
	[Description(
		"The full text of one search result by its id: a conversation as plain text (overview, then one line per " +
		"turn with its time and speaker, and the quiet, lost, and music markers), or a recap, brief, follow-up, or note. " +
		"Long conversations are cut and metadata.next continues with get_conversation.")]
	public static async Task<CallToolResult> Fetch(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		[Description("An id from search, or a conversation id.")] string id,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		var key = id?.Trim() ?? "";
		var result = await FetchAsync(archive, call, key, cancellationToken);
		if (result is null)
		{
			await archive.LogAsync(call, "fetch", [], cancellationToken);
			return ToolResults.Error($"There is no item “{key}” in what the person shares. Use an id from search.");
		}

		await archive.LogAsync(call, "fetch", [result.Metadata.TryGetValue("conversationId", out var conversationId) ? (string)conversationId : result.Id], cancellationToken);
		return ToolResults.Of(result);
	}

	internal static async Task<FetchResult?> FetchAsync(ArchiveReader archive, ToolCall call, string key, CancellationToken cancellationToken)
	{
		// Room for the title, the summary, and the metadata around the text.
		var budget = Math.Max(call.Settings.ToolMaxCharacters / 2, call.Settings.ToolMaxCharacters - 2_000);
		if (key.StartsWith(RecapPrefix, StringComparison.Ordinal) && SyncJson.TryParseDay(key[RecapPrefix.Length..], out var day))
		{
			var recap = await archive.Recaps(call).SingleOrDefaultAsync(r => r.DayKey == day, cancellationToken);
			if (recap is null)
			{
				return null;
			}

			var title = $"{Speak.Day(day, call.Today)}{(ArchiveReader.Blank(recap.Headline) is { } headline ? $": {headline}" : "")}";
			return new FetchResult(
				$"The recap of {Speak.Day(day, call.Today)}.",
				key,
				title,
				Speak.Cap(string.Join("\n\n", new[] { recap.LineSummary, recap.Text }.Select(ArchiveReader.Blank).OfType<string>()), budget)!,
				archive.Links.Day(day),
				new Dictionary<string, object>
				{
					["kind"] = "recap",
					["day"] = Days.Key(day),
					["timeZone"] = ArchiveReader.ZoneName(recap.TimeZone),
					["conversationIds"] = recap.ConversationIds,
				});
		}

		if (key.StartsWith(BriefPrefix, StringComparison.Ordinal))
		{
			var periodKey = key[BriefPrefix.Length..];
			var brief = await archive.Briefs(call).SingleOrDefaultAsync(b => b.PeriodKey == periodKey, cancellationToken);
			if (brief is null)
			{
				return null;
			}

			var period = brief.Kind == BriefKind.Week ? $"The week of {Speak.ShortDay(brief.StartDay, call.Today)}" : brief.StartDay.ToString("MMMM yyyy", CultureInfo.GetCultureInfo("en-US"));
			return new FetchResult(
				$"{period}'s brief.",
				key,
				$"{period}{(ArchiveReader.Blank(brief.Headline) is { } headline ? $": {headline}" : "")}",
				Speak.Cap(string.Join("\n\n", new[] { brief.LineSummary, brief.Text }.Select(ArchiveReader.Blank).OfType<string>()), budget)!,
				DayTools.Link(archive, brief),
				new Dictionary<string, object>
				{
					["kind"] = "brief",
					["period"] = brief.Kind.ToWire(),
					["startDay"] = Days.Key(brief.StartDay),
					["endDay"] = Days.Key(brief.EndDay),
				});
		}

		if (key.StartsWith(FollowUpPrefix, StringComparison.Ordinal))
		{
			var followUpId = key[FollowUpPrefix.Length..];
			var followUp = await archive.FollowUps(call).SingleOrDefaultAsync(f => f.Id == followUpId, cancellationToken);
			if (followUp is null)
			{
				return null;
			}

			var shaped = (await archive.FollowUpsAsync(call, [followUp], cancellationToken))[0];
			var lines = new List<string> { shaped.Text };
			lines.AddRange(new[] { shaped.Quote is { } quote ? $"Said: “{quote}”" : null, shaped.Why is { } why ? $"Why: {why}" : null }.OfType<string>());
			lines.Add($"Status: {shaped.Status}{(shaped.DueAt is { } due ? $", due {due:yyyy-MM-dd HH:mm}" : "")}");
			var metadata = new Dictionary<string, object> { ["kind"] = "followUp", ["status"] = shaped.Status, ["priority"] = shaped.Priority, ["origin"] = shaped.Origin };
			if (shaped.Source is { } source)
			{
				lines.Add($"From: {source.Title ?? "a conversation"}");
				metadata["conversationId"] = source.ConversationId;
			}

			return new FetchResult($"A follow-up: {Speak.Clause(shaped.Text)}.", key, Speak.Cap(shaped.Text, 200)!, string.Join("\n", lines), shaped.Url, metadata);
		}

		if (key.StartsWith(NotePrefix, StringComparison.Ordinal))
		{
			var noteId = key[NotePrefix.Length..];
			var note = await archive.Notes(call).SingleOrDefaultAsync(n => n.Id == noteId, cancellationToken);
			if (note is null)
			{
				return null;
			}

			var conversation = note.ConversationId is { } cid ? await archive.Conversations(call).SingleOrDefaultAsync(c => c.Id == cid, cancellationToken) : null;
			var shaped = archive.Note(call, note, conversation);
			var metadata = new Dictionary<string, object> { ["kind"] = "note", ["origin"] = shaped.Origin };
			if (conversation is not null)
			{
				metadata["conversationId"] = conversation.Id;
			}

			return new FetchResult(
				$"A note{(conversation?.Title is { } on ? $" on {Speak.Clause(on)}" : "")}.",
				key,
				shaped.Title ?? "Note",
				Speak.Cap(shaped.Body, budget)!,
				shaped.Url,
				metadata);
		}

		var conversationId = key.StartsWith("conversation:", StringComparison.Ordinal) ? key["conversation:".Length..] : key;
		var found = await archive.Conversations(call).SingleOrDefaultAsync(c => c.Id == conversationId, cancellationToken);
		if (found is null)
		{
			return null;
		}

		var transcript = await archive.Transcripts(call).SingleOrDefaultAsync(t => t.ConversationId == conversationId, cancellationToken);
		var rendered = ArchiveText.Conversation(found, transcript, budget, markdown: false);
		var zone = LogicalDays.Zone(found.TimeZone);
		var data = new Dictionary<string, object>
		{
			["kind"] = "conversation",
			["day"] = Days.Key(found.DayKey),
			["startedAt"] = Days.Local(found.StartedAt, zone),
			["timeZone"] = ArchiveReader.ZoneName(found.TimeZone),
			["people"] = found.People.Select(p => p.Name).OfType<string>().Distinct().ToList(),
			["tags"] = found.Tags,
			["quietMinutes"] = ArchiveReader.GapMinutes(found, GapKind.Quiet),
			["lostMinutes"] = ArchiveReader.GapMinutes(found, GapKind.Lost),
			["provisional"] = found.Provisional,
			["truncated"] = rendered.Truncated,
		};
		if (found.EndedAt is { } ended)
		{
			data["endedAt"] = Days.Local(ended, zone);
		}

		if (rendered.ResumeAt is { } resume)
		{
			data["next"] = new NextCall("get_conversation", ConversationTools.NextArguments(found.Id, Days.Local(resume, zone), null, null));
		}

		return new FetchResult(
			ConversationTools.Spoken(found, call),
			found.Id,
			ArchiveReader.Blank(found.Title) ?? "Untitled conversation",
			rendered.Text,
			archive.Links.Conversation(found.Id),
			data);
	}

	private static SearchHit Hit(ArchiveReader archive, ToolCall call, SearchRow row)
	{
		var zone = row.TimeZone is not null ? LogicalDays.Zone(row.TimeZone) : call.Zone;
		var snippet = ArchiveReader.Blank(row.Snippet);
		switch (row.Kind)
		{
			case "conversation":
				var t = row.At is { } at && row.ConversationStartedAt is { } start ? Days.Offset(at, start) : 0;
				return new SearchHit(row.Id, row.Title, archive.Links.Moment(row.Id, t), "conversation", row.Day, Days.Local(row.At, zone), snippet);
			case "recap":
				var day = row.Day!.Value;
				var title = $"{Speak.Day(day, call.Today)}{(row.Title.Length > 0 ? $": {row.Title}" : "")}";
				return new SearchHit(RecapPrefix + row.Id, title, archive.Links.Day(day), "recap", day, null, snippet);
			case "brief":
				var startDay = row.Day!.Value;
				var isWeek = row.Id.StartsWith("week:", StringComparison.Ordinal);
				var period = isWeek ? $"The week of {Speak.ShortDay(startDay, call.Today)}" : startDay.ToString("MMMM yyyy", CultureInfo.GetCultureInfo("en-US"));
				return new SearchHit(
					BriefPrefix + row.Id,
					$"{period}{(row.Title.Length > 0 ? $": {row.Title}" : "")}",
					isWeek ? archive.Links.Week(startDay) : archive.Links.Month(startDay),
					"brief",
					startDay,
					null,
					snippet);
			case "followUp":
				var followUpUrl = row.ConversationId is { } source && row.ConversationStartedAt is { } sourceStart && row.At is { } said
					? archive.Links.Moment(source, Days.Offset(said, sourceStart))
					: archive.Links.Day(LogicalDays.Of(row.At ?? call.Now, zone));
				return new SearchHit(FollowUpPrefix + row.Id, Speak.Cap(row.Title, 200)!, followUpUrl, "followUp", row.At is { } a ? LogicalDays.Of(a, zone) : null, Days.Local(row.At, zone), snippet);
			default:
				var noteUrl = row.ConversationId is { } noteConversation ? archive.Links.Conversation(noteConversation) : archive.Links.Day(LogicalDays.Of(row.At ?? call.Now, zone));
				return new SearchHit(NotePrefix + row.Id, row.Title, noteUrl, "note", row.Day ?? (row.At is { } written ? LogicalDays.Of(written, zone) : null), null, snippet);
		}
	}
}
