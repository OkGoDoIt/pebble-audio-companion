namespace PebbleAudio.Server.Data;

// Every enum is stored as its member name (see ArchiveDbContext.ConfigureConventions) and switched on
// exhaustively: a switch that misses a member is a build error (CS8509 in the project file).

/// <summary>
/// The kinds of entity the phone syncs (sync-protocol.md §2).
/// </summary>
public enum SyncKind
{
	Conversation,
	Transcript,
	Recap,
	Brief,
	FollowUp,
	Note,
	Person,
	Coverage,
	VoiceRevocation,
}

/// <summary>
/// What a sync item does to its entity (sync-protocol.md §2).
/// </summary>
public enum SyncOp
{
	/// <summary>The payload replaces the entity.</summary>
	Upsert,

	/// <summary>The person deleted it in the app; the server deletes it and everything derived from it.</summary>
	Delete,

	/// <summary>The app's retention aged it out; the server keeps it and marks it expired on the phone.</summary>
	Expire,

	/// <summary>Update only transcript speaker identities; preserve all archived words.</summary>
	SpeakerPatch,
}

public enum ConversationState
{
	Live,
	Closed,
}

/// <summary>
/// What a conversation's audio turned out to be. Music, TV, and announcements still sync so days add up.
/// </summary>
public enum ContentKind
{
	Conversation,
	NoConversation,
}

/// <summary>
/// A stretch inside a conversation with no stored audio.
/// </summary>
public enum GapKind
{
	/// <summary>Silence skipped on purpose. Not loss.</summary>
	Quiet,

	/// <summary>Audio that is genuinely missing.</summary>
	Lost,
}

public enum TranscriptItemKind
{
	Turn,
	Quiet,
	Lost,
	Masked,
}

public enum CoverageKind
{
	Recorded,
	Quiet,
	Missing,
	Paused,
	Off,
}

public enum BriefKind
{
	Week,
	Month,
}

/// <summary>
/// Which conversations the server may hold, as the phone set it (sync-protocol.md §5, the sharing scope).
/// </summary>
public enum SharingScopeKind
{
	/// <summary>Everything the phone sends, kept after the phone's own retention ages it out.</summary>
	All,

	/// <summary>Nothing dated before a fixed time ("from today on").</summary>
	Since,

	/// <summary>A rolling window of the last N days, enforced every day.</summary>
	LastDays,
}

/// <summary>
/// Who wrote a follow-up or note: the app's AI, the person, or an assistant through an MCP write tool.
/// </summary>
public enum ContentOrigin
{
	Ai,
	User,
	Assistant,
}

/// <summary>
/// Where a follow-up stands (docs/reminders.md, sync-protocol.md §2.5). A follow-up is something the app noticed that
/// the person might act on; a reminder is one they said yes to or asked for.
/// </summary>
public enum FollowUpStage
{
	/// <summary>Noticed by the app and waiting for the person's review. Not a commitment.</summary>
	Suggested,

	/// <summary>On the person's list: they asked for it or said yes to it. Every row from before stages is one.</summary>
	Reminder,

	/// <summary>The person said no. Kept and findable, on no list.</summary>
	Skipped,
}

/// <summary>
/// Work the server asks the phone to do (sync-protocol.md §4).
/// </summary>
public enum PhoneRequestKind
{
	Clip,
	FollowUpCreate,
	FollowUpUpdate,
	NoteCreate,
}

public enum PhoneRequestState
{
	/// <summary>Waiting for the phone.</summary>
	Pending,

	Done,
	Failed,

	/// <summary>The phone no longer has what was asked for (aged out or deleted).</summary>
	Unavailable,

	/// <summary>The phone did not answer within the request's time to live.</summary>
	Expired,
}

public enum ClipStatus
{
	/// <summary>Requested; waiting for the phone to upload the audio.</summary>
	Waiting,

	/// <summary>Uploaded; waiting for the transcode job.</summary>
	Received,

	Ready,
	Failed,

	/// <summary>The phone no longer has the audio.</summary>
	Unavailable,
}

public enum JobState
{
	Pending,
	Running,
	Succeeded,

	/// <summary>Failed on every allowed attempt and set aside.</summary>
	DeadLettered,
}

/// <summary>
/// What a bearer token may do.
/// </summary>
public enum TokenAccess
{
	Read,
	ReadWrite,
}

/// <summary>
/// How an OAuth app identified itself.
/// </summary>
public enum OAuthClientKind
{
	/// <summary>Dynamic client registration (RFC 7591); the client id is <c>dcr_…</c>.</summary>
	Registered,

	/// <summary>The client id is the https URL of a client metadata document (CIMD).</summary>
	MetadataDocument,
}

public enum OAuthTokenKind
{
	Access,
	Refresh,
}
