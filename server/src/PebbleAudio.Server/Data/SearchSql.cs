namespace PebbleAudio.Server.Data;

/// <summary>
/// The SQL behind full-text search. The initial migration creates <c>pebble_tags_text(text[])</c> before the
/// tables, because a generated column may only call immutable functions and <c>array_to_string</c> is not.
/// </summary>
public static class SearchSql
{
	public const string TextSearchConfig = "english";

	/// <summary>
	/// The conversation's half of the search vector: title (A), tags and summary (B).
	/// </summary>
	public const string ConversationVector = """
		setweight(to_tsvector('english'::regconfig, coalesce("Title", '')), 'A') || setweight(to_tsvector('english'::regconfig, pebble_tags_text("Tags")), 'B') || setweight(to_tsvector('english'::regconfig, coalesce("Summary", '')), 'B')
		""";
}
