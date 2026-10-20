using System.ComponentModel;
using System.Globalization;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>Follow-ups, people, and tags: <c>list_follow_ups</c>, <c>get_people</c>, <c>get_tags</c>.</summary>
[McpServerToolType]
public sealed class VocabularyTools
{
	[McpServerTool(
		Name = "list_follow_ups",
		Title = "List follow-ups",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(ListFollowUpsResult))]
	[McpMeta("openai/toolInvocation/invoking", "Checking your follow-ups…")]
	[McpMeta("openai/toolInvocation/invoked", "Checked your follow-ups")]
	[Description(
		"Things the person said they would do (found by the app, written by them, or added by an assistant), with " +
		"the quote, why, due date, priority, and a link to the moment it was said. Open ones come soonest due first. " +
		"Use it for \"what did I promise\" and \"what is on my plate\".")]
	public static async Task<CallToolResult> ListFollowUps(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		[Description("open (default), done, snoozed, archived, or all.")] string status = "open",
		[Description("Only those said or created on or after this day: yyyy-MM-dd, today, or yesterday.")] string? from = null,
		[Description("Only those said or created on or before this day: yyyy-MM-dd, today, or yesterday.")] string? to = null,
		[Description("The cursor from a previous result's next.")] string? cursor = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		var wanted = status?.Trim().ToLowerInvariant();
		if (wanted is not ("open" or "done" or "snoozed" or "archived" or "all"))
		{
			return ToolResults.Error("status is open, done, snoozed, archived, or all.");
		}

		var query = archive.FollowUps(call);
		DateOnly? first = null, last = null;
		if (!string.IsNullOrWhiteSpace(from))
		{
			if (!Days.TryParse(from, call.Today, out var day))
			{
				return ToolResults.Error(DayTools.DayHelp);
			}

			first = day;
			var start = LogicalDays.Start(day, call.Zone);
			query = query.Where(f => (f.SourceAt ?? f.CreatedAt) >= start);
		}

		if (!string.IsNullOrWhiteSpace(to))
		{
			if (!Days.TryParse(to, call.Today, out var day))
			{
				return ToolResults.Error(DayTools.DayHelp);
			}

			last = day;
			var end = LogicalDays.Start(day.AddDays(1), call.Zone);
			query = query.Where(f => (f.SourceAt ?? f.CreatedAt) < end);
		}

		var now = call.Now;
		query = wanted switch
		{
			"open" => query.Where(f => !f.Done && f.ArchivedAt == null && (f.SnoozedUntil == null || f.SnoozedUntil <= now)),
			"done" => query.Where(f => f.Done && f.ArchivedAt == null),
			"snoozed" => query.Where(f => !f.Done && f.ArchivedAt == null && f.SnoozedUntil > now),
			"archived" => query.Where(f => f.ArchivedAt != null),
			_ => query,
		};
		query = wanted == "open"
			? query.OrderBy(f => f.DueAt == null).ThenBy(f => f.DueAt).ThenByDescending(f => f.CreatedAt).ThenBy(f => f.Id)
			: query.OrderByDescending(f => f.CreatedAt).ThenBy(f => f.Id);

		var offset = 0;
		if (!string.IsNullOrWhiteSpace(cursor) && !int.TryParse(cursor, NumberStyles.None, CultureInfo.InvariantCulture, out offset))
		{
			return ToolResults.Error("That cursor is not one this tool gave; leave it out to start from the top.");
		}

		var total = await query.CountAsync(cancellationToken);
		var rows = await query.Skip(offset).Take(call.Settings.ToolMaxResults).ToListAsync(cancellationToken);
		var followUps = await archive.FollowUpsAsync(call, rows, cancellationToken);

		ListFollowUpsResult Build(int n)
		{
			var shown = followUps.GetRange(0, n);
			var more = offset + n < total;
			var label = wanted == "all" ? "" : $"{wanted} ";
			string summary;
			if (total == 0)
			{
				summary = $"You have no {label}follow-ups{Range(first, last, call)}.";
			}
			else
			{
				summary = $"You have {Speak.Count(total, $"{label}follow-up", $"{label}follow-ups")}{Range(first, last, call)}";
				var lead = shown.FirstOrDefault();
				summary += lead is null ? "."
					: wanted == "open" && lead.DueAt is { } due
						? $"; the next is due {Speak.Day(DateOnly.FromDateTime(due.DateTime), call.Today)}: {Speak.Clause(lead.Text)}."
						: $"; the {(wanted == "open" ? "newest" : "latest")}: {Speak.Clause(lead.Text)}.";
			}

			NextCall? next = null;
			if (more && n > 0)
			{
				var arguments = new Dictionary<string, object> { ["status"] = wanted, ["cursor"] = (offset + n).ToString(CultureInfo.InvariantCulture) };
				if (first is { } a)
				{
					arguments["from"] = Days.Key(a);
				}

				if (last is { } b)
				{
					arguments["to"] = Days.Key(b);
				}

				next = new NextCall("list_follow_ups", arguments);
			}

			return new ListFollowUpsResult(summary, wanted, shown, more, next);
		}

		var result = Fit.Largest(followUps.Count, Build, call.Settings.ToolMaxCharacters);
		await archive.LogAsync(call, "list_follow_ups", result.FollowUps.Select(f => f.Id), cancellationToken);
		return ToolResults.Of(result);
	}

	[McpServerTool(
		Name = "get_people",
		Title = "People",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(PeopleResult))]
	[McpMeta("openai/toolInvocation/invoking", "Gathering names…")]
	[McpMeta("openai/toolInvocation/invoked", "Gathered names")]
	[Description(
		"The people who speak in the person's conversations, by name and person id, with how many conversations and " +
		"the last day, most often first. Two people with the same name have different ids. Use the name or the id as " +
		"list_conversations' person.")]
	public static async Task<CallToolResult> GetPeople(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		var names = await archive.People(call).ToDictionaryAsync(p => p.Id, p => p.Name, cancellationToken);
		var rows = await archive.Conversations(call).Select(c => new { c.Id, c.DayKey, c.People }).ToListAsync(cancellationToken);
		var people = rows
			.SelectMany(r => r.People.Select(p => (Row: r, Speaker: p)))
			.Select(x => (
				x.Row,
				PersonId: ArchiveReader.Blank(x.Speaker.PersonId),
				Name: x.Speaker.PersonId is { } id && names.TryGetValue(id, out var known) && known.Length > 0 ? known : ArchiveReader.Blank(x.Speaker.Name)))
			.Where(x => x.Name is not null)
			.GroupBy(x => x.PersonId is { } id ? $"id:{id}" : $"name:{x.Name!.ToLowerInvariant()}")
			.Select(g => new PersonOut(g.First().Name!, g.First().PersonId, g.Select(x => x.Row.Id).Distinct().Count(), g.Max(x => x.Row.DayKey)))
			.OrderByDescending(p => p.ConversationCount)
			.ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
			.ToList();

		PeopleResult Build(int n)
		{
			var shown = people.GetRange(0, n);
			var summary = people.Count == 0
				? "No one is named in your conversations yet."
				: $"{Speak.Count(people.Count, "person appears", "people appear")} in your conversations; {people[0].Name} most often.";
			return new PeopleResult(summary, shown, n < people.Count);
		}

		var result = Fit.Largest(Math.Min(people.Count, call.Settings.ToolMaxResults), Build, call.Settings.ToolMaxCharacters);
		await archive.LogAsync(call, "get_people", [], cancellationToken);
		return ToolResults.Of(result);
	}

	[McpServerTool(
		Name = "get_tags",
		Title = "Tags",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(TagsResult))]
	[McpMeta("openai/toolInvocation/invoking", "Gathering tags…")]
	[McpMeta("openai/toolInvocation/invoked", "Gathered tags")]
	[Description("The tags on the person's conversations, with how many conversations and the last day, most used first. Use one as list_conversations' tag.")]
	public static async Task<CallToolResult> GetTags(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		var rows = await archive.Conversations(call).Select(c => new { c.Id, c.DayKey, c.Tags }).ToListAsync(cancellationToken);
		var tags = rows
			.SelectMany(r => r.Tags.Where(t => !string.IsNullOrWhiteSpace(t)).Select(t => (Row: r, Tag: t.Trim())))
			.GroupBy(x => x.Tag, StringComparer.OrdinalIgnoreCase)
			.Select(g => new TagOut(g.First().Tag, g.Select(x => x.Row.Id).Distinct().Count(), g.Max(x => x.Row.DayKey)))
			.OrderByDescending(t => t.ConversationCount)
			.ThenBy(t => t.Tag, StringComparer.OrdinalIgnoreCase)
			.ToList();

		TagsResult Build(int n)
		{
			var summary = tags.Count == 0
				? "Your conversations have no tags yet."
				: $"{Speak.Count(tags.Count, "tag", "tags")}; the most used is {tags[0].Tag}.";
			return new TagsResult(summary, tags.GetRange(0, n), n < tags.Count);
		}

		var result = Fit.Largest(Math.Min(tags.Count, call.Settings.ToolMaxResults), Build, call.Settings.ToolMaxCharacters);
		await archive.LogAsync(call, "get_tags", [], cancellationToken);
		return ToolResults.Of(result);
	}

	private static string Range(DateOnly? first, DateOnly? last, ToolCall call) => (first, last) switch
	{
		({ } a, { } b) when a == b => $" from {Speak.ShortDay(a, call.Today)}",
		({ } a, { } b) => $" from {Speak.ShortDay(a, call.Today)} to {Speak.ShortDay(b, call.Today)}",
		({ } a, null) => $" since {Speak.ShortDay(a, call.Today)}",
		(null, { } b) => $" up to {Speak.ShortDay(b, call.Today)}",
		(null, null) => "",
	};
}
