using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Mcp;

/// <summary>How a row reads: calm quiet, the watch's power-save pause, or an interruption.</summary>
public enum GapRowKind
{
	Quiet,
	Paused,
	Lost,
}

/// <summary>
/// One quiet, paused, or interrupted row of a conversation, the way the phone's Conversation screen shows it.
/// </summary>
/// <param name="Words">The row's own words without its cause, in the app's wording: <c>audio interrupted for 1 min over 14
/// min</c>, <c>quiet for 3 min</c>.</param>
/// <param name="Cause">On an interruption: the cause the row names (<c>watch buffer filled while disconnected</c>,
/// <c>2 reasons</c>), or null when nothing says why.</param>
/// <param name="MissingSeconds">On an interruption: the audio genuinely missing inside the row. The row's stretch
/// (<see cref="StartedAt"/> to <see cref="EndedAt"/>) can be far longer: brief drops a few seconds apart are one row.</param>
/// <param name="Shown">False for an interruption too brief for a transcript row of its own (under 10 seconds). It still
/// counts in the missing total and still marks the strip, as it marks the app's scrubber.</param>
public sealed record GapRow(
	GapRowKind Kind,
	DateTimeOffset StartedAt,
	DateTimeOffset EndedAt,
	string Words,
	string? Cause,
	IReadOnlyList<GapCause> Causes,
	double MissingSeconds,
	string? Origin,
	bool Shown)
{
	/// <summary>The row as the app labels it: its words, then its cause in parentheses.</summary>
	public string Label => Cause is null ? Words : $"{Words} ({Cause})";

	public double Seconds => Math.Max(0, (EndedAt - StartedAt).TotalSeconds);
}

/// <summary>
/// The one way the server reads a conversation's gaps. A phone with the gap change sends the rows its transcript screen
/// shows — merged, thresholded, and worded by the app's own rule (sync-protocol.md §2.1) — and they are taken as sent.
/// A phone before it sent one gap per record (on a choppy recording, a thousand one-second losses), and until it sends
/// the conversation again those are read here the app's way: records within 5 seconds of each other are one row, a
/// row under 10 seconds gets no line of its own, quiet under 30 seconds is not a row, and a hole between two pieces that
/// no record explains is not loss (the app calls it not recording, and before 2026-09-30 it was mostly the watch's
/// skipped silence). The legacy reading can name a cause only for audio the phone missed: an old record does not say
/// why the watch dropped it.
/// </summary>
public static class GapRows
{
	/// <summary>An interruption shorter than this gets no transcript row (the app's <c>minimumShownLossMs</c>).</summary>
	public const double ShownLossSeconds = 10;

	/// <summary>Quiet earns a labelled row from here (the app's <c>quietPauseThresholdMs</c>).</summary>
	public const double QuietRowSeconds = 30;

	/// <summary>Records this close together are one row (the app's <c>gapCollapseWindowMs</c>).</summary>
	public const double CollapseSeconds = 5;

	/// <summary>The app's words for the watch's power-save pause.</summary>
	public const string WatchSavingPower = "watch was saving power";

	/// <summary>Whether the phone sent this conversation's gaps as the app's rows (it labels every row).</summary>
	public static bool AreRows(Conversation c) => c.Gaps.Count == 0 || c.Gaps.All(g => g.Label is not null);

	/// <summary>Every row of the conversation, in time order, brief interruptions included.</summary>
	public static IReadOnlyList<GapRow> Of(Conversation c) => AreRows(c) ? AsSent(c) : FromRecords(c);

	/// <summary>
	/// The audio genuinely missing inside the conversation, in seconds: the phone's own total (what its History card
	/// says), or for an older phone the loss records, merged, with unexplained holes between pieces left out.
	/// </summary>
	public static double MissingSeconds(Conversation c) =>
		c.MissingMs is { } ms
			? ms / 1000.0
			: Union(c.Gaps.Where(g => g.Kind == GapKind.Lost && g.Origin is "watch" or "link").Select(g => (g.StartedAt, g.EndedAt)));

	/// <summary>The conversation's quiet rows, in seconds (the watch's power-save pause is not quiet).</summary>
	public static double QuietSeconds(Conversation c) => Of(c).Where(r => r.Kind == GapRowKind.Quiet).Sum(r => r.Seconds);

	/// <summary>
	/// A transcript's items with its quiet and lost markers replaced by the conversation's shown rows, in time order: at
	/// one instant a row reads before the words that follow it. For a new phone the two are the same rows; for an older
	/// one this is what keeps a thousand one-second markers out of the transcript.
	/// </summary>
	public static List<TranscriptItem> Interleave(IEnumerable<TranscriptItem> items, Conversation c)
	{
		var rows = Of(c).Where(r => r.Shown).Select(r => new TranscriptItem
		{
			Kind = r.Kind == GapRowKind.Lost ? TranscriptItemKind.Lost : TranscriptItemKind.Quiet,
			At = r.StartedAt,
			EndAt = r.EndedAt,
			Origin = r.Kind == GapRowKind.Lost ? r.Origin ?? "unknown" : null,
			Label = r.Words,
			Cause = r.Cause,
			MissingMs = r.Kind == GapRowKind.Lost ? (long)Math.Round(r.MissingSeconds * 1000) : null,
			Reason = r.Kind == GapRowKind.Paused ? "watchPause" : null,
		});
		return
		[
			.. items
				.Where(i => i.Kind is TranscriptItemKind.Turn or TranscriptItemKind.Masked)
				.Select((item, index) => (item, rank: item.Kind == TranscriptItemKind.Turn ? 1 : 0, index))
				.Concat(rows.Select((item, index) => (item, rank: 0, index: -1 - index)))
				.OrderBy(x => x.item.At)
				.ThenBy(x => x.rank)
				.ThenBy(x => x.index)
				.Select(x => x.item),
		];
	}

	/// <summary>
	/// A duration the way the app's transcript words it (StatusUI <c>Formatting.duration</c>): whole units, truncated —
	/// <c>14 min</c>, <c>1 hr 5 min</c>, <c>48 sec</c>.
	/// </summary>
	public static string AppDuration(double seconds)
	{
		var total = (long)Math.Max(0, Math.Floor(seconds));
		var (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60);
		return (hours, minutes) switch
		{
			( > 0, > 0) => $"{hours} hr {minutes} min",
			( > 0, _) => $"{hours} hr",
			(_, > 0) => $"{minutes} min",
			_ => $"{rest} sec",
		};
	}

	/// <summary>
	/// An interruption spread thin over its stretch — brief drops through minutes of audio that was heard — rather than
	/// one hole (the app's <c>Pause.isSpread</c>, without its wording check). Drawn as a tick where it starts, not to
	/// scale.
	/// </summary>
	public static bool IsSpread(GapRow row) =>
		row.Kind == GapRowKind.Lost && row.MissingSeconds >= 1 && row.Seconds >= row.MissingSeconds * 2;

	/// <summary>
	/// An interruption's words (the app's <c>Pause.summaryText</c>): what it did not hear, and over how long when that was
	/// spread thin — <c>audio interrupted for 1 min over 14 min</c>.
	/// </summary>
	public static string InterruptionWords(double interruptedSeconds, double stretchSeconds)
	{
		if (interruptedSeconds < 1)
		{
			return "audio briefly interrupted";
		}

		var words = $"audio interrupted for {AppDuration(interruptedSeconds)}";
		var spread = stretchSeconds >= interruptedSeconds * 2 && AppDuration(stretchSeconds) != AppDuration(interruptedSeconds);
		return spread ? $"{words} over {AppDuration(stretchSeconds)}" : words;
	}

	// The phone's rows

	private static List<GapRow> AsSent(Conversation c) =>
	[
		.. c.Gaps.OrderBy(g => g.StartedAt).Select(g =>
		{
			var paused = g.Kind == GapKind.Quiet && g.Reason == "watchPause";
			var kind = g.Kind == GapKind.Lost ? GapRowKind.Lost : paused ? GapRowKind.Paused : GapRowKind.Quiet;
			var seconds = Math.Max(0, (g.EndedAt - g.StartedAt).TotalSeconds);
			return new GapRow(
				kind,
				g.StartedAt,
				g.EndedAt,
				paused ? $"paused for {AppDuration(seconds)}" : g.Label ?? "",
				kind switch
				{
					GapRowKind.Lost => ArchiveReader.Blank(g.Cause),
					GapRowKind.Paused => WatchSavingPower,
					_ => null,
				},
				g.Causes,
				kind == GapRowKind.Lost ? (g.MissingMs ?? (long)(seconds * 1000)) / 1000.0 : 0,
				kind == GapRowKind.Lost ? ArchiveReader.Blank(g.Origin) ?? "unknown" : null,
				g.Shown ?? true);
		}),
	];

	// An older phone's records

	private static List<GapRow> FromRecords(Conversation c)
	{
		var pieceStarts = c.Pieces.Select(p => p.StartedAt).Order().ToList();
		int PieceOf(DateTimeOffset at) => pieceStarts.Count(s => s <= at);

		var rows = new List<GapRow>();
		// Interruptions: records within the collapse window of each other, never across a piece (the app builds each
		// piece's rows on its own).
		foreach (var run in Runs(c.Gaps.Where(g => g.Kind == GapKind.Lost && g.Origin is "watch" or "link"), PieceOf))
		{
			var start = run.Min(g => g.StartedAt);
			var end = run.Max(g => g.EndedAt);
			var missing = Union(run.Select(g => (g.StartedAt, g.EndedAt)));
			var stretch = (end - start).TotalSeconds;
			// The one cause an old record states: the phone saw the watch's numbers jump and nothing said why.
			string? cause = run.All(g => g.Origin == "link")
				? missing >= 60 ? "phone missed audio" : "phone briefly missed audio"
				: null;
			rows.Add(new GapRow(
				GapRowKind.Lost, start, end, InterruptionWords(missing, stretch), cause, [], missing,
				run.GroupBy(g => g.Origin).OrderByDescending(o => o.Count()).First().Key, stretch >= ShownLossSeconds));
		}

		foreach (var run in Runs(c.Gaps.Where(g => g.Kind == GapKind.Quiet && g.Reason == "watchPause"), PieceOf))
		{
			var (start, end) = (run.Min(g => g.StartedAt), run.Max(g => g.EndedAt));
			var seconds = (end - start).TotalSeconds;
			rows.Add(new GapRow(GapRowKind.Paused, start, end, $"paused for {AppDuration(seconds)}", WatchSavingPower, [], 0, null, seconds >= ShownLossSeconds));
		}

		// Quiet is a stretch: a run's whole length, labelled from 30 seconds; anything shorter is not a row in the app.
		foreach (var run in Runs(c.Gaps.Where(g => g.Kind == GapKind.Quiet && g.Reason != "watchPause"), PieceOf))
		{
			var (start, end) = (run.Min(g => g.StartedAt), run.Max(g => g.EndedAt));
			var seconds = (end - start).TotalSeconds;
			if (seconds >= QuietRowSeconds)
			{
				rows.Add(new GapRow(GapRowKind.Quiet, start, end, $"quiet for {AppDuration(seconds)}", null, [], 0, null, true));
			}
		}

		return [.. rows.OrderBy(r => r.StartedAt)];
	}

	/// <summary>Records in time order, split wherever the next starts more than the collapse window after the run's end,
	/// or in another piece.</summary>
	private static IEnumerable<List<ConversationGap>> Runs(IEnumerable<ConversationGap> gaps, Func<DateTimeOffset, int> pieceOf)
	{
		List<ConversationGap>? run = null;
		var runEnd = DateTimeOffset.MinValue;
		var runPiece = -1;
		foreach (var gap in gaps.Where(g => g.EndedAt > g.StartedAt).OrderBy(g => g.StartedAt))
		{
			var piece = pieceOf(gap.StartedAt);
			if (run is not null && piece == runPiece && gap.StartedAt <= runEnd.AddSeconds(CollapseSeconds))
			{
				run.Add(gap);
				runEnd = gap.EndedAt > runEnd ? gap.EndedAt : runEnd;
				continue;
			}

			if (run is not null)
			{
				yield return run;
			}

			run = [gap];
			runEnd = gap.EndedAt;
			runPiece = piece;
		}

		if (run is not null)
		{
			yield return run;
		}
	}

	private static double Union(IEnumerable<(DateTimeOffset Start, DateTimeOffset End)> spans)
	{
		var total = 0.0;
		var cursor = DateTimeOffset.MinValue;
		foreach (var (start, end) in spans.Where(s => s.End > s.Start).OrderBy(s => s.Start))
		{
			var from = start > cursor ? start : cursor;
			if (end > from)
			{
				total += (end - from).TotalSeconds;
			}

			cursor = end > cursor ? end : cursor;
		}

		return total;
	}
}
