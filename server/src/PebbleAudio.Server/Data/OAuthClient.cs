namespace PebbleAudio.Server.Data;

/// <summary>
/// An app that signs in to the archive with OAuth: one that registered itself (RFC 7591), or one whose client id is
/// the https URL of its metadata document (CIMD). A metadata-document client gets a row when it is first allowed,
/// and the row keeps what the last valid document said, for when a later fetch fails.
/// </summary>
public sealed class OAuthClient
{
	public Guid Id { get; set; }

	/// <summary>The OAuth <c>client_id</c>: <c>dcr_…</c> for a registered app, an https URL for a metadata document.</summary>
	public string ClientId { get; set; } = "";

	public OAuthClientKind Kind { get; set; }

	/// <summary>The name the app gives itself, for example <c>ChatGPT</c>.</summary>
	public string Name { get; set; } = "";

	public string? ClientUri { get; set; }

	public string? LogoUri { get; set; }

	/// <summary>Where sign-in may send the person back to. Loopback entries match any port.</summary>
	public List<string> RedirectUris { get; set; } = [];

	/// <summary>When the stored copy of the metadata was last saved (metadata-document clients only).</summary>
	public DateTimeOffset? MetadataFetchedAt { get; set; }

	public DateTimeOffset CreatedAt { get; set; }

	public DateTimeOffset? LastUsedAt { get; set; }

	public List<OAuthGrant> Grants { get; set; } = [];
}
