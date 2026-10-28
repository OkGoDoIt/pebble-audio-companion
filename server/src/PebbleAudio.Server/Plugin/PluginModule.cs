using System.Globalization;
using System.Security.Claims;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Plugin;
using PebbleAudio.Server.Sync;

// In the root namespace, so Program.cs needs only its two calls.
namespace PebbleAudio.Server;

/// <summary>
/// The Pebble plugin's server half (pebble-plugin/README.md, "Server endpoints"): <c>POST /plugin/link</c> exchanges
/// the connect page's code for a read-only personal token, and <c>GET /plugin/status</c> and <c>GET /plugin/today</c>
/// answer that token with JSON. Only personal tokens (<c>pat_…</c>) with <c>archive:read</c> open them: an OAuth
/// token's audience is <c>/mcp</c>, and a phone's device token opens <c>/sync/*</c> only.
/// </summary>
public static class PluginModule
{
	public const string Policy = "Plugin";

	public static IServiceCollection AddPebblePlugin(this IServiceCollection services)
	{
		services.AddAuthorizationBuilder()
			.AddPolicy(Policy, policy => policy
				.AddAuthenticationSchemes(ArchiveAuth.BearerScheme)
				.RequireAuthenticatedUser()
				.RequireClaim(ArchiveAuth.ScopeClaim, ArchiveScopes.Read)
				.RequireClaim(ArchiveAuth.TokenIdClaim));
		services.AddScoped<PluginLinkService>();
		services.AddScoped<PluginReader>();
		return services;
	}

	public static IEndpointRouteBuilder MapPebblePlugin(this IEndpointRouteBuilder app)
	{
		var plugin = app.MapGroup("/plugin").AddEndpointFilter(async (context, next) =>
		{
			// Per person, and the link answer carries a token: nothing here is ever cached.
			context.HttpContext.Response.Headers.CacheControl = "no-store";
			return await next(context);
		});
		plugin.MapPost("/link", LinkAsync).AllowAnonymous();
		plugin.MapGet("/status", StatusAsync).RequireAuthorization(Policy);
		plugin.MapGet("/today", TodayAsync).RequireAuthorization(Policy);
		return app;
	}

	/// <summary>
	/// The code from <c>/connect/pebble-plugin</c> for a token, <c>201 { "token": "pat_…" }</c>. Wrong codes count against
	/// the address as wrong phone codes do, and the same limit answers 429.
	/// </summary>
	private static async Task<IResult> LinkAsync(
		HttpContext context,
		PluginLinkRequest? body,
		PluginLinkService links,
		LinkAttemptLimiter limiter,
		CancellationToken cancellationToken)
	{
		var address = context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
		if (limiter.IsBlocked(address))
		{
			context.Response.Headers.RetryAfter = ((int)LinkAttemptLimiter.Window.TotalSeconds).ToString(CultureInfo.InvariantCulture);
			return Error(StatusCodes.Status429TooManyRequests, "Too many wrong codes. Try again in a few minutes.");
		}

		var token = await links.ExchangeAsync(body?.Code, cancellationToken);
		if (token is null)
		{
			limiter.RecordFailure(address);
			return Error(StatusCodes.Status409Conflict, "That code is not valid. Codes last ten minutes and work once.");
		}

		return Results.Json(new PluginLinkResponse(token), SyncJson.Options, statusCode: StatusCodes.Status201Created);
	}

	private static async Task<IResult> StatusAsync(ClaimsPrincipal user, PluginReader reader, CancellationToken cancellationToken)
	{
		var status = await reader.StatusAsync(Caller(user), cancellationToken);
		return status is null
			? Error(StatusCodes.Status404NotFound, "No watch status has arrived from a linked phone yet.")
			: Results.Json(status, SyncJson.Options);
	}

	private static async Task<IResult> TodayAsync(ClaimsPrincipal user, PluginReader reader, CancellationToken cancellationToken) =>
		Results.Json(await reader.TodayAsync(user, cancellationToken), SyncJson.Options);

	private static Guid Caller(ClaimsPrincipal user) =>
		user.UserId() ?? throw new InvalidOperationException("A plugin request reached its handler without a user.");

	private static IResult Error(int status, string message) =>
		Results.Json(new { error = message }, SyncJson.Options, statusCode: status);

	internal sealed record PluginLinkRequest(string? Code);

	internal sealed record PluginLinkResponse(string Token);
}
