namespace PebbleAudio.Server.Data;

/// <summary>
/// The strings sync-protocol.md uses for the enums that cross the wire.
/// </summary>
public static class WireNames
{
	public static string ToWire(this SyncKind kind) => kind switch
	{
		SyncKind.Conversation => "conversation",
		SyncKind.Transcript => "transcript",
		SyncKind.Recap => "recap",
		SyncKind.Brief => "brief",
		SyncKind.FollowUp => "followUp",
		SyncKind.Note => "note",
		SyncKind.Person => "person",
		SyncKind.Coverage => "coverage",
	};

	public static string ToWire(this SyncOp op) => op switch
	{
		SyncOp.Upsert => "upsert",
		SyncOp.Delete => "delete",
		SyncOp.Expire => "expire",
	};

	public static string ToWire(this PhoneRequestKind kind) => kind switch
	{
		PhoneRequestKind.Clip => "clip",
		PhoneRequestKind.FollowUpCreate => "followUp.create",
		PhoneRequestKind.FollowUpUpdate => "followUp.update",
		PhoneRequestKind.NoteCreate => "note.create",
	};

	public static bool TryParse(string? value, out SyncKind kind) => TryParse(value, ToWire, out kind);

	public static bool TryParse(string? value, out SyncOp op) => TryParse(value, ToWire, out op);

	private static bool TryParse<T>(string? value, Func<T, string> toWire, out T result)
		where T : struct, Enum
	{
		foreach (var candidate in Enum.GetValues<T>())
		{
			if (string.Equals(toWire(candidate), value, StringComparison.Ordinal))
			{
				result = candidate;
				return true;
			}
		}

		result = default;
		return false;
	}
}
