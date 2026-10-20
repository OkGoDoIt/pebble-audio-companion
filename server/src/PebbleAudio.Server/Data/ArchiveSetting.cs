namespace PebbleAudio.Server.Data;

/// <summary>
/// A setting that differs from its default (see <c>Settings/</c>). Stored in the <c>Settings</c> table.
/// </summary>
public sealed class ArchiveSetting
{
	public string Key { get; set; } = "";

	public string Value { get; set; } = "";

	public DateTimeOffset UpdatedAt { get; set; }
}
