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
		foreach (var item in transcript.Items.OrderBy(i => i.At))
		{
			if (!Add(Line(item, zone)))
			{
				Add("…");
				return new Rendered(text.ToString().TrimEnd(), true, item.At);
			}
		}

		return new Rendered(text.ToString().TrimEnd(), false, null);
	}

	/// <summary><c>[10:05:12] Sam: words</c>, or <c>[10:09–10:10] (lost audio, watch)</c>.</summary>
	public static string Line(TranscriptItem item, TimeZoneInfo zone)
	{
		var at = Days.Local(item.At, zone);
		var span = item.EndAt is { } endAt ? $"[{at:HH:mm}–{Days.Local(endAt, zone):HH:mm}]" : $"[{at:HH:mm}]";
		return item.Kind switch
		{
			TranscriptItemKind.Turn =>
				$"[{at:HH:mm:ss}] {item.Name ?? (item.Speaker is { Length: > 0 } speaker ? $"Speaker {speaker}" : "Someone")}: {item.Text}" +
				(item.Confidence < LowConfidence ? " (low confidence)" : ""),
			TranscriptItemKind.Quiet => $"{span} (quiet)",
			TranscriptItemKind.Lost => $"{span} (lost audio, {item.Origin ?? "unknown"})",
			TranscriptItemKind.Masked => $"{span} ({item.Descriptor ?? "music"})",
		};
	}
}
