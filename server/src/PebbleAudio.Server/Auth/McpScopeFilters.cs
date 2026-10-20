using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// Scope checks on MCP tools. <c>/mcp</c> itself needs <c>archive:read</c> (the endpoint policy); a tool that is not
/// marked read-only also needs <c>archive:write</c>. A read-only connection does not see such tools in
/// <c>tools/list</c>, and calling one answers with an error the model can relay, plus the step-up challenge ChatGPT
/// reads from <c>_meta["mcp/www_authenticate"]</c>. ChatGPT shows its linking UI only when the tool also declares
/// its OAuth scopes (<c>securitySchemes</c>, here in <c>_meta</c>, its back-compat mirror: the SDK's tool has no such
/// field) and the challenge carries both <c>error</c> and <c>error_description</c>.
/// </summary>
public static class McpScopeFilters
{
	public const string WriteNeeded =
		"This assistant can read the archive but not add to it. Reconnect it and allow adding follow-ups and notes.";

	/// <summary>
	/// <c>_meta["securitySchemes"]</c> on every tool: OAuth with <c>archive:read</c>, and <c>archive:write</c> too for one
	/// that is not read-only. Set once, after the SDK has collected the tools.
	/// </summary>
	public static void DeclareSchemes(McpServerOptions options)
	{
		if (options.ToolCollection is not { } tools)
		{
			return;
		}

		foreach (var tool in tools)
		{
			var protocol = tool.ProtocolTool;
			var scopes = new JsonArray(ArchiveScopes.Read);
			if (!IsReadOnly(protocol))
			{
				scopes.Add(ArchiveScopes.Write);
			}

			protocol.Meta ??= [];
			protocol.Meta["securitySchemes"] = new JsonArray(new JsonObject { ["type"] = "oauth2", ["scopes"] = scopes });
		}
	}

	public static void Add(McpServerOptions options, OAuthUrls urls)
	{
		options.Filters.Request.ListToolsFilters.Add(next => async (context, cancellationToken) =>
		{
			var result = await next(context, cancellationToken);
			if (!context.User.HasScope(ArchiveScopes.Write))
			{
				result.Tools = [.. result.Tools.Where(IsReadOnly)];
			}

			return result;
		});

		options.Filters.Request.CallToolFilters.Add(next => async (context, cancellationToken) =>
		{
			if (context.MatchedPrimitive is McpServerTool tool && !IsReadOnly(tool.ProtocolTool) &&
				!context.User.HasScope(ArchiveScopes.Write))
			{
				return new CallToolResult
				{
					IsError = true,
					Content = [new TextContentBlock { Text = WriteNeeded }],
					Meta = new JsonObject
					{
						["mcp/www_authenticate"] =
							$"Bearer error=\"insufficient_scope\", error_description=\"Adding to the archive needs write access\", " +
							$"scope=\"{ArchiveScopes.Read} {ArchiveScopes.Write}\", " +
							$"resource_metadata=\"{urls.ResourceMetadata}\"",
					},
				};
			}

			return await next(context, cancellationToken);
		});
	}

	private static bool IsReadOnly(Tool tool) => tool.Annotations?.ReadOnlyHint == true;
}
