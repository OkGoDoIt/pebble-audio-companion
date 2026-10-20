namespace PebbleAudio.Server.Data;

/// <summary>
/// One tool call by an assistant: when, which client, which tool, and which entities it read. The phone shows
/// the latest ones so "what AI read" is truthful.
/// </summary>
public sealed class AiRead
{
	public long Id { get; set; }

	public Guid UserId { get; set; }

	public DateTimeOffset At { get; set; }

	/// <summary>The client's name: a token's name, or later an OAuth client's.</summary>
	public string Client { get; set; } = "";

	public string Tool { get; set; } = "";

	public List<string> EntityIds { get; set; } = [];

	public Guid? ApiTokenId { get; set; }
}
