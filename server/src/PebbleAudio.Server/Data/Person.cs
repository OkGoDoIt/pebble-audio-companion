namespace PebbleAudio.Server.Data;

/// <summary>
/// A person the app knows by name.
/// </summary>
public sealed class Person : SyncedRecord
{
	public string Id { get; set; } = "";

	public string Name { get; set; } = "";
}
