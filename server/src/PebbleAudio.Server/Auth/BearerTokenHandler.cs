using System.Globalization;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// Authenticates <c>Authorization: Bearer pat_…</c> against the ApiTokens table. OAuth access tokens will be
/// checked here too once the authorization server exists (see Auth/README.md).
/// </summary>
public sealed class BearerTokenHandler(
	IOptionsMonitor<AuthenticationSchemeOptions> options,
	ILoggerFactory logger,
	UrlEncoder encoder,
	ApiTokenService tokens)
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
}

/// <summary>
/// Reads the archive's claims back off an authenticated principal.
/// </summary>
public static class ArchivePrincipal
{
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
