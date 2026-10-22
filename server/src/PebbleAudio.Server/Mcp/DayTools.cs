using System.ComponentModel;
using System.Globalization;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>Days and periods: <c>list_days</c>, <c>get_day</c>, and <c>get_brief</c>.</summary>
[McpServerToolType]
public sealed class DayTools
{
	private const int DefaultDays = 14;

	[McpServerTool(
		Name = "list_days",
		Title = "List days",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(ListDaysResult))]
	[McpMeta("openai/toolInvocation/invoking", "Looking over your days…")]
	[McpMeta("openai/toolInvocation/invoked", "Looked over your days")]
	[ModelContextProtocol.Extensions.Apps.McpAppUi(ResourceUri = Widgets.DayTimeline)]
	[McpMeta(Widgets.OutputTemplateKey, Widgets.DayTimeline)]
	[Description(
		"A span of days at a glance, newest first: each day's recap headline and one-line summary, how many " +
		"conversations, minutes recorded, quiet minutes (silence skipped on purpose), and lost minutes (audio genuinely " +
		"missing). Days with nothing recorded are left out. Use it to orient across a week or a month before get_day or get_brief.")]
	public static async Task<CallToolResult> ListDays(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		[Description("First day, yyyy-MM-dd, today, or yesterday. Default: 13 days before `to`.")] string? from = null,
		[Description("Last day, yyyy-MM-dd, today, or yesterday. Default: today.")] string? to = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		if (!TryDay(to, call, call.Today, out var last) || !TryDay(from, call, last.AddDays(-(DefaultDays - 1)), out var first))
		{
			return ToolResults.Error(DayHelp);
		}

		if (first > last)
		{
			(first, last) = (last, first);
		}

		var shownFrom = first < call.FromDay ? call.FromDay : first;
		var limit = call.Settings.ToolMaxResults;
		var conversationDays = await archive.Conversations(call).Where(c => c.DayKey >= shownFrom && c.DayKey <= last).Select(c => c.DayKey).Distinct().ToListAsync(cancellationToken);
		var recapDays = await archive.Recaps(call).Where(r => r.DayKey >= shownFrom && r.DayKey <= last).Select(r => r.DayKey).ToListAsync(cancellationToken);
		var coverageDays = await archive.Coverage(call).Where(c => c.DayKey >= shownFrom && c.DayKey <= last && c.RecordedMs > 0).Select(c => c.DayKey).ToListAsync(cancellationToken);
		var withData = conversationDays.Concat(recapDays).Concat(coverageDays).Distinct().OrderDescending().ToList();
		var page = withData.Take(limit).ToList();
		var days = await DaysAsync(archive, call, page, cancellationToken);

		var span = last.DayNumber - first.DayNumber + 1;
		var range = $"{Speak.ShortDay(first, call.Today)} to {Speak.ShortDay(last, call.Today)}";
		var whole = withData.Count == 0
			? $"Nothing was recorded from {range}."
			: $"{withData.Count} of the {Speak.Count(span, "day", "days")} from {range} {(withData.Count == 1 ? "has" : "have")} recordings.";

		ListDaysResult Build(int n)
		{
			var truncated = withData.Count > n;
			return new ListDaysResult(
				truncated ? Speak.Clause(whole) + $"; here are the latest {n}." : whole,
				first,
				last,
				call.Scope.TimeZoneId,
				days.GetRange(0, n),
				truncated,
				truncated && n > 0
					? new NextCall("list_days", new Dictionary<string, object> { ["from"] = Days.Key(first), ["to"] = Days.Key(days[n - 1].Day.AddDays(-1)) })
					: null);
		}

		var result = Fit.Largest(days.Count, Build, call.Settings.ToolMaxCharacters);
		await archive.LogAsync(call, "list_days", result.Days.Select(d => Days.Key(d.Day)), cancellationToken);
		return ToolResults.Of(result);
	}

	[McpServerTool(
		Name = "get_day",
		Title = "Get a day",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(GetDayResult))]
	[McpMeta("openai/toolInvocation/invoking", "Reading your day…")]
	[McpMeta("openai/toolInvocation/invoked", "Read your day")]
	[ModelContextProtocol.Extensions.Apps.McpAppUi(ResourceUri = Widgets.DayTimeline)]
	[McpMeta(Widgets.OutputTemplateKey, Widgets.DayTimeline)]
	[Description(
		"One day: the app's recap of it, how it was covered (recorded, quiet, missing, paused, off), every " +
		"conversation in time order (title, times, overview, tags, people, quiet and lost minutes), and the reminders " +
		"and follow-ups to review from that day (each with its stage). Start here for \"what happened on…\". Days roll over at 5 AM. An ambiguous date such as " +
		"\"Tuesday\" answers with candidates to choose from.")]
	public static async Task<CallToolResult> GetDay(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		[Description("The day: yyyy-MM-dd, today, or yesterday.")] string date,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		if (!Days.TryParse(date, call.Today, out var day))
		{
			if (Days.Weekday(date) is not { } weekday)
			{
				return ToolResults.Error(DayHelp);
			}

			// Which Tuesday? The two most recent, newest first.
			var back = ((int)call.Today.DayOfWeek - (int)weekday + 7) % 7;
			var recent = new[] { call.Today.AddDays(-back), call.Today.AddDays(-back - 7) };
			var choices = await CandidatesAsync(archive, call, recent, cancellationToken);
			var weekdayName = weekday.ToString();
			var ambiguous = new GetDayResult(
				$"Which {weekdayName} do you mean: {Speak.List([.. recent.Select(d => Speak.ShortDay(d, call.Today))], "or")}?",
				false,
				null,
				weekdayName,
				null,
				call.Scope.TimeZoneId,
				null,
				null,
				[],
				[],
				false,
				null,
				choices);
			await archive.LogAsync(call, "get_day", [], cancellationToken);
			return ToolResults.Of(ambiguous);
		}

		var result = await DayAsync(archive, call, day, cancellationToken);
		await archive.LogAsync(call, "get_day", [Days.Key(day), .. result.Conversations.Select(c => c.Id)], cancellationToken);
		return ToolResults.Of(result);
	}

	[McpServerTool(
		Name = "get_brief",
		Title = "Get a brief",
		ReadOnly = true,
		Destructive = false,
		Idempotent = true,
		OpenWorld = false,
		UseStructuredContent = true,
		OutputSchemaType = typeof(GetBriefResult))]
	[McpMeta("openai/toolInvocation/invoking", "Reading the brief…")]
	[McpMeta("openai/toolInvocation/invoked", "Read the brief")]
	[Description(
		"The app's written brief of a week or a month: headline, one-line summary, and text. Use it for \"how was my " +
		"week\" before reading days. Without a key it gives the latest one.")]
	public static async Task<CallToolResult> GetBrief(
		RequestContext<CallToolRequestParams> context,
		ArchiveReader archive,
		[Description("week or month.")] string kind = "week",
		[Description("The week's first day (2026-10-11), any day inside the week or month, or a month (2026-10). Default: the latest.")] string? key = null,
		CancellationToken cancellationToken = default)
	{
		var call = await archive.BeginAsync(context.User, cancellationToken);
		if (!WireNames.TryParse(kind?.Trim().ToLowerInvariant(), out BriefKind briefKind))
		{
			return ToolResults.Error("kind is week or month.");
		}

		DateOnly? target = null;
		var text = key?.Trim();
		if (!string.IsNullOrEmpty(text))
		{
			if (text.StartsWith("week:", StringComparison.OrdinalIgnoreCase) || text.StartsWith("month:", StringComparison.OrdinalIgnoreCase))
			{
				text = text[(text.IndexOf(':') + 1)..];
			}

			if (DateOnly.TryParseExact(text, "yyyy-MM", CultureInfo.InvariantCulture, DateTimeStyles.None, out var month))
			{
				target = month;
			}
			else if (Days.TryParse(text, call.Today, out var day))
			{
				target = day;
			}
			else
			{
				return ToolResults.Error("key is a day (yyyy-MM-dd), a month (yyyy-MM), or left out for the latest brief.");
			}
		}

		var briefs = archive.Briefs(call).Where(b => b.Kind == briefKind);
		var brief = target is { } t
			? await briefs.Where(b => b.StartDay <= t && b.EndDay >= t).OrderByDescending(b => b.StartDay).FirstOrDefaultAsync(cancellationToken)
			: await briefs.OrderByDescending(b => b.StartDay).FirstOrDefaultAsync(cancellationToken);
		var period = briefKind == BriefKind.Week ? "week" : "month";
		GetBriefResult result;
		if (brief is null)
		{
			var near = target ?? call.Today;
			var all = await briefs.ToListAsync(cancellationToken);
			var candidates = all
				.OrderBy(b => Math.Abs(b.StartDay.DayNumber - near.DayNumber))
				.Take(3)
				.OrderByDescending(b => b.StartDay)
				.Select(b => new BriefCandidate(period, b.PeriodKey, b.StartDay, b.EndDay, Link(archive, b), ArchiveReader.Blank(b.Headline)))
				.ToList();
			var asked = target is { } wanted ? $" for {(briefKind == BriefKind.Week ? "the week of " + Speak.ShortDay(wanted, call.Today) : wanted.ToString("MMMM yyyy", CultureInfo.GetCultureInfo("en-US")))}" : "";
			result = new GetBriefResult(
				candidates.Count == 0
					? $"There is no {period} brief yet."
					: $"There is no {period} brief{asked}; the nearest {(candidates.Count == 1 ? "is" : "are")} listed.",
				false,
				period,
				null,
				null,
				null,
				null,
				null,
				null,
				null,
				candidates);
		}
		else
		{
			var heading = briefKind == BriefKind.Week
				? $"The week of {Speak.ShortDay(brief.StartDay, call.Today)} to {(brief.StartDay.Month == brief.EndDay.Month ? brief.EndDay.Day.ToString(CultureInfo.InvariantCulture) : Speak.ShortDay(brief.EndDay, call.Today))}"
				: brief.StartDay.ToString("MMMM yyyy", CultureInfo.GetCultureInfo("en-US"));
			var gist = ArchiveReader.Blank(brief.LineSummary) ?? ArchiveReader.Blank(brief.Headline);
			result = new GetBriefResult(
				gist is null ? $"{heading}." : $"{heading}: {Speak.Clause(gist)}.",
				true,
				period,
				brief.PeriodKey,
				brief.StartDay,
				brief.EndDay,
				Link(archive, brief),
				ArchiveReader.Blank(brief.Headline),
				ArchiveReader.Blank(brief.LineSummary),
				Speak.Cap(ArchiveReader.Blank(brief.Text), call.Settings.ToolMaxCharacters / 2),
				null);
		}

		await archive.LogAsync(call, "get_brief", brief is null ? [] : [brief.PeriodKey], cancellationToken);
		return ToolResults.Of(result);
	}

	// Shared with the day:// resource

	internal static async Task<GetDayResult> DayAsync(ArchiveReader archive, ToolCall call, DateOnly day, CancellationToken cancellationToken)
	{
		var weekday = day.DayOfWeek.ToString();
		var spoken = Speak.Day(day, call.Today);
		if (!call.Scope.HoldsDay(day))
		{
			return new GetDayResult(
				$"{spoken} is before what you share with assistants.",
				false,
				day,
				weekday,
				archive.Links.Day(day),
				call.Scope.TimeZoneId,
				null,
				null,
				[],
				[],
				false,
				null,
				[]);
		}

		var recap = await archive.Recaps(call).SingleOrDefaultAsync(r => r.DayKey == day, cancellationToken);
		var coverage = await archive.Coverage(call).SingleOrDefaultAsync(c => c.DayKey == day, cancellationToken);
		var conversations = await archive.Conversations(call).Where(c => c.DayKey == day).OrderBy(c => c.StartedAt).ToListAsync(cancellationToken);
		if (recap is null && coverage is null && conversations.Count == 0)
		{
			var earlier = await archive.Conversations(call).Where(c => c.DayKey < day).Select(c => c.DayKey).Distinct().OrderByDescending(d => d).Take(2).ToListAsync(cancellationToken);
			var later = await archive.Conversations(call).Where(c => c.DayKey > day).Select(c => c.DayKey).Distinct().OrderBy(d => d).Take(2).ToListAsync(cancellationToken);
			var near = earlier.Concat(later).OrderBy(d => Math.Abs(d.DayNumber - day.DayNumber)).Take(3).OrderByDescending(d => d).ToList();
			var candidates = await CandidatesAsync(archive, call, near, cancellationToken);
			return new GetDayResult(
				near.Count == 0
					? $"Nothing was recorded on {spoken}."
					: $"Nothing was recorded on {spoken}. The nearest days with recordings are {Speak.List([.. near.Select(d => Speak.ShortDay(d, call.Today))])}.",
				false,
				day,
				weekday,
				archive.Links.Day(day),
				call.Scope.TimeZoneId,
				null,
				null,
				[],
				[],
				false,
				null,
				candidates);
		}

		var ids = conversations.Select(c => c.Id).ToList();
		// Skipped ones are the person's no: on no list, found by search or in their conversation.
		var followUps = await archive.FollowUps(call)
			.Where(f => f.SourceConversationId != null && ids.Contains(f.SourceConversationId) && f.Stage != FollowUpStage.Skipped)
			.OrderBy(f => f.SourceAt ?? f.CreatedAt)
			.Take(call.Settings.ToolMaxResults)
			.ToListAsync(cancellationToken);
		var cards = await archive.CardsAsync(call, conversations, cancellationToken);
		var zone = coverage is null ? call.Zone : LogicalDays.Zone(coverage.TimeZone);
		var opens = OpensWindow(call, day);
		var totals = Totals(coverage, conversations, opens);
		var coverageOut = coverage is null
			? null
			: new CoverageOut(
				totals.Recorded,
				totals.Quiet,
				totals.Lost,
				// On the day the sharing window opens, nothing before its start is shown: spans are cut at it.
				[
					.. coverage.Spans
						.Where(s => s.EndedAt > call.From)
						.OrderBy(s => s.StartedAt)
						.Select(s => (s.Kind, Start: s.StartedAt > call.From ? s.StartedAt : call.From, End: s.EndedAt))
						.Select(s => new CoverageSpanOut(s.Kind.ToWire(), Days.Local(s.Start, zone), Days.Local(s.End, zone), Days.Minutes(s.End - s.Start))),
				]);
		// A day can contain tens of thousands of sub-second transitions. Keep exact totals,
		// but leave detailed coverage to the day view rather than crowding out every conversation.
		if (coverageOut is not null && ToolJson.Length(coverageOut) > call.Settings.ToolMaxCharacters / 4)
		{
			coverageOut = coverageOut with { Spans = [], SpansOmitted = true };
		}

		var recapOut = recap is null
			? null
			: new RecapOut(ArchiveReader.Blank(recap.Headline), ArchiveReader.Blank(recap.LineSummary), Speak.Cap(ArchiveReader.Blank(recap.Text), call.Settings.ToolMaxCharacters / 3));
		var followUpsOut = await archive.FollowUpsAsync(call, followUps, cancellationToken);

		var recorded = totals.Recorded;
		var talk = conversations.Count(c => c.ContentKind == ContentKind.Conversation);
		var gist = ArchiveReader.Blank(recap?.Headline) ?? ArchiveReader.Blank(recap?.LineSummary);
		var summary = $"On {spoken} you had {Speak.Count(talk, "conversation", "conversations")}" +
			(recorded > 0 ? $" over {Speak.Duration(recorded)} of recording" : "") +
			(gist is null ? "." : $": {Speak.Clause(gist)}.") +
			(opens ? $" Counted from {Speak.Clock(Days.Local(call.From, zone))}, when what you share begins." : "");

		// Within the answer's length: conversations are kept in time order and the rest is said to be cut.
		var shown = cards.Take(call.Settings.ToolMaxResults).ToList();
		GetDayResult Build(IReadOnlyList<ConversationCard> list, bool cut) => new(
			cut ? Speak.Clause(summary) + $"; here are the first {list.Count}." : summary,
			true,
			day,
			weekday,
			archive.Links.Day(day),
			call.Scope.TimeZoneId,
			recapOut,
			coverageOut,
			list,
			followUpsOut,
			cut,
			cut ? new NextCall("list_conversations", new Dictionary<string, object> { ["from"] = Days.Key(day), ["to"] = Days.Key(day) }) : null,
			null);
		return Fit.Largest(shown.Count, n => Build(shown.GetRange(0, n), n < cards.Count), call.Settings.ToolMaxCharacters);
	}

	private static async Task<List<DayOut>> DaysAsync(ArchiveReader archive, ToolCall call, IReadOnlyList<DateOnly> days, CancellationToken cancellationToken)
	{
		if (days.Count == 0)
		{
			return [];
		}

		var recaps = await archive.Recaps(call).Where(r => days.Contains(r.DayKey)).ToDictionaryAsync(r => r.DayKey, cancellationToken);
		var coverage = await archive.Coverage(call).Where(c => days.Contains(c.DayKey)).ToDictionaryAsync(c => c.DayKey, cancellationToken);
		var conversations = (await archive.Conversations(call).Where(c => days.Contains(c.DayKey)).ToListAsync(cancellationToken))
			.ToLookup(c => c.DayKey);
		return
		[
			.. days.Select(day =>
			{
				recaps.TryGetValue(day, out var recap);
				coverage.TryGetValue(day, out var covered);
				var list = conversations[day].ToList();
				var totals = Totals(covered, list, OpensWindow(call, day));
				return new DayOut(
					day,
					day.DayOfWeek.ToString(),
					archive.Links.Day(day),
					ArchiveReader.Blank(recap?.Headline),
					Speak.Cap(ArchiveReader.Blank(recap?.LineSummary), ArchiveReader.ListOverviewLength),
					list.Count(c => c.ContentKind == ContentKind.Conversation),
					totals.Recorded,
					totals.Quiet,
					totals.Lost,
					recap is not null);
			}),
		];
	}

	/// <summary>
	/// True for the day the sharing window opens partway through. The phone's totals for it count the whole day, so
	/// that day is counted from its conversations inside the window instead.
	/// </summary>
	private static bool OpensWindow(ToolCall call, DateOnly day) =>
		call.Scope.From is { } from && day == call.FromDay && from > LogicalDays.Start(day, call.Zone);

	/// <summary>
	/// A day's recorded, quiet, and lost minutes: the phone's coverage when it sent one, else (and on the day the window
	/// opens) what the conversations shown hold.
	/// </summary>
	private static (double Recorded, double Quiet, double Lost) Totals(CoverageDay? coverage, IReadOnlyCollection<Conversation> conversations, bool opensWindow) =>
		coverage is not null && !opensWindow
			? (Days.Minutes(coverage.RecordedMs), Days.Minutes(coverage.QuietMs), Days.Minutes(coverage.MissingMs))
			: (Days.Minutes(conversations.Sum(c => c.RecordedMs)),
				Math.Round(conversations.Sum(c => ArchiveReader.GapMinutes(c, GapKind.Quiet)), 1),
				Math.Round(conversations.Sum(c => ArchiveReader.GapMinutes(c, GapKind.Lost)), 1));

	private static async Task<List<DayCandidate>> CandidatesAsync(ArchiveReader archive, ToolCall call, IReadOnlyList<DateOnly> days, CancellationToken cancellationToken)
	{
		var inScope = days.Where(call.Scope.HoldsDay).ToList();
		var recaps = await archive.Recaps(call).Where(r => inScope.Contains(r.DayKey)).ToDictionaryAsync(r => r.DayKey, r => r.Headline, cancellationToken);
		var counts = await archive.Conversations(call)
			.Where(c => inScope.Contains(c.DayKey) && c.ContentKind == ContentKind.Conversation)
			.GroupBy(c => c.DayKey)
			.Select(g => new { Day = g.Key, Count = g.Count() })
			.ToDictionaryAsync(g => g.Day, g => g.Count, cancellationToken);
		return
		[
			.. inScope.Select(d => new DayCandidate(
				d,
				d.DayOfWeek.ToString(),
				archive.Links.Day(d),
				ArchiveReader.Blank(recaps.GetValueOrDefault(d)),
				counts.GetValueOrDefault(d))),
		];
	}

	private static bool TryDay(string? text, ToolCall call, DateOnly fallback, out DateOnly day)
	{
		if (string.IsNullOrWhiteSpace(text))
		{
			day = fallback;
			return true;
		}

		return Days.TryParse(text, call.Today, out day);
	}

	internal static string Link(ArchiveReader archive, Brief brief) =>
		brief.Kind == BriefKind.Week ? archive.Links.Week(brief.StartDay) : archive.Links.Month(brief.StartDay);

	internal const string DayHelp = "Send days as yyyy-MM-dd, today, or yesterday.";
}

/// <summary>Fitting a result into the answer's length.</summary>
public static class Fit
{
	/// <summary>
	/// The result built with the most items (from <paramref name="count"/> down) whose JSON fits in
	/// <paramref name="maxCharacters"/>; with none fitting, the one built with none.
	/// </summary>
	public static T Largest<T>(int count, Func<int, T> build, int maxCharacters)
	{
		var full = build(count);
		if (ToolJson.Length(full) <= maxCharacters)
		{
			return full;
		}

		// Binary search on how many items fit: lengths only grow with items.
		var (low, high) = (0, count - 1);
		while (low < high)
		{
			var middle = (low + high + 1) / 2;
			if (ToolJson.Length(build(middle)) <= maxCharacters)
			{
				low = middle;
			}
			else
			{
				high = middle - 1;
			}
		}

		return build(low);
	}
}
