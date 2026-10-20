namespace PebbleAudio.Server.Auth;

/// <summary>
/// CORS for MCP clients that run in a browser (the MCP Inspector, web agents). Only what such a client calls opts in:
/// <c>/mcp</c>, the two metadata documents, and the token, registration, and revocation endpoints. Any origin, never
/// with credentials: these endpoints take bearer tokens, which a browser never attaches by itself, and the admin
/// area's cookie is never honored across origins.
/// </summary>
public static class BrowserClients
{
	public const string CorsPolicy = "mcp-browser-clients";

	public static IServiceCollection AddBrowserClientCors(this IServiceCollection services) =>
		services.AddCors(options => options.AddPolicy(CorsPolicy, policy => policy
			.AllowAnyOrigin()
			.AllowAnyHeader()
			.WithMethods("GET", "POST", "DELETE")
			// The 401's challenge names the metadata document a client signs in from.
			.WithExposedHeaders("WWW-Authenticate", "Mcp-Session-Id", "MCP-Protocol-Version")));
}
