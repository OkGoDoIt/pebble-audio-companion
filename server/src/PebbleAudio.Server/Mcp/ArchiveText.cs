using System.Globalization;
using System.Text;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// A conversation as plain text (the <c>text</c> of <c>fetch</c>, and the <c>conversation://</c> resource): title,
/// time, overview, then one line per transcript turn and per quiet, lost, or masked stretch, so the honest markers
/// survive in clients that read only text.
/// </summary>
public static class ArchiveText
{
	/// <summary>Below this the transcriber's words are marked as uncertain.</summary>
	public const double LowConfidence = 0.6;

	private static readonly CultureInfo English = CultureInfo.GetCultureInfo("en-US");

	/// <param name="Text">The rendered text.</param>
	/// <param name="Truncated">True when the budget ended before the transcript did.</param>
	/// <param name="ResumeAt">The first transcript item left out, to continue from.</param>
	public sealed record Rendered(string Text, bool Truncated, DateTimeOffset? ResumeAt);

	public static Rendered Conversation(Conversation c, Transcript? transcript, int budget, bool markdown)
	{
		var zone = LogicalDays.Zone(c.TimeZone);
		var start = Days.Local(c.StartedAt, zone);
		var end = Days.Local(c.EndedAt, zone);
		var title = string.IsNullOrWhiteSpace(c.Title) ? "Untitled conversation" : c.Title.Trim();
		var text = new StringBuilder();
		var used = 0;

		bool Add(string line)
		{
			// The JSON escapes of a newline, a quote, or a backslash take two characters.
			var cost = line.Length + 2 + line.Count(ch => ch is '"' or '\\' or '\n' or '\t');
			if (used + cost > budget)
			{
				return false;
			}

			text.Append(line).Append('\n');
			used += cost;
			return true;
		}

		Add(markdown ? $"# {title}" : title);
		Add($"{start.ToString("dddd, MMMM d, yyyy", English)}, {start:HH:mm}{(end is { } e ? $"–{e:HH:mm}" : "")} ({ArchiveReader.ZoneName(c.TimeZone)})");
		if (c.ContentKind == ContentKind.NoConversation)
		{
			Add($"Not a conversation: {c.ContentDescriptor ?? "other audio"}.");
		}

		if (c.Provisional)
		{
			Add("Still being written: the boundaries may move.");
		}

		var people = c.People.Select(p => p.Name).OfType<string>().Where(n => n.Length > 0).Distinct().ToList();
		if (people.Count > 0)
		{
			Add($"People: {string.Join(", ", people)}");
		}

		if (c.Tags.Count > 0)
		{
			Add($"Tags: {string.Join(", ", c.Tags)}");
		}

		if (!string.IsNullOrWhiteSpace(c.Summary))
		{
			Add("");
			Add(Speak.Cap(c.Summary.Trim(), Math.Max(200, budget / 4))!);
		}

		if (transcript is null)
		{
			Add("");
			Add("No transcript yet.");
			return new Rendered(text.ToString().TrimEnd(), false, null);
		}

		Add("");
		Add(markdown ? "## Transcript" : "Transcript:");
		// The words with the quiet and interrupted rows the phone's transcript shows between them (GapRows).
		foreach (var item in GapRows.Interleave(transcript.Items, c))
		{
			if (!Add(Line(item, zone)))
			{
				Add("…");
				return new Rendered(text.ToString().TrimEnd(), true, item.At);
			}
		}

		return new Rendered(text.ToString().TrimEnd(), false, null);
	}

	/// <summary>
	/// <c>[10:05:12] Sam: words</c>, or a row in the app's words: <c>[10:09–10:23] (audio interrupted for 1 min over 14
	/// min: watch buffer filled while disconnected)</c>, <c>[10:14–10:17] (quiet for 3 min)</c>.
	/// </summary>
	public static string Line(TranscriptItem item, TimeZoneInfo zone)
	{
		var at = Days.Local(item.At, zone);
		var span = item.EndAt is { } endAt ? $"[{at:HH:mm}–{Days.Local(endAt, zone):HH:mm}]" : $"[{at:HH:mm}]";
		return item.Kind switch
		{
			TranscriptItemKind.Turn =>
				$"[{at:HH:mm:ss}] {item.Name ?? (item.Speaker is { Length: > 0 } speaker ? $"Speaker {speaker}" : "Someone")}: {item.Text}" +
				(item.Confidence < LowConfidence ? " (low confidence)" : ""),
			TranscriptItemKind.Quiet or TranscriptItemKind.Lost => $"{span} ({MarkerWords(item, ": ")})",
			TranscriptItemKind.Masked => $"{span} ({item.Descriptor ?? "music"})",
		};
	}

	/// <summary>
	/// A quiet or lost item in the app's words, its cause after <paramref name="separator"/> (the app's own form, with the
	/// cause in parentheses, by default): <c>audio interrupted for 1 min over 14 min (watch buffer filled while
	/// disconnected)</c>. An item from before the phone sent words gets the plainest true ones.
	/// </summary>
	public static string MarkerWords(TranscriptItem item, string? separator = null)
	{
		var seconds = item.EndAt is { } end ? Math.Max(0, (end - item.At).TotalSeconds) : 0;
		var words = item.Label ?? (item.Kind == TranscriptItemKind.Lost
			? GapRows.InterruptionWords(item.MissingMs is { } ms ? ms / 1000.0 : seconds, seconds)
			: $"quiet for {GapRows.AppDuration(seconds)}");
		return item.Cause is { } cause ? separator is null ? $"{words} ({cause})" : $"{words}{separator}{cause}" : words;
	}
}
