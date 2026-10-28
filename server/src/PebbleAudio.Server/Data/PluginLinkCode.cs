namespace PebbleAudio.Server.Data;

/// <summary>
/// A one-time code the Pebble plugin's connect page shows (<c>/connect/pebble-plugin</c>). The plugin's settings page
/// sends it to <c>POST /plugin/link</c> and gets a read-only personal token back. Stored hashed, like a phone's code,
/// in a table of its own so neither kind of code can ever open the other's door.
/// </summary>
public sealed class PluginLinkCode
{
	public Guid Id { get; set; }

	public Guid UserId { get; set; }

	public byte[] CodeHash { get; set; } = [];

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset ExpiresAt { get; set; }

	public DateTimeOffset? UsedAt { get; set; }

	/// <summary>The personal token the code was exchanged for.</summary>
	public Guid? ApiTokenId { get; set; }
}
