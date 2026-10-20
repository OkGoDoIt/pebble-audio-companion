namespace PebbleAudio.Server.Settings;

/// <summary>
/// The archive's business numbers. Each has a default here and can be changed at <c>/admin/settings</c>;
/// only values that differ from their default are stored.
/// </summary>
public sealed record ArchiveSettings
{
	public static ArchiveSettings Defaults { get; } = new();

	/// <summary>The most items (conversations, turns, follow-ups) one tool result lists.</summary>
	public int ToolMaxResults { get; init; } = 50;

	/// <summary>The longest tool result, in characters. Claude Code allows about 25,000 tokens.</summary>
	public int ToolMaxCharacters { get; init; } = 80_000;

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

	public TimeSpan ClipMaxDuration => TimeSpan.FromMinutes(ClipMaxMinutes);

	public TimeSpan RequestTtl => TimeSpan.FromHours(RequestTtlHours);

	public TimeSpan ClipLinkLifetime => TimeSpan.FromMinutes(ClipLinkMinutes);
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
			"The most conversations, turns, or follow-ups one tool result lists.",
			"items",
			1,
			1000,
			s => s.ToolMaxResults,
			(s, v) => s with { ToolMaxResults = v }),
		new(
			nameof(ArchiveSettings.ToolMaxCharacters),
			"Length of an assistant answer",
			"Longer results are cut short and say so.",
			"characters",
			2_000,
			1_000_000,
			s => s.ToolMaxCharacters,
			(s, v) => s with { ToolMaxCharacters = v }),
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
			nameof(ArchiveSettings.JobMaxAttempts),
			"Attempts for background work",
			"A task that keeps failing is set aside after this many tries.",
			"attempts",
			1,
			50,
			s => s.JobMaxAttempts,
			(s, v) => s with { JobMaxAttempts = v }),
	];
}
