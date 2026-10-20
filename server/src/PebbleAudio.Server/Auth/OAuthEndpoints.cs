using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.DependencyInjection.Extensions;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// The OAuth 2.1 authorization server for <c>/mcp</c>: metadata, token, registration, and revocation endpoints.
/// <c>GET /oauth/authorize</c> and its consent page are the Razor Page <c>Pages/OAuth/Authorize</c>.
/// </summary>
public static class OAuthEndpoints
{
	private const int MaxRegistrationBytes = 16 * 1024;

	private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
	{
		DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
	};

	public static IServiceCollection AddOAuthServer(this IServiceCollection services)
	{
		services.TryAddSingleton(TimeProvider.System);
		services.AddSingleton<OAuthUrls>();
		services.AddSingleton<ClientMetadataFetcher>();
		services.AddSingleton<RegistrationLimiter>();
		services.AddScoped<OAuthClientResolver>();
		services.AddScoped<OAuthAuthorization>();
		services.AddScoped<OAuthTokenService>();
		services.AddScoped<OAuthConnections>();
		services.TryAddEnumerable(ServiceDescriptor.Scoped<IConnectedAssistantSource, OAuthConnections>());
		services.AddHttpClient(ClientMetadataFetcher.HttpClientName)
			.ConfigurePrimaryHttpMessageHandler(PublicHttp.CreateHandler);
		services.AddOptions<McpServerOptions>().Configure<OAuthUrls>(McpScopeFilters.Add);
		return services;
	}

	public static IEndpointRouteBuilder MapOAuthServer(this IEndpointRouteBuilder app)
	{
		app.MapGet("/.well-known/oauth-authorization-server", (OAuthUrls urls) =>
			Results.Json(AuthorizationServerMetadata.For(urls), Json));

		var oauth = app.MapGroup("/oauth").DisableAntiforgery();
		oauth.MapPost("/token", TokenAsync);
		oauth.MapPost("/register", RegisterAsync).WithMetadata(new RequestSizeLimitAttribute(MaxRegistrationBytes));
		oauth.MapPost("/revoke", RevokeAsync);
		return app;
	}

	/// <summary>
	/// <c>POST /oauth/token</c>, form-encoded. Public clients only: a client secret or Basic credentials are refused.
	/// </summary>
	private static async Task<IResult> TokenAsync(HttpContext http, OAuthTokenService tokens, CancellationToken cancellationToken)
	{
		NoStore(http.Response);
		if (!http.Request.HasFormContentType)
		{
			return Failure(new TokenError("invalid_request", "send the request as application/x-www-form-urlencoded"));
		}

		var form = await http.Request.ReadFormAsync(cancellationToken);
		if (http.Request.Headers.Authorization.Count > 0 || !string.IsNullOrEmpty(form["client_secret"]))
		{
			return Failure(new TokenError("invalid_client", "this server takes public clients only (token_endpoint_auth_method none)"));
		}

		var result = Value(form, "grant_type") switch
		{
			"authorization_code" => await tokens.ExchangeCodeAsync(
				Value(form, "client_id"),
				Value(form, "code"),
				Value(form, "redirect_uri"),
				Value(form, "code_verifier"),
				Value(form, "resource"),
				cancellationToken),
			"refresh_token" => await tokens.RefreshAsync(
				Value(form, "client_id"),
				Value(form, "refresh_token"),
				Value(form, "scope"),
				Value(form, "resource"),
				cancellationToken),
			null => new OAuthTokenService.Result(null, new TokenError("invalid_request", "grant_type is required")),
			_ => new OAuthTokenService.Result(null, new TokenError("unsupported_grant_type", "use authorization_code or refresh_token")),
		};

		return result.Response is { } response ? Results.Json(response, Json) : Failure(result.Error!);
	}

	/// <summary>
	/// <c>POST /oauth/register</c> (RFC 7591), JSON. Open registration for public clients with https or loopback
	/// redirect URIs; limited per address, and a registration that never connects is deleted after a week.
	/// </summary>
	private static async Task<IResult> RegisterAsync(
		HttpContext http,
		RegistrationLimiter limiter,
		ArchiveDbContext db,
		OAuthTokenService tokens,
		TimeProvider time,
		ILoggerFactory loggers,
		CancellationToken cancellationToken)
	{
		NoStore(http.Response);
		var logger = loggers.CreateLogger(typeof(OAuthEndpoints));
		using var lease = limiter.Acquire(http.Connection.RemoteIpAddress?.ToString() ?? "unknown");
		if (!lease.IsAcquired)
		{
			return Results.Json(
				new TokenError("too_many_requests", "too many registrations from this address; try again later"),
				Json,
				statusCode: StatusCodes.Status429TooManyRequests);
		}

		JsonElement root;
		try
		{
			using var document = await JsonDocument.ParseAsync(http.Request.Body, cancellationToken: cancellationToken);
			root = document.RootElement.Clone();
		}
		catch (JsonException)
		{
			return RegistrationError("invalid_client_metadata", "the body is not JSON");
		}

		if (root.ValueKind != JsonValueKind.Object)
		{
			return RegistrationError("invalid_client_metadata", "the body is not a JSON object");
		}

		if (!root.TryGetProperty("redirect_uris", out var redirects) || redirects.ValueKind != JsonValueKind.Array ||
			redirects.GetArrayLength() == 0 ||
			redirects.EnumerateArray().Any(r => r.ValueKind != JsonValueKind.String || !OAuthRedirects.IsAllowed(r.GetString()!)))
		{
			return RegistrationError("invalid_redirect_uri", "redirect_uris must be https, or http on localhost or 127.0.0.1");
		}

		var method = ClientMetadataDocuments.StringProperty(root, "token_endpoint_auth_method");
		if (method is not null and not "none")
		{
			return RegistrationError("invalid_client_metadata", "token_endpoint_auth_method must be none (public clients only)");
		}

		if (root.TryGetProperty("grant_types", out var grants) &&
			(grants.ValueKind != JsonValueKind.Array || !grants.EnumerateArray().Any(g => g.ValueKind == JsonValueKind.String && g.GetString() == "authorization_code")))
		{
			return RegistrationError("invalid_client_metadata", "grant_types must include authorization_code");
		}

		if (root.TryGetProperty("response_types", out var responses) &&
			(responses.ValueKind != JsonValueKind.Array || !responses.EnumerateArray().Any(r => r.ValueKind == JsonValueKind.String && r.GetString() == "code")))
		{
			return RegistrationError("invalid_client_metadata", "response_types must include code");
		}

		var name = ClientMetadataDocuments.StringProperty(root, "client_name")?.Trim() ?? "";
		if (name.Length > ClientMetadataDocuments.MaxNameLength)
		{
			name = name[..ClientMetadataDocuments.MaxNameLength];
		}

		var now = time.GetUtcNow();
		var client = new OAuthClient
		{
			Id = Guid.CreateVersion7(),
			ClientId = OAuthServer.RegisteredClientPrefix + Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(16)),
			Kind = OAuthClientKind.Registered,
			Name = name,
			ClientUri = ClientMetadataDocuments.HttpsOrNull(ClientMetadataDocuments.StringProperty(root, "client_uri")),
			LogoUri = ClientMetadataDocuments.HttpsOrNull(ClientMetadataDocuments.StringProperty(root, "logo_uri")),
			RedirectUris = [.. redirects.EnumerateArray().Select(r => r.GetString()!)],
			CreatedAt = now,
		};
		db.OAuthClients.Add(client);
		await db.SaveChangesAsync(cancellationToken);
		await tokens.CleanUpAsync(cancellationToken);
		logger.LogInformation(
			"Registered OAuth client {ClientId} ({Name}) for {RedirectHost}.",
			client.ClientId,
			OAuthClientNames.Display(client.Name, client.RedirectUris[0]),
			OAuthRedirects.Host(client.RedirectUris[0]));

		return Results.Json(
			new RegistrationResponse(
				client.ClientId,
				now.ToUnixTimeSeconds(),
				client.Name.Length == 0 ? null : client.Name,
				client.RedirectUris,
				["authorization_code", "refresh_token"],
				["code"],
				"none",
				client.ClientUri,
				client.LogoUri),
			Json,
			statusCode: StatusCodes.Status201Created);
	}

	/// <summary>
	/// <c>POST /oauth/revoke</c> (RFC 7009). Always 200, whether or not the token was known.
	/// </summary>
	private static async Task<IResult> RevokeAsync(HttpContext http, OAuthTokenService tokens, CancellationToken cancellationToken)
	{
		NoStore(http.Response);
		if (!http.Request.HasFormContentType)
		{
			return Failure(new TokenError("invalid_request", "send the request as application/x-www-form-urlencoded"));
		}

		var form = await http.Request.ReadFormAsync(cancellationToken);
		if (Value(form, "token") is not { Length: > 0 } token)
		{
			return Failure(new TokenError("invalid_request", "token is required"));
		}

		await tokens.RevokeAsync(token, Value(form, "client_id"), cancellationToken);
		return Results.Ok();
	}

	private static string? Value(IFormCollection form, string name) =>
		form.TryGetValue(name, out var values) && values.Count == 1 && !string.IsNullOrEmpty(values[0]) ? values[0] : null;

	private static IResult Failure(TokenError error) => Results.Json(error, Json, statusCode: error.StatusCode);

	private static IResult RegistrationError(string error, string description) =>
		Results.Json(new TokenError(error, description), Json, statusCode: StatusCodes.Status400BadRequest);

	private static void NoStore(HttpResponse response)
	{
		response.Headers.CacheControl = "no-store";
		response.Headers.Pragma = "no-cache";
	}

	private sealed record RegistrationResponse(
		[property: JsonPropertyName("client_id")] string ClientId,
		[property: JsonPropertyName("client_id_issued_at")] long ClientIdIssuedAt,
		[property: JsonPropertyName("client_name")] string? ClientName,
		[property: JsonPropertyName("redirect_uris")] IReadOnlyList<string> RedirectUris,
		[property: JsonPropertyName("grant_types")] IReadOnlyList<string> GrantTypes,
		[property: JsonPropertyName("response_types")] IReadOnlyList<string> ResponseTypes,
		[property: JsonPropertyName("token_endpoint_auth_method")] string TokenEndpointAuthMethod,
		[property: JsonPropertyName("client_uri")] string? ClientUri,
		[property: JsonPropertyName("logo_uri")] string? LogoUri);
}

/// <summary>
/// At most 20 dynamic registrations per address per hour. Registration is open, so this keeps one address from
/// filling the table; ChatGPT and Claude register once per connection.
/// </summary>
public sealed class RegistrationLimiter : IDisposable
{
	private readonly PartitionedRateLimiter<string> _limiter = PartitionedRateLimiter.Create<string, string>(address =>
		RateLimitPartition.GetFixedWindowLimiter(address, _ => new FixedWindowRateLimiterOptions
		{
			PermitLimit = 20,
			Window = TimeSpan.FromHours(1),
			QueueLimit = 0,
		}));

	public RateLimitLease Acquire(string address) => _limiter.AttemptAcquire(address);

	public void Dispose() => _limiter.Dispose();
}
