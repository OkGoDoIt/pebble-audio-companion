using Microsoft.AspNetCore.WebUtilities;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// A checked authorization request, ready for the consent page.
/// </summary>
/// <param name="Client">The app asking.</param>
/// <param name="RedirectUri">Where to send the answer, exactly as requested (a loopback one keeps its port).</param>
/// <param name="CodeChallenge">The PKCE S256 challenge.</param>
/// <param name="State">The client's state, echoed verbatim.</param>
/// <param name="Scopes">What the grant will allow; always includes <c>archive:read</c>.</param>
/// <param name="Resource">The MCP URL the tokens will be for.</param>
public sealed record AuthorizationRequest(
	ResolvedClient Client,
	string RedirectUri,
	string CodeChallenge,
	string? State,
	IReadOnlyList<string> Scopes,
	string Resource);

/// <summary>
/// The outcome of checking <c>GET /oauth/authorize</c>.
/// </summary>
public abstract record AuthorizeCheck
{
	/// <summary>The client or its redirect URI cannot be trusted, so the answer is a page here, never a redirect.</summary>
	public sealed record Rejected(string Problem) : AuthorizeCheck;

	/// <summary>Anything else wrong goes back to the client as an error redirect (with <c>iss</c>).</summary>
	public sealed record Failed(string Location) : AuthorizeCheck;

	public sealed record Accepted(AuthorizationRequest Request) : AuthorizeCheck;
}

/// <summary>
/// Checks authorization requests and builds the redirects back to the client. Every redirect, success or error,
/// carries <c>iss</c> (RFC 9207), identical to the metadata's issuer.
/// </summary>
public sealed class OAuthAuthorization(OAuthClientResolver clients, OAuthUrls urls, ILogger<OAuthAuthorization> logger)
{
	public const string UnknownClient =
		"Pebble Audio couldn't identify the app that sent you here. Try connecting again from the app.";

	public const string UnknownRedirect =
		"The app asked to send you somewhere it hasn't registered. Try connecting again from the app.";

	private const int MaxStateLength = 2048;
	private const int ChallengeLength = 43;

	public async Task<AuthorizeCheck> CheckAsync(IQueryCollection query, CancellationToken cancellationToken)
	{
		if (Single(query, "client_id") is not { Length: > 0 } clientId)
		{
			return new AuthorizeCheck.Rejected(UnknownClient);
		}

		var client = await clients.ResolveAsync(clientId, cancellationToken);
		if (client is null)
		{
			logger.LogInformation("An authorization request came from an unknown client {ClientId}.", clientId);
			return new AuthorizeCheck.Rejected(UnknownClient);
		}

		if (Single(query, "redirect_uri") is not { Length: > 0 } redirectUri || !client.AllowsRedirect(redirectUri))
		{
			logger.LogInformation("Client {ClientId} asked for an unregistered redirect URI.", clientId);
			return new AuthorizeCheck.Rejected(UnknownRedirect);
		}

		var state = Single(query, "state");
		if (query["state"].Count > 1 || state is { Length: > MaxStateLength })
		{
			return Fail(redirectUri, "invalid_request", "state is repeated or too long", state: null);
		}

		if (HasRepeats(query))
		{
			return Fail(redirectUri, "invalid_request", "a parameter is repeated", state);
		}

		if (Single(query, "response_type") != "code")
		{
			return Fail(redirectUri, "unsupported_response_type", "only response_type=code is supported", state);
		}

		var challenge = Single(query, "code_challenge");
		if (Single(query, "code_challenge_method") != "S256" || !IsS256Challenge(challenge))
		{
			return Fail(redirectUri, "invalid_request", "PKCE with code_challenge_method=S256 is required", state);
		}

		// RFC 8707: the token's audience. Clients send the MCP URL (in any canonical spelling); older ones send nothing.
		var resource = Single(query, "resource");
		if (resource is not null && !OAuthUrls.SameResource(resource, urls.Resource))
		{
			logger.LogInformation("Client {ClientId} asked for resource {Resource}.", clientId, resource);
			return Fail(redirectUri, "invalid_target", $"the only resource here is {urls.Resource}", state);
		}

		return new AuthorizeCheck.Accepted(new AuthorizationRequest(
			client,
			redirectUri,
			challenge!,
			state,
			GrantedScopes(Single(query, "scope")),
			urls.Resource));
	}

	public string SuccessLocation(AuthorizationRequest request, string code) =>
		Location(request.RedirectUri, new() { ["code"] = code, ["state"] = request.State });

	public string ErrorLocation(string redirectUri, string error, string? description, string? state) =>
		Location(redirectUri, new() { ["error"] = error, ["error_description"] = description, ["state"] = state });

	/// <summary>
	/// The scopes a grant gets for a requested <c>scope</c>: read always, write and offline access when asked.
	/// Anything else (an OpenID scope a client sends out of habit) is left out rather than refused.
	/// </summary>
	public static IReadOnlyList<string> GrantedScopes(string? scope)
	{
		var requested = (scope ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
		List<string> granted = [ArchiveScopes.Read];
		if (requested.Contains(ArchiveScopes.Write))
		{
			granted.Add(ArchiveScopes.Write);
		}

		if (requested.Contains(ArchiveScopes.OfflineAccess))
		{
			granted.Add(ArchiveScopes.OfflineAccess);
		}

		return granted;
	}

	public static bool IsS256Challenge(string? challenge) =>
		challenge is { Length: ChallengeLength } && challenge.All(IsBase64UrlCharacter);

	internal static bool IsBase64UrlCharacter(char c) => char.IsAsciiLetterOrDigit(c) || c is '-' or '_';

	private AuthorizeCheck.Failed Fail(string redirectUri, string error, string description, string? state) =>
		new(ErrorLocation(redirectUri, error, description, state));

	private string Location(string redirectUri, Dictionary<string, string?> parameters)
	{
		parameters["iss"] = urls.Issuer;
		return QueryHelpers.AddQueryString(redirectUri, parameters.Where(p => p.Value is not null)!);
	}

	private static string? Single(IQueryCollection query, string name) =>
		query.TryGetValue(name, out var values) && values.Count == 1 ? values[0] : null;

	private static bool HasRepeats(IQueryCollection query) => query.Any(pair => pair.Value.Count > 1);
}
