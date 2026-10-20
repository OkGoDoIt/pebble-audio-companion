using System.Globalization;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// Authenticates <c>Authorization: Bearer …</c> on <c>/mcp</c>: personal tokens (<c>pat_…</c>, the ApiTokens table)
/// and OAuth access tokens (<c>oat_…</c>, whose audience must be this server's <c>/mcp</c> URL). Either way the
/// principal carries the user id, the client's name, and one <c>scope</c> claim per granted scope.
/// </summary>
public sealed class BearerTokenHandler(
	IOptionsMonitor<AuthenticationSchemeOptions> options,
	ILoggerFactory logger,
	UrlEncoder encoder,
	ApiTokenService tokens,
	OAuthTokenService oauth)
	: AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
	private const string BearerPrefix = "Bearer ";

	protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
	{
		var header = Request.Headers.Authorization.ToString();
		if (!header.StartsWith(BearerPrefix, StringComparison.OrdinalIgnoreCase))
		{
			return AuthenticateResult.NoResult();
		}

		var secret = header[BearerPrefix.Length..].Trim();
		if (secret.StartsWith(OAuthServer.AccessTokenPrefix, StringComparison.Ordinal))
		{
			return await AuthenticateOAuthAsync(secret);
		}

		var token = await tokens.FindActiveAsync(secret, Context.RequestAborted);
		if (token is null)
		{
			return AuthenticateResult.Fail("The token is unknown or revoked.");
		}

		var identity = new ClaimsIdentity(Scheme.Name);
		identity.AddClaim(new Claim(ClaimTypes.NameIdentifier, token.UserId.ToString()));
		identity.AddClaim(new Claim(ArchiveAuth.TokenIdClaim, token.Id.ToString()));
		identity.AddClaim(new Claim(ArchiveAuth.ClientNameClaim, token.Name));
		foreach (var scope in ArchiveScopes.For(token.Access))
		{
			identity.AddClaim(new Claim(ArchiveAuth.ScopeClaim, scope));
		}

		return AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name));
	}

	private async Task<AuthenticateResult> AuthenticateOAuthAsync(string secret)
	{
		var access = await oauth.FindAccessAsync(secret, Context.RequestAborted);
		if (access is null)
		{
			return AuthenticateResult.Fail("The token is unknown, expired, revoked, or for another resource.");
		}

		var identity = new ClaimsIdentity(Scheme.Name);
		identity.AddClaim(new Claim(ClaimTypes.NameIdentifier, access.UserId.ToString()));
		identity.AddClaim(new Claim(ArchiveAuth.GrantIdClaim, access.GrantId.ToString()));
		identity.AddClaim(new Claim(ArchiveAuth.ClientNameClaim, access.DisplayName));
		foreach (var scope in access.Scopes)
		{
			identity.AddClaim(new Claim(ArchiveAuth.ScopeClaim, scope));
		}

		return AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name));
	}
}

/// <summary>
/// Reads the archive's claims back off an authenticated principal.
/// </summary>
public static class ArchivePrincipal
{
	/// <summary>
	/// True when the caller was granted <paramref name="scope"/>, for example <see cref="ArchiveScopes.Write"/>.
	/// </summary>
	public static bool HasScope(this ClaimsPrincipal? principal, string scope) =>
		principal?.HasClaim(ArchiveAuth.ScopeClaim, scope) == true;

	public static Guid? GrantId(this ClaimsPrincipal? principal) =>
		Guid.TryParse(principal?.FindFirstValue(ArchiveAuth.GrantIdClaim), CultureInfo.InvariantCulture, out var id)
			? id
			: null;

	public static Guid? UserId(this ClaimsPrincipal? principal) =>
		Guid.TryParse(principal?.FindFirstValue(ClaimTypes.NameIdentifier), CultureInfo.InvariantCulture, out var id)
			? id
			: null;

	public static Guid? TokenId(this ClaimsPrincipal? principal) =>
		Guid.TryParse(principal?.FindFirstValue(ArchiveAuth.TokenIdClaim), CultureInfo.InvariantCulture, out var id)
			? id
			: null;

	public static string ClientName(this ClaimsPrincipal? principal) =>
		principal?.FindFirstValue(ArchiveAuth.ClientNameClaim) ?? "unknown client";
}
