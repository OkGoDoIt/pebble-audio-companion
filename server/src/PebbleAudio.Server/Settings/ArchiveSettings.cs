namespace PebbleAudio.Server.Settings;

/// <summary>
/// The archive's business numbers. Each has a default here and can be changed at <c>/settings</c>;
/// only values that differ from their default are stored.
/// </summary>
public sealed record ArchiveSettings
{
	public static ArchiveSettings Defaults { get; } = new();

	/// <summary>The most items (days, conversations, search results, follow-ups, people, tags) one tool result lists.
	/// Transcript turns are limited by length instead.</summary>
	public int ToolMaxResults { get; init; } = 50;

	/// <summary>
	/// The longest tool result, in characters of JSON. A result carries it twice (as text and as structured content),
	/// so 40,000 keeps the whole under Claude's ~150,000-character result limit, and under Claude Code's limits: it
	/// moves a result over 50,000 characters out of the chat into a file, and stops at 25,000 tokens (timestamp-heavy
	/// transcript JSON runs about 2.5 characters a token).
	/// </summary>
	public int ToolMaxCharacters { get; init; } = 40_000;

	/// <summary>How much of a transcript one read returns when the assistant does not ask for a length.</summary>
	public int TranscriptReadCharacters { get; init; } = 30_000;

	/// <summary>
	/// Only news is announced to subscribed assistants: a recap for a day this recent, a follow-up created this
	/// recently. Older ones arrive when a phone catches up on its history, and wake no one.
	/// </summary>
	public int EventRecentHours { get; init; } = 48;

	/// <summary>The longest audio clip the phone is asked for.</summary>
	public int ClipMaxMinutes { get; init; } = 20;

	/// <summary>How long a request waits for the phone before it counts as not delivered.</summary>
	public int RequestTtlHours { get; init; } = 24;

	/// <summary>How many times a background job runs before it is set aside.</summary>
	public int JobMaxAttempts { get; init; } = 5;

	/// <summary>How long a clip link an assistant is given keeps working.</summary>
	public int ClipLinkMinutes { get; init; } = 60;

	/// <summary>The bit rate clips are served at (AAC, 16 kHz mono). The watch records Speex at 9.8 kbps.</summary>
	public int ClipAudioKbps { get; init; } = 32;

	/// <summary>
	/// How long clip audio stays on the server once it is ready (or failed). After that the file and its request go,
	/// and a new request asks the phone again.
	/// </summary>
	public int ClipKeepDays { get; init; } = 7;

	/// <summary>How long an OAuth access token lasts; the app renews it with its refresh token.</summary>
	public int OAuthAccessTokenMinutes { get; init; } = 60;

	/// <summary>How long an OAuth refresh token lasts. Every renewal starts the period again.</summary>
	public int OAuthRefreshTokenDays { get; init; } = 60;

	/// <summary>How long an MCP Events subscription lasts: the default, and the longest an assistant may ask for.</summary>
	public int EventSubscriptionHours { get; init; } = 72;

	public TimeSpan ClipMaxDuration => TimeSpan.FromMinutes(ClipMaxMinutes);

	public TimeSpan RequestTtl => TimeSpan.FromHours(RequestTtlHours);

	public TimeSpan ClipLinkLifetime => TimeSpan.FromMinutes(ClipLinkMinutes);

	public TimeSpan ClipKeepTime => TimeSpan.FromDays(ClipKeepDays);

	public TimeSpan OAuthAccessTokenLifetime => TimeSpan.FromMinutes(OAuthAccessTokenMinutes);

	public TimeSpan OAuthRefreshTokenLifetime => TimeSpan.FromDays(OAuthRefreshTokenDays);

	public TimeSpan EventSubscriptionLifetime => TimeSpan.FromHours(EventSubscriptionHours);
}

/// <summary>
/// How one setting appears in the admin area and where it is stored.
/// </summary>
/// <param name="Key">The stored key, also the form field name.</param>
/// <param name="Label">What the admin page calls it.</param>
/// <param name="Hint">One line on what it changes.</param>
/// <param name="Unit">Shown after the number.</param>
/// <param name="Min">The smallest allowed value.</param>
/// <param name="Max">The largest allowed value.</param>
/// <param name="Get">Reads it from a settings value.</param>
/// <param name="With">Returns a copy of a settings value with it changed.</param>
public sealed record SettingDefinition(
	string Key,
	string Label,
	string Hint,
	string Unit,
	int Min,
	int Max,
	Func<ArchiveSettings, int> Get,
	Func<ArchiveSettings, int, ArchiveSettings> With)
{
	public int Default => Get(ArchiveSettings.Defaults);

	public static IReadOnlyList<SettingDefinition> All { get; } =
	[
		new(
			nameof(ArchiveSettings.ToolMaxResults),
			"Items per assistant answer",
			"The most days, conversations, search results, or follow-ups one tool result lists.",
			"items",
			1,
			1000,
			s => s.ToolMaxResults,
			(s, v) => s with { ToolMaxResults = v }),
		new(
			nameof(ArchiveSettings.ToolMaxCharacters),
			"Length of an assistant answer",
			"Longer results are cut short and say how to read on. Claude Code moves results over 50,000 characters to a file.",
			"characters",
			2_000,
			1_000_000,
			s => s.ToolMaxCharacters,
			(s, v) => s with { ToolMaxCharacters = v }),
		new(
			nameof(ArchiveSettings.TranscriptReadCharacters),
			"Transcript read",
			"How much of a transcript one read returns unless the assistant asks for more.",
			"characters",
			1_000,
			1_000_000,
			s => s.TranscriptReadCharacters,
			(s, v) => s with { TranscriptReadCharacters = v }),
		new(
			nameof(ArchiveSettings.ClipMaxMinutes),
			"Longest audio clip",
			"The most audio one clip request asks the phone for.",
			"minutes",
			1,
			240,
			s => s.ClipMaxMinutes,
			(s, v) => s with { ClipMaxMinutes = v }),
		new(
			nameof(ArchiveSettings.RequestTtlHours),
			"How long requests wait for the phone",
			"After this, a request counts as not delivered.",
			"hours",
			1,
			720,
			s => s.RequestTtlHours,
			(s, v) => s with { RequestTtlHours = v }),
		new(
			nameof(ArchiveSettings.ClipLinkMinutes),
			"How long a clip link works",
			"A link to a clip that an assistant was given stops working after this.",
			"minutes",
			1,
			1440,
			s => s.ClipLinkMinutes,
			(s, v) => s with { ClipLinkMinutes = v }),
		new(
			nameof(ArchiveSettings.ClipAudioKbps),
			"Clip audio quality",
			"Lower makes smaller files. The watch records at about 10 kbps.",
			"kbps",
			16,
			128,
			s => s.ClipAudioKbps,
			(s, v) => s with { ClipAudioKbps = v }),
		new(
			nameof(ArchiveSettings.ClipKeepDays),
			"How long clips are kept",
			"Clip audio on the server is deleted this long after it is ready.",
			"days",
			1,
			365,
			s => s.ClipKeepDays,
			(s, v) => s with { ClipKeepDays = v }),
		new(
			nameof(ArchiveSettings.JobMaxAttempts),
			"Attempts for background work",
			"A task that keeps failing is set aside after this many tries.",
			"attempts",
			1,
			50,
			s => s.JobMaxAttempts,
			(s, v) => s with { JobMaxAttempts = v }),
		new(
			nameof(ArchiveSettings.OAuthAccessTokenMinutes),
			"Connected app access",
			"How long a connected app's access lasts before it renews it on its own.",
			"minutes",
			5,
			1440,
			s => s.OAuthAccessTokenMinutes,
			(s, v) => s with { OAuthAccessTokenMinutes = v }),
		new(
			nameof(ArchiveSettings.OAuthRefreshTokenDays),
			"Connected app sign-in",
			"An app that goes unused this long has to sign in again.",
			"days",
			1,
			365,
			s => s.OAuthRefreshTokenDays,
			(s, v) => s with { OAuthRefreshTokenDays = v }),
		new(
			nameof(ArchiveSettings.EventSubscriptionHours),
			"Event subscriptions",
			"The longest an assistant's event subscription lasts before it has to renew it.",
			"hours",
			1,
			720,
			s => s.EventSubscriptionHours,
			(s, v) => s with { EventSubscriptionHours = v }),
		new(
			nameof(ArchiveSettings.EventRecentHours),
			"News for event subscriptions",
			"Recaps and follow-ups older than this are not announced, as when a phone sends its history.",
			"hours",
			1,
			720,
			s => s.EventRecentHours,
			(s, v) => s with { EventRecentHours = v }),
	];
}
