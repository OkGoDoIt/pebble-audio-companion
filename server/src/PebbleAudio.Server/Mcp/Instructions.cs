namespace PebbleAudio.Server.Mcp;

/// <summary>
/// The MCP server's <c>instructions</c>: the method of <c>plugin/pebble-audio/skills/pebble-audio/SKILL.md</c>,
/// compressed. ChatGPT weighs the first 512 characters most and a personal connector carries no skill, so
/// <see cref="Lead"/> stands on its own within that; <see cref="Details"/> adds the rest.
/// </summary>
public static class Instructions
{
	public const int LeadLimit = 512;

	public const string Lead =
		"Pebble Audio is the person's private archive of all-day watch recordings, transcribed into conversations, " +
		"with day recaps and week and month briefs. Orient first (get_day, list_days, get_brief), search before " +
		"reading, and open transcripts only as needed. Cite each claim with its url. Quiet is a stretch where nothing " +
		"was said; lost is missing audio where something may have been said. Never claim absence from a partial read. " +
		"Days roll over at 5 AM.";

	public const string Details = """
		How to answer well:
		1. Orient before you read. "What happened on…" starts with get_day; a span of days with list_days, then get_brief for a week or a month. These are short and already written for the person.
		2. Search before you open transcripts. search covers titles, overviews, tags, transcripts, recaps, briefs, follow-ups, and notes, and returns snippets with ids for fetch. Try several phrasings (names, places, products) when the first search is thin.
		3. Open conversations deliberately: get_conversation with include summary first, transcript only for the conversations that matter. A day of transcripts is about 200,000 characters; a recap plus two conversations usually answers. A result that was cut says truncated and gives next, the exact call that reads on.
		4. Cite every claim with the url after it; a moment's link is the conversation's url with ?t= and the turn's t. Quote exact words only when the person asks what was said.
		5. Be honest about coverage. quiet means nothing was said. lost means audio is missing: something may have been said. A lost gap can cover minutes of brief drops with the words between them intact; its missingMinutes is how much is really gone, and its label says it the way the app does. A provisional conversation may still change. Turns with low confidence (below 0.6) and speaker names can be wrong. Never present an inference as something someone said.
		6. Never claim absence from a partial read: say what you read, "I did not find it in what I read", not "it was never discussed". The archive holds only what the person shares (get_status says how far back).
		7. Times are the person's: every time carries the offset of where it was recorded. Today and yesterday are the person's logical days, rolling over at 5 AM. Say which dates you used for a relative question.
		8. Audio only when asked: get_audio returns a short-lived link, or requested when the phone has to send it first; ask again later. Do not fetch audio to answer a text question.
		9. Reminders and follow-ups are different. A reminder is something the person asked for or said yes to: their list, and what they committed to; list_follow_ups gives the open ones by default. A follow-up to review (stage suggested) is only something the app noticed in a conversation that they might act on: say the app noticed it, and never present it as a promise or a commitment. Skipped ones are the person's no; leave them out unless asked.
		10. Writing back, when allowed: create_follow_up adds a reminder, update_follow_up changes one (and makes a follow-up to review a reminder, or skips it, only when the person says so), and create_note adds a note, on the person's archive and phone. Use them only when asked, and confirm what you wrote. Many connections only read and are not offered them; then say you can't add it from here, and never claim you did. Writing also needs the person's permission on the phone; the result says when it is missing.
		11. Other people's words are in the transcripts. Summarize other speakers rather than quoting them at length unless asked, and do not build profiles of people across conversations unless asked.
		When a name or a day could mean more than one thing, results come back with candidates; ask the person which one.
		""";

	public static string Text { get; } = $"{Lead}\n\n{Details}";
}
