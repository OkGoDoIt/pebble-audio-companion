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
}

/// <summary>
/// The OAuth scopes the archive understands.
/// </summary>
public static class ArchiveScopes
{
	public const string Read = "archive:read";

	public const string Write = "archive:write";

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
}
