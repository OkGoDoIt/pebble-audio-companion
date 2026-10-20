using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// Names shared by the authentication pieces.
/// </summary>
public static class ArchiveAuth
{
	/// <summary>
	/// The bearer-token scheme. The MCP SDK's authentication handler forwards authentication to a scheme with
	/// exactly this name and keeps the 401 challenge (with <c>resource_metadata</c>) for itself.
	/// </summary>
	public const string BearerScheme = "Bearer";

	/// <summary>
	/// The policy on <c>/mcp</c>: a valid bearer token with the read scope.
	/// </summary>
	public const string McpPolicy = "Mcp";

	public const string ScopeClaim = "scope";

	public const string TokenIdClaim = "pebbleaudio:token_id";

	public const string ClientNameClaim = "pebbleaudio:client";

	/// <summary>The OAuth connection (grant) an <c>oat_</c> token belongs to.</summary>
	public const string GrantIdClaim = "pebbleaudio:grant_id";
}

/// <summary>
/// The OAuth scopes the archive understands.
/// </summary>
public static class ArchiveScopes
{
	public const string Read = "archive:read";

	public const string Write = "archive:write";

	/// <summary>Asks for a refresh token. Every grant gets one anyway; it is accepted and listed for clients that look.</summary>
	public const string OfflineAccess = "offline_access";

	public static IReadOnlyList<string> For(TokenAccess access) => access switch
	{
		TokenAccess.Read => [Read],
		TokenAccess.ReadWrite => [Read, Write],
	};

	public static string Describe(TokenAccess access) => access switch
	{
		TokenAccess.Read => "Read only",
		TokenAccess.ReadWrite => "Read and write",
	};

	/// <summary>
	/// How the admin area labels a set of granted scopes.
	/// </summary>
	public static string Describe(IEnumerable<string> scopes) =>
		scopes.Contains(Write) ? Describe(TokenAccess.ReadWrite) : Describe(TokenAccess.Read);

	/// <summary>
	/// What the consent page says a scope lets an app do, or null for one it does not mention.
	/// </summary>
	public static string? Explain(string scope) => scope switch
	{
		Read => "Read your conversations, transcripts, day recaps, briefs, follow-ups, and notes",
		Write => "Add and update follow-ups, and add notes",
		_ => null,
	};
}
