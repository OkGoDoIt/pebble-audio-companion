using System.Text.Json.Serialization;
using Microsoft.Extensions.Options;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// The OAuth 2.1 authorization server's fixed values. Business numbers (token lifetimes) are settings.
/// </summary>
public static class OAuthServer
{
	public const string AccessTokenPrefix = "oat_";

	public const string RefreshTokenPrefix = "ort_";

	/// <summary>Client ids from dynamic registration. They never start with <c>https://</c>, which means CIMD.</summary>
	public const string RegisteredClientPrefix = "dcr_";

	/// <summary>How long an authorization code can be exchanged.</summary>
	public static readonly TimeSpan CodeLifetime = TimeSpan.FromSeconds(60);

	/// <summary>
	/// A rotated refresh token presented again within this long gets a fresh pair instead of disconnecting the app:
	/// ChatGPT and Claude both race their own refreshes. After it, a reused token disconnects the whole grant.
	/// </summary>
	public static readonly TimeSpan RefreshReuseAllowance = TimeSpan.FromSeconds(60);

	/// <summary>A registered app that never connected is deleted after this long.</summary>
	public static readonly TimeSpan UnusedRegistrationLifetime = TimeSpan.FromDays(7);

	public static IReadOnlyList<string> ScopesSupported { get; } = [ArchiveScopes.Read, ArchiveScopes.Write, ArchiveScopes.OfflineAccess];
}

/// <summary>
/// Every URL the authorization server and the protected resource publish, built from <c>PebbleAudio:PublicOrigin</c>
/// and never from the request's host. The issuer is that origin string byte for byte.
/// </summary>
public sealed class OAuthUrls(IOptions<PebbleAudioOptions> options)
{
	public string Issuer => options.Value.PublicOrigin;

	/// <summary>The MCP endpoint: the RFC 8707 resource, and the audience of every access token.</summary>
	public string Resource => $"{Issuer}/mcp";

	public string ResourceMetadata => $"{Issuer}/.well-known/oauth-protected-resource/mcp";

	public string AuthorizationEndpoint => $"{Issuer}/oauth/authorize";

	public string TokenEndpoint => $"{Issuer}/oauth/token";

	public string RegistrationEndpoint => $"{Issuer}/oauth/register";

	public string RevocationEndpoint => $"{Issuer}/oauth/revoke";

	/// <summary>
	/// Whether two RFC 8707 resource URLs name the same resource: compared in canonical form (scheme and host in lower
	/// case, no default port, no trailing slash), as clients may send <c>…/mcp/</c> or an upper-case host. Tokens are
	/// still issued for the configured spelling.
	/// </summary>
	public static bool SameResource(string? a, string? b) =>
		CanonicalResource(a) is { } left && left == CanonicalResource(b);

	private static string? CanonicalResource(string? value)
	{
		if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Fragment.Length > 0)
		{
			return null;
		}

		var path = uri.AbsolutePath.Length > 1 && uri.AbsolutePath.EndsWith('/') ? uri.AbsolutePath[..^1] : uri.AbsolutePath;
		var port = uri.IsDefaultPort ? "" : $":{uri.Port}";
		return $"{uri.Scheme}://{uri.IdnHost}{port}{(path == "/" ? "" : path)}{uri.Query}";
	}
}

/// <summary>
/// <c>GET /.well-known/oauth-authorization-server</c> (RFC 8414). No OpenID Connect: advertising <c>openid</c>,
/// <c>email</c>, or <c>profile</c> would make ChatGPT ask for them.
/// </summary>
public sealed record AuthorizationServerMetadata(
	[property: JsonPropertyName("issuer")] string Issuer,
	[property: JsonPropertyName("authorization_endpoint")] string AuthorizationEndpoint,
	[property: JsonPropertyName("token_endpoint")] string TokenEndpoint,
	[property: JsonPropertyName("registration_endpoint")] string RegistrationEndpoint,
	[property: JsonPropertyName("revocation_endpoint")] string RevocationEndpoint,
	[property: JsonPropertyName("scopes_supported")] IReadOnlyList<string> ScopesSupported,
	[property: JsonPropertyName("response_types_supported")] IReadOnlyList<string> ResponseTypesSupported,
	[property: JsonPropertyName("response_modes_supported")] IReadOnlyList<string> ResponseModesSupported,
	[property: JsonPropertyName("grant_types_supported")] IReadOnlyList<string> GrantTypesSupported,
	[property: JsonPropertyName("code_challenge_methods_supported")] IReadOnlyList<string> CodeChallengeMethodsSupported,
	[property: JsonPropertyName("token_endpoint_auth_methods_supported")] IReadOnlyList<string> TokenEndpointAuthMethodsSupported,
	[property: JsonPropertyName("revocation_endpoint_auth_methods_supported")] IReadOnlyList<string> RevocationEndpointAuthMethodsSupported,
	[property: JsonPropertyName("client_id_metadata_document_supported")] bool ClientIdMetadataDocumentSupported,
	[property: JsonPropertyName("authorization_response_iss_parameter_supported")] bool AuthorizationResponseIssParameterSupported)
{
	public static AuthorizationServerMetadata For(OAuthUrls urls) => new(
		urls.Issuer,
		urls.AuthorizationEndpoint,
		urls.TokenEndpoint,
		urls.RegistrationEndpoint,
		urls.RevocationEndpoint,
		OAuthServer.ScopesSupported,
		["code"],
		["query"],
		["authorization_code", "refresh_token"],
		["S256"],
		["none"],
		["none"],
		ClientIdMetadataDocumentSupported: true,
		AuthorizationResponseIssParameterSupported: true);
}
