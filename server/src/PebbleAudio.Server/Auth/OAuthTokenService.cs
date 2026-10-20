using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Settings;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// A successful token response (RFC 6749 §5.1).
/// </summary>
public sealed record TokenResponse(
	[property: JsonPropertyName("access_token")] string AccessToken,
	[property: JsonPropertyName("token_type")] string TokenType,
	[property: JsonPropertyName("expires_in")] long ExpiresIn,
	[property: JsonPropertyName("refresh_token")] string RefreshToken,
	[property: JsonPropertyName("scope")] string Scope);

/// <summary>
/// A token endpoint error (RFC 6749 §5.2). <c>invalid_client</c> answers 401; the rest answer 400.
/// </summary>
public sealed record TokenError(
	[property: JsonPropertyName("error")] string Error,
	[property: JsonPropertyName("error_description")] string? Description)
{
	[JsonIgnore]
	public int StatusCode => Error == "invalid_client" ? StatusCodes.Status401Unauthorized : StatusCodes.Status400BadRequest;
}

/// <summary>
/// A live OAuth access token, as <c>/mcp</c> sees it.
/// </summary>
public sealed record OAuthAccess(
	Guid GrantId,
	Guid UserId,
	Guid ClientRowId,
	string ClientName,
	string RedirectUri,
	List<string> Scopes,
	string Resource,
	DateTimeOffset? LastUsedAt)
{
	public string DisplayName => OAuthClientNames.Display(ClientName, RedirectUri);
}

/// <summary>
/// Issues and checks OAuth codes and tokens. Everything is opaque random bytes, stored as SHA-256 hashes. A grant
/// is one refresh-token family; deleting it ends every token issued from it.
/// </summary>
public sealed class OAuthTokenService(
	ArchiveDbContext db,
	SettingsService settings,
	OAuthUrls urls,
	TimeProvider time,
	ILogger<OAuthTokenService> logger)
{
	private static readonly TimeSpan UseNoteInterval = TimeSpan.FromMinutes(1);

	/// <summary>
	/// Issues a one-time code for an allowed request, bound to the client, redirect URI, PKCE challenge, resource,
	/// scopes, and user.
	/// </summary>
	public async Task<string> IssueCodeAsync(
		Guid clientRowId,
		Guid userId,
		AuthorizationRequest request,
		CancellationToken cancellationToken)
	{
		var code = NewSecret("");
		var now = time.GetUtcNow();
		db.OAuthAuthorizationCodes.Add(new OAuthAuthorizationCode
		{
			Id = Guid.CreateVersion7(),
			CodeHash = Hash(code),
			OAuthClientId = clientRowId,
			UserId = userId,
			RedirectUri = request.RedirectUri,
			CodeChallenge = request.CodeChallenge,
			Scopes = [.. request.Scopes],
			Resource = request.Resource,
			CreatedAt = now,
			ExpiresAt = now + OAuthServer.CodeLifetime,
		});
		await db.SaveChangesAsync(cancellationToken);
		return code;
	}

	/// <summary>
	/// <c>grant_type=authorization_code</c>: checks the code, its binding, and PKCE, then starts a grant.
	/// </summary>
	public async Task<Result> ExchangeCodeAsync(
		string? clientId,
		string? code,
		string? redirectUri,
		string? codeVerifier,
		string? resource,
		CancellationToken cancellationToken)
	{
		if (clientId is null || code is null || redirectUri is null || codeVerifier is null)
		{
			return Error("invalid_request", "client_id, code, redirect_uri, and code_verifier are required");
		}

		var client = await FindClientAsync(clientId, cancellationToken);
		if (client is null)
		{
			return Error("invalid_client", "unknown client_id");
		}

		var now = time.GetUtcNow();
		var config = await settings.GetAsync(cancellationToken);
		await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);

		var hash = Hash(code);
		var stored = (await db.OAuthAuthorizationCodes
			.FromSql($"""SELECT * FROM "OAuthAuthorizationCodes" WHERE "CodeHash" = {hash} FOR UPDATE""")
			.ToListAsync(cancellationToken))
			.SingleOrDefault();
		if (stored is null || stored.OAuthClientId != client.Id)
		{
			return Error("invalid_grant", "the code is unknown");
		}

		if (stored.RedeemedAt is not null)
		{
			// A code used twice was intercepted, or replayed: end what the first exchange started (RFC 6749 §4.1.2).
			if (stored.GrantId is { } issued)
			{
				await db.OAuthGrants.Where(g => g.Id == issued).ExecuteDeleteAsync(cancellationToken);
			}

			await transaction.CommitAsync(cancellationToken);
			logger.LogWarning("An authorization code for client {ClientId} was presented twice; its grant was ended.", clientId);
			return Error("invalid_grant", "the code was already used");
		}

		if (stored.ExpiresAt <= now)
		{
			return Error("invalid_grant", "the code has expired");
		}

		if (!string.Equals(stored.RedirectUri, redirectUri, StringComparison.Ordinal))
		{
			return Error("invalid_grant", "redirect_uri does not match the authorization request");
		}

		if (!PkceMatches(codeVerifier, stored.CodeChallenge))
		{
			return Error("invalid_grant", "code_verifier does not match the code_challenge");
		}

		if (resource is not null && !OAuthUrls.SameResource(resource, stored.Resource))
		{
			return Error("invalid_target", $"the only resource here is {urls.Resource}");
		}

		var grant = new OAuthGrant
		{
			Id = Guid.CreateVersion7(),
			UserId = stored.UserId,
			OAuthClientId = client.Id,
			Scopes = stored.Scopes,
			Resource = stored.Resource,
			RedirectUri = stored.RedirectUri,
			CreatedAt = now,
			ExpiresAt = now + config.OAuthRefreshTokenLifetime,
		};
		db.OAuthGrants.Add(grant);
		stored.RedeemedAt = now;
		stored.GrantId = grant.Id;
		var response = AddTokenPair(grant, now, config);
		await db.SaveChangesAsync(cancellationToken);
		// Connected: from now on the app keeps its registration, even with no live connection (it reuses its client_id).
		await db.OAuthClients
			.Where(c => c.Id == client.Id)
			.ExecuteUpdateAsync(s => s.SetProperty(c => c.LastUsedAt, now), cancellationToken);
		await transaction.CommitAsync(cancellationToken);

		await CleanUpAsync(cancellationToken);
		return new Result(response, null);
	}

	/// <summary>
	/// <c>grant_type=refresh_token</c>: rotates the refresh token. A rotated token presented again after
	/// <see cref="OAuthServer.RefreshReuseAllowance"/> ends the grant.
	/// </summary>
	public async Task<Result> RefreshAsync(
		string? clientId,
		string? refreshToken,
		string? scope,
		string? resource,
		CancellationToken cancellationToken)
	{
		if (clientId is null || refreshToken is null)
		{
			return Error("invalid_request", "client_id and refresh_token are required");
		}

		var hash = Hash(refreshToken);
		var found = await db.OAuthTokens.AsNoTracking()
			.Where(t => t.TokenHash == hash && t.Kind == OAuthTokenKind.Refresh)
			.Select(t => new { t.Id, t.GrantId })
			.SingleOrDefaultAsync(cancellationToken);
		if (found is null)
		{
			return Error("invalid_grant", "the refresh token is unknown or was revoked");
		}

		var now = time.GetUtcNow();
		var config = await settings.GetAsync(cancellationToken);
		await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);

		// One refresh at a time per grant, so two racing requests see each other's rotation.
		var grant = (await db.OAuthGrants
			.FromSql($"""SELECT * FROM "OAuthGrants" WHERE "Id" = {found.GrantId} FOR UPDATE""")
			.ToListAsync(cancellationToken))
			.SingleOrDefault();
		var token = await db.OAuthTokens.SingleOrDefaultAsync(t => t.Id == found.Id, cancellationToken);
		if (grant is null || token is null)
		{
			return Error("invalid_grant", "the refresh token is unknown or was revoked");
		}

		var client = await db.OAuthClients.AsNoTracking().SingleAsync(c => c.Id == grant.OAuthClientId, cancellationToken);
		if (!string.Equals(client.ClientId, clientId, StringComparison.Ordinal))
		{
			return Error("invalid_grant", "the refresh token was issued to another client");
		}

		if (token.UsedAt is { } usedAt && now - usedAt > OAuthServer.RefreshReuseAllowance)
		{
			await db.OAuthGrants.Where(g => g.Id == grant.Id).ExecuteDeleteAsync(cancellationToken);
			await transaction.CommitAsync(cancellationToken);
			logger.LogWarning(
				"A rotated refresh token for {Client} was used again; the connection was ended.",
				OAuthClientNames.Display(client.Name, grant.RedirectUri));
			return Error("invalid_grant", "the refresh token was already used");
		}

		if (token.ExpiresAt <= now || grant.ExpiresAt <= now)
		{
			return Error("invalid_grant", "the refresh token has expired");
		}

		if (resource is not null && !OAuthUrls.SameResource(resource, grant.Resource))
		{
			return Error("invalid_target", $"the only resource here is {urls.Resource}");
		}

		if (scope is not null &&
			scope.Split(' ', StringSplitOptions.RemoveEmptyEntries).Any(s => !grant.Scopes.Contains(s)))
		{
			return Error("invalid_scope", "a refresh cannot add scopes");
		}

		token.UsedAt ??= now;
		grant.ExpiresAt = now + config.OAuthRefreshTokenLifetime;
		var response = AddTokenPair(grant, now, config);
		await db.SaveChangesAsync(cancellationToken);
		await transaction.CommitAsync(cancellationToken);
		return new Result(response, null);
	}

	/// <summary>
	/// The live access token with this secret, for <c>/mcp</c>; null when it is unknown, expired, revoked, or for
	/// another audience. Notes the grant's last use at most once a minute.
	/// </summary>
	public async Task<OAuthAccess?> FindAccessAsync(string secret, CancellationToken cancellationToken)
	{
		if (!secret.StartsWith(OAuthServer.AccessTokenPrefix, StringComparison.Ordinal))
		{
			return null;
		}

		var hash = Hash(secret);
		var now = time.GetUtcNow();
		var access = await db.OAuthTokens.AsNoTracking()
			.Where(t => t.TokenHash == hash && t.Kind == OAuthTokenKind.Access && t.ExpiresAt > now)
			.Select(t => new OAuthAccess(
				t.GrantId,
				t.Grant.UserId,
				t.Grant.OAuthClientId,
				t.Grant.Client.Name,
				t.Grant.RedirectUri,
				t.Grant.Scopes,
				t.Grant.Resource,
				t.Grant.LastUsedAt))
			.SingleOrDefaultAsync(cancellationToken);

		// The audience is the configured MCP URL, never the request's host.
		if (access is null || !string.Equals(access.Resource, urls.Resource, StringComparison.Ordinal))
		{
			return null;
		}

		if (access.LastUsedAt is null || now - access.LastUsedAt > UseNoteInterval)
		{
			await db.OAuthGrants
				.Where(g => g.Id == access.GrantId)
				.ExecuteUpdateAsync(s => s.SetProperty(g => g.LastUsedAt, now), cancellationToken);
			await db.OAuthClients
				.Where(c => c.Id == access.ClientRowId)
				.ExecuteUpdateAsync(s => s.SetProperty(c => c.LastUsedAt, now), cancellationToken);
		}

		return access;
	}

	/// <summary>
	/// RFC 7009: a refresh token ends its whole grant; an access token ends only itself. Unknown tokens are ignored.
	/// </summary>
	public async Task RevokeAsync(string token, string? clientId, CancellationToken cancellationToken)
	{
		var hash = Hash(token);
		var found = await db.OAuthTokens.AsNoTracking()
			.Where(t => t.TokenHash == hash)
			.Select(t => new { t.Id, t.Kind, t.GrantId, ClientId = t.Grant.Client.ClientId })
			.SingleOrDefaultAsync(cancellationToken);
		if (found is null || (clientId is not null && !string.Equals(found.ClientId, clientId, StringComparison.Ordinal)))
		{
			return;
		}

		switch (found.Kind)
		{
			case OAuthTokenKind.Refresh:
				await db.OAuthGrants.Where(g => g.Id == found.GrantId).ExecuteDeleteAsync(cancellationToken);
				break;
			case OAuthTokenKind.Access:
				await db.OAuthTokens.Where(t => t.Id == found.Id).ExecuteDeleteAsync(cancellationToken);
				break;
		}
	}

	/// <summary>
	/// Deletes what can no longer be used: expired codes and tokens, grants past their refresh lifetime, and
	/// registrations that never connected. A registration that connected once stays: ChatGPT and the CLIs keep their
	/// client_id and come back with it after a disconnect.
	/// </summary>
	public async Task CleanUpAsync(CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		await db.OAuthAuthorizationCodes.Where(c => c.ExpiresAt < now - TimeSpan.FromMinutes(10)).ExecuteDeleteAsync(cancellationToken);
		await db.OAuthTokens.Where(t => t.ExpiresAt < now).ExecuteDeleteAsync(cancellationToken);
		await db.OAuthGrants.Where(g => g.ExpiresAt < now).ExecuteDeleteAsync(cancellationToken);
		var unused = now - OAuthServer.UnusedRegistrationLifetime;
		await db.OAuthClients
			.Where(c => c.Kind == OAuthClientKind.Registered && c.CreatedAt < unused && c.LastUsedAt == null && !c.Grants.Any())
			.ExecuteDeleteAsync(cancellationToken);
	}

	/// <summary>
	/// PKCE S256 (RFC 7636): the verifier is 43 to 128 unreserved characters, and BASE64URL(SHA256(verifier)) is
	/// the challenge.
	/// </summary>
	public static bool PkceMatches(string verifier, string challenge)
	{
		if (verifier.Length is < 43 or > 128 || !verifier.All(c => OAuthAuthorization.IsBase64UrlCharacter(c) || c is '.' or '~'))
		{
			return false;
		}

		var computed = Base64Url.EncodeToString(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
		return CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(computed), Encoding.ASCII.GetBytes(challenge));
	}

	public static byte[] Hash(string secret) => ApiTokenService.Hash(secret);

	private Task<OAuthClient?> FindClientAsync(string clientId, CancellationToken cancellationToken) =>
		db.OAuthClients.AsNoTracking().SingleOrDefaultAsync(c => c.ClientId == clientId, cancellationToken);

	private TokenResponse AddTokenPair(OAuthGrant grant, DateTimeOffset now, ArchiveSettings config)
	{
		var access = NewSecret(OAuthServer.AccessTokenPrefix);
		var refresh = NewSecret(OAuthServer.RefreshTokenPrefix);
		db.OAuthTokens.Add(new OAuthToken
		{
			Id = Guid.CreateVersion7(),
			GrantId = grant.Id,
			Kind = OAuthTokenKind.Access,
			TokenHash = Hash(access),
			CreatedAt = now,
			ExpiresAt = now + config.OAuthAccessTokenLifetime,
		});
		db.OAuthTokens.Add(new OAuthToken
		{
			Id = Guid.CreateVersion7(),
			GrantId = grant.Id,
			Kind = OAuthTokenKind.Refresh,
			TokenHash = Hash(refresh),
			CreatedAt = now,
			ExpiresAt = grant.ExpiresAt,
		});
		return new TokenResponse(
			access,
			"Bearer",
			(long)config.OAuthAccessTokenLifetime.TotalSeconds,
			refresh,
			string.Join(' ', grant.Scopes));
	}

	private static string NewSecret(string prefix) => prefix + Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(32));

	private static Result Error(string error, string description) => new(null, new TokenError(error, description));

	/// <summary>Either a token response or an error.</summary>
	public sealed record Result(TokenResponse? Response, TokenError? Error);
}
