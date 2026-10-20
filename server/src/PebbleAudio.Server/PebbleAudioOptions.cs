namespace PebbleAudio.Server;

/// <summary>
/// Deployment values from the <c>PebbleAudio</c> configuration section (environment variables
/// <c>PebbleAudio__*</c> in production). Business numbers live in <see cref="Settings.ArchiveSettings"/>.
/// </summary>
public sealed class PebbleAudioOptions
{
	public const string SectionName = "PebbleAudio";

	/// <summary>
	/// The public origin with no trailing slash, for example <c>https://pebbleaudio.okgodoit.com</c>. Every
	/// absolute link, the MCP resource and the OAuth issuer derive from it, never from the request's host.
	/// </summary>
	public string PublicOrigin { get; set; } = "";

	/// <summary>
	/// Where clip audio is stored, absolute or relative to the content root; <c>App_Data/clips</c> when unset.
	/// </summary>
	public string? ClipsPath { get; set; }

	/// <summary>
	/// The ffmpeg binary that transcodes clips; <c>ffmpeg</c> on the PATH when unset.
	/// </summary>
	public string? FfmpegPath { get; set; }

	/// <summary>
	/// An optional fixed setup code for the first admin passkey, accepted alongside the one printed in the log.
	/// </summary>
	public string? SetupCode { get; set; }

	/// <summary>
	/// Reads and validates <c>PebbleAudio:PublicOrigin</c>.
	/// </summary>
	public static string ReadPublicOrigin(IConfiguration configuration)
	{
		var value = configuration[$"{SectionName}:{nameof(PublicOrigin)}"];
		if (string.IsNullOrWhiteSpace(value) ||
			!Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
			(uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp) ||
			uri.PathAndQuery != "/")
		{
			throw new InvalidOperationException(
				"PebbleAudio:PublicOrigin must be an absolute http(s) origin such as https://pebbleaudio.okgodoit.com.");
		}

		return uri.GetLeftPart(UriPartial.Authority);
	}
}
