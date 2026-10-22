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

	public static string ToWire(this PhoneRequestState state) => state switch
	{
		PhoneRequestState.Pending => "pending",
		PhoneRequestState.Done => "done",
		PhoneRequestState.Failed => "failed",
		PhoneRequestState.Unavailable => "unavailable",
		PhoneRequestState.Expired => "expired",
	};

	public static string ToWire(this ConversationState state) => state switch
	{
		ConversationState.Live => "live",
		ConversationState.Closed => "closed",
	};

	public static string ToWire(this ContentKind kind) => kind switch
	{
		ContentKind.Conversation => "conversation",
		ContentKind.NoConversation => "noConversation",
	};

	public static string ToWire(this GapKind kind) => kind switch
	{
		GapKind.Quiet => "quiet",
		GapKind.Lost => "lost",
	};

	public static string ToWire(this TranscriptItemKind kind) => kind switch
	{
		TranscriptItemKind.Turn => "turn",
		TranscriptItemKind.Quiet => "quiet",
		TranscriptItemKind.Lost => "lost",
		TranscriptItemKind.Masked => "masked",
	};

	public static string ToWire(this CoverageKind kind) => kind switch
	{
		CoverageKind.Recorded => "recorded",
		CoverageKind.Quiet => "quiet",
		CoverageKind.Missing => "missing",
		CoverageKind.Paused => "paused",
		CoverageKind.Off => "off",
	};

	public static string ToWire(this BriefKind kind) => kind switch
	{
		BriefKind.Week => "week",
		BriefKind.Month => "month",
	};

	public static string ToWire(this ContentOrigin origin) => origin switch
	{
		ContentOrigin.Ai => "ai",
		ContentOrigin.User => "user",
		ContentOrigin.Assistant => "assistant",
	};

	public static string ToWire(this FollowUpStage stage) => stage switch
	{
		FollowUpStage.Suggested => "suggested",
		FollowUpStage.Reminder => "reminder",
		FollowUpStage.Skipped => "skipped",
	};

	public static string ToWire(this SharingScopeKind kind) => kind switch
	{
		SharingScopeKind.All => "all",
		SharingScopeKind.Since => "since",
		SharingScopeKind.LastDays => "lastDays",
	};

	public static bool TryParse(string? value, out SharingScopeKind kind) => TryParse(value, ToWire, out kind);

	public static bool TryParse(string? value, out SyncKind kind) => TryParse(value, ToWire, out kind);

	public static bool TryParse(string? value, out SyncOp op) => TryParse(value, ToWire, out op);

	public static bool TryParse(string? value, out PhoneRequestState state) => TryParse(value, ToWire, out state);

	public static bool TryParse(string? value, out ConversationState state) => TryParse(value, ToWire, out state);

	public static bool TryParse(string? value, out ContentKind kind) => TryParse(value, ToWire, out kind);

	public static bool TryParse(string? value, out GapKind kind) => TryParse(value, ToWire, out kind);

	public static bool TryParse(string? value, out TranscriptItemKind kind) => TryParse(value, ToWire, out kind);

	public static bool TryParse(string? value, out CoverageKind kind) => TryParse(value, ToWire, out kind);

	public static bool TryParse(string? value, out BriefKind kind) => TryParse(value, ToWire, out kind);

	public static bool TryParse(string? value, out ContentOrigin origin) => TryParse(value, ToWire, out origin);

	public static bool TryParse(string? value, out FollowUpStage stage) => TryParse(value, ToWire, out stage);

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
