namespace PebbleAudio.Server.Mcp;

/// <summary>
/// The MCP server's <c>instructions</c>. Some clients keep only the first 512 characters, so
/// <see cref="Lead"/> stands on its own and stays within that; <see cref="Details"/> adds the rest.
/// </summary>
public static class Instructions
{
	public const int LeadLimit = 512;

	public const string Lead =
		"Pebble Audio is a private archive of the user's spoken conversations, recorded by a microphone on " +
		"their Pebble watch, transcribed on their iPhone, and mirrored here as text. Start from days and " +
		"briefs (day recaps, weekly and monthly briefs), then open conversations and their transcripts. " +
		"Quiet means silence that was skipped on purpose, not lost audio; only spans marked lost are " +
		"missing. Cite each claim with its conversation id and viewer link.";

	public const string Details = """
		How the archive works:
		- The iPhone is the system of record and syncs here whenever it can, so the latest minutes may not be here yet. get_status shows what the archive holds, the first and last day on record, and when the phone last synced.
		- Times are UTC (RFC 3339). A conversation's day key is the user's logical day, which starts at 5 AM in the conversation's time zone.
		- A conversation is one topic-sized stretch of talk. Its transcript lists turns in time order, with markers for quiet, lost, and masked (music or TV) stretches.
		- Stretches that were music, TV, or announcements are kept and flagged as not a conversation, so a day's time adds up.
		- Results are capped. A result that was cut short says so.
		""";

	public static string Text { get; } = $"{Lead}\n\n{Details}";
}
