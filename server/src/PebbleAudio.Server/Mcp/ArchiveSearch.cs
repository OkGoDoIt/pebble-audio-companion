using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// Full-text search over the archive with Postgres (English stemming, <c>websearch_to_tsquery</c>, so quotes, OR,
/// and -words work). Conversations use their generated search columns (title A, tags and overview B, transcript);
/// recaps, briefs, follow-ups, and notes are few and short, so their vectors are made as the query runs. Every query
/// is the user's own and inside the sharing scope.
/// </summary>
public sealed class ArchiveSearch(ArchiveDbContext db)
{
	/// <summary>How <c>ts_headline</c> cuts a snippet; matched words are marked with <c>**</c>.</summary>
	private const string HeadlineOptions = "MaxFragments=2, MaxWords=24, MinWords=10, ShortWord=2, StartSel=**, StopSel=**, FragmentDelimiter=\" … \"";

	public async Task<SearchPage> SearchAsync(
		ToolCall call,
		string query,
		DateOnly fromDay,
		DateOnly toDay,
		IReadOnlySet<string> kinds,
		int limit,
		CancellationToken cancellationToken)
	{
		var rows = new List<SearchRow>();
		var total = 0;
		var userId = call.UserId;
		var scopeFrom = call.From;
		var scopeFromDay = call.FromDay;
		var fromInstant = LogicalDays.Start(fromDay == DateOnly.MinValue ? new DateOnly(1900, 1, 1) : fromDay, call.Zone);
		var toInstant = LogicalDays.Start(toDay == DateOnly.MaxValue ? new DateOnly(9000, 1, 1) : toDay.AddDays(1), call.Zone);

		if (kinds.Contains("conversation"))
		{
			var found = await db.Database.SqlQuery<SearchRow>($"""
				WITH q AS (SELECT websearch_to_tsquery('english', {query}) AS q),
				hits AS (
					SELECT c."Id", c."StartedAt", c."DayKey", c."TimeZone",
						coalesce(nullif(c."Title", ''), 'Untitled conversation') AS "Title",
						ts_rank(c."SearchVector" || coalesce(t."SearchVector", ''::tsvector), q.q) AS "Rank",
						coalesce(t."SearchVector" @@ q.q, false) AS "InTranscript",
						(count(*) OVER ())::int AS "Total"
					FROM "Conversations" c
					CROSS JOIN q
					LEFT JOIN "Transcripts" t ON t."UserId" = c."UserId" AND t."ConversationId" = c."Id"
					WHERE c."UserId" = {userId}
						AND c."StartedAt" >= {scopeFrom}
						AND c."DayKey" >= {fromDay} AND c."DayKey" <= {toDay}
						AND (c."SearchVector" @@ q.q OR coalesce(t."SearchVector" @@ q.q, false))
					ORDER BY "Rank" DESC, c."StartedAt" DESC
					LIMIT {limit})
				SELECT 'conversation' AS "Kind", h."Id", h."Title", h."DayKey" AS "Day", h."TimeZone", h."Rank", h."Total",
					CASE WHEN h."InTranscript"
						THEN ts_headline('english', t."Text", q.q, {HeadlineOptions})
						ELSE ts_headline('english', coalesce(c."Summary", c."Title", ''), q.q, {HeadlineOptions})
					END AS "Snippet",
					CASE WHEN h."InTranscript" THEN (
						SELECT (item->>'At')::timestamptz
						FROM jsonb_array_elements(t."Items") AS item
						WHERE item->>'Kind' = 'Turn' AND to_tsvector('english', coalesce(item->>'Text', '')) @@ q.q
						ORDER BY (item->>'At')::timestamptz
						LIMIT 1)
					END AS "At",
					h."StartedAt" AS "ConversationStartedAt",
					NULL::text AS "ConversationId"
				FROM hits h
				CROSS JOIN q
				JOIN "Conversations" c ON c."UserId" = {userId} AND c."Id" = h."Id"
				LEFT JOIN "Transcripts" t ON t."UserId" = c."UserId" AND t."ConversationId" = c."Id"
				""").ToListAsync(cancellationToken);
			rows.AddRange(found);
			total += found.FirstOrDefault()?.Total ?? 0;
		}

		if (kinds.Contains("recap"))
		{
			var found = await db.Database.SqlQuery<SearchRow>($"""
				WITH q AS (SELECT websearch_to_tsquery('english', {query}) AS q)
				SELECT 'recap' AS "Kind", r."DayKey"::text AS "Id", coalesce(r."Headline", '') AS "Title", r."DayKey" AS "Day", r."TimeZone",
					ts_rank(v.v, q.q) AS "Rank", (count(*) OVER ())::int AS "Total",
					ts_headline('english', concat_ws(' ', r."LineSummary", r."Text"), q.q, {HeadlineOptions}) AS "Snippet",
					NULL::timestamptz AS "At", NULL::timestamptz AS "ConversationStartedAt", NULL::text AS "ConversationId"
				FROM "Recaps" r
				CROSS JOIN q
				CROSS JOIN LATERAL (SELECT to_tsvector('english', concat_ws(' ', r."Headline", r."LineSummary", r."ShortText", r."Text")) AS v) v
				WHERE r."UserId" = {userId} AND r."DayKey" >= {scopeFromDay} AND r."DayKey" >= {fromDay} AND r."DayKey" <= {toDay} AND v.v @@ q.q
				ORDER BY "Rank" DESC, r."DayKey" DESC
				LIMIT {limit}
				""").ToListAsync(cancellationToken);
			rows.AddRange(found);
			total += found.FirstOrDefault()?.Total ?? 0;
		}

		if (kinds.Contains("brief"))
		{
			var found = await db.Database.SqlQuery<SearchRow>($"""
				WITH q AS (SELECT websearch_to_tsquery('english', {query}) AS q)
				SELECT 'brief' AS "Kind", b."PeriodKey" AS "Id", coalesce(b."Headline", '') AS "Title", b."StartDay" AS "Day", NULL::text AS "TimeZone",
					ts_rank(v.v, q.q) AS "Rank", (count(*) OVER ())::int AS "Total",
					ts_headline('english', concat_ws(' ', b."LineSummary", b."Text"), q.q, {HeadlineOptions}) AS "Snippet",
					NULL::timestamptz AS "At", NULL::timestamptz AS "ConversationStartedAt", NULL::text AS "ConversationId"
				FROM "Briefs" b
				CROSS JOIN q
				CROSS JOIN LATERAL (SELECT to_tsvector('english', concat_ws(' ', b."Headline", b."LineSummary", b."Text")) AS v) v
				WHERE b."UserId" = {userId} AND b."EndDay" >= {scopeFromDay} AND b."EndDay" >= {fromDay} AND b."StartDay" <= {toDay} AND v.v @@ q.q
				ORDER BY "Rank" DESC, b."StartDay" DESC
				LIMIT {limit}
				""").ToListAsync(cancellationToken);
			rows.AddRange(found);
			total += found.FirstOrDefault()?.Total ?? 0;
		}

		if (kinds.Contains("followUp"))
		{
			var found = await db.Database.SqlQuery<SearchRow>($"""
				WITH q AS (SELECT websearch_to_tsquery('english', {query}) AS q)
				SELECT 'followUp' AS "Kind", f."Id", f."Text" AS "Title", NULL::date AS "Day", c."TimeZone",
					ts_rank(v.v, q.q) AS "Rank", (count(*) OVER ())::int AS "Total",
					ts_headline('english', concat_ws(' — ', f."Text", f."Quote", f."Why"), q.q, {HeadlineOptions}) AS "Snippet",
					coalesce(f."SourceAt", f."CreatedAt") AS "At", c."StartedAt" AS "ConversationStartedAt", c."Id" AS "ConversationId"
				FROM "FollowUps" f
				CROSS JOIN q
				CROSS JOIN LATERAL (SELECT to_tsvector('english', concat_ws(' ', f."Text", f."Quote", f."Why")) AS v) v
				LEFT JOIN "Conversations" c ON c."UserId" = f."UserId" AND c."Id" = f."SourceConversationId" AND c."StartedAt" >= {scopeFrom}
				WHERE f."UserId" = {userId}
					AND coalesce(f."SourceAt", f."CreatedAt") >= {scopeFrom}
					AND coalesce(f."SourceAt", f."CreatedAt") >= {fromInstant} AND coalesce(f."SourceAt", f."CreatedAt") < {toInstant}
					AND v.v @@ q.q
				ORDER BY "Rank" DESC, f."CreatedAt" DESC
				LIMIT {limit}
				""").ToListAsync(cancellationToken);
			rows.AddRange(found);
			total += found.FirstOrDefault()?.Total ?? 0;
		}

		if (kinds.Contains("note"))
		{
			var found = await db.Database.SqlQuery<SearchRow>($"""
				WITH q AS (SELECT websearch_to_tsquery('english', {query}) AS q)
				SELECT 'note' AS "Kind", n."Id", coalesce(nullif(n."Title", ''), 'Note') AS "Title", c."DayKey" AS "Day", c."TimeZone",
					ts_rank(v.v, q.q) AS "Rank", (count(*) OVER ())::int AS "Total",
					ts_headline('english', n."Body", q.q, {HeadlineOptions}) AS "Snippet",
					n."CreatedAt" AS "At", c."StartedAt" AS "ConversationStartedAt", c."Id" AS "ConversationId"
				FROM "Notes" n
				CROSS JOIN q
				CROSS JOIN LATERAL (SELECT to_tsvector('english', concat_ws(' ', n."Title", n."Body")) AS v) v
				LEFT JOIN "Conversations" c ON c."UserId" = n."UserId" AND c."Id" = n."ConversationId"
				WHERE n."UserId" = {userId}
					AND (CASE WHEN c."Id" IS NULL THEN n."CreatedAt" ELSE c."StartedAt" END) >= {scopeFrom}
					AND (CASE WHEN c."Id" IS NULL THEN n."CreatedAt" ELSE c."StartedAt" END) >= {fromInstant}
					AND (CASE WHEN c."Id" IS NULL THEN n."CreatedAt" ELSE c."StartedAt" END) < {toInstant}
					AND v.v @@ q.q
				ORDER BY "Rank" DESC, n."CreatedAt" DESC
				LIMIT {limit}
				""").ToListAsync(cancellationToken);
			rows.AddRange(found);
			total += found.FirstOrDefault()?.Total ?? 0;
		}

		var best = rows.OrderByDescending(r => r.Rank).ThenByDescending(r => r.Day).Take(limit).ToList();
		return new SearchPage(best, total);
	}

	/// <summary>The ids of in-scope conversations whose title, tags, overview, or transcript match.</summary>
	public Task<List<string>> MatchingConversationsAsync(ToolCall call, string query, CancellationToken cancellationToken)
	{
		var (userId, from) = (call.UserId, call.From);
		return db.Database.SqlQuery<string>($"""
			SELECT c."Id" AS "Value"
			FROM "Conversations" c
			LEFT JOIN "Transcripts" t ON t."UserId" = c."UserId" AND t."ConversationId" = c."Id"
			WHERE c."UserId" = {userId} AND c."StartedAt" >= {from}
				AND (c."SearchVector" @@ websearch_to_tsquery('english', {query})
					OR coalesce(t."SearchVector" @@ websearch_to_tsquery('english', {query}), false))
			""").ToListAsync(cancellationToken);
	}
}

/// <summary>One page of search results across kinds, best first, and how many matched in all.</summary>
public sealed record SearchPage(IReadOnlyList<SearchRow> Rows, int Total);

/// <summary>A row of the search SQL. <see cref="Id"/> is the entity's own id (a day for a recap, a period key for a brief).</summary>
public sealed class SearchRow
{
	public string Kind { get; set; } = "";

	public string Id { get; set; } = "";

	public string Title { get; set; } = "";

	public DateOnly? Day { get; set; }

	public string? TimeZone { get; set; }

	public float Rank { get; set; }

	public int Total { get; set; }

	public string? Snippet { get; set; }

	public DateTimeOffset? At { get; set; }

	public DateTimeOffset? ConversationStartedAt { get; set; }

	public string? ConversationId { get; set; }
}
