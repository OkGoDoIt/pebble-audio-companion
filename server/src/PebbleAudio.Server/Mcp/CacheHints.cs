using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace PebbleAudio.Server.Mcp;

/// <summary>
/// The caching hints MCP 2026-07-28 requires on the results of <c>tools/list</c>, <c>prompts/list</c>,
/// <c>resources/list</c>, <c>resources/templates/list</c>, and <c>resources/read</c> (<c>ttlMs</c> and
/// <c>cacheScope</c>; the SDK sets them only on <c>server/discover</c>). A missing <c>cacheScope</c> means public, so
/// without them a shared cache could hand one connection's answer to another.
/// </summary>
/// <remarks>
/// <c>tools/list</c> depends on the connection (a read-only one does not see the write tools) and
/// <c>resources/read</c> is the person's archive: both private. Prompts, resource templates, and the resource list
/// are the same for everyone: public. A handler that sets its own hints keeps them. <c>tools/call</c> carries none:
/// the spec does not make it cacheable.
/// </remarks>
public static class CacheHints
{
	/// <summary>How long a list stays fresh. Lists change only with a deploy.</summary>
	public static readonly TimeSpan ListLifetime = TimeSpan.FromHours(1);

	public static void Add(McpServerOptions options)
	{
		var filters = options.Filters.Request;
		filters.ListToolsFilters.Add(next => async (context, cancellationToken) =>
			Hint(await next(context, cancellationToken), CacheScope.Private, ListLifetime));
		filters.ListPromptsFilters.Add(next => async (context, cancellationToken) =>
			Hint(await next(context, cancellationToken), CacheScope.Public, ListLifetime));
		filters.ListResourcesFilters.Add(next => async (context, cancellationToken) =>
			Hint(await next(context, cancellationToken), CacheScope.Public, ListLifetime));
		filters.ListResourceTemplatesFilters.Add(next => async (context, cancellationToken) =>
			Hint(await next(context, cancellationToken), CacheScope.Public, ListLifetime));
		filters.ReadResourceFilters.Add(next => async (context, cancellationToken) =>
			Hint(await next(context, cancellationToken), CacheScope.Private, TimeSpan.Zero));
	}

	private static T Hint<T>(T result, CacheScope scope, TimeSpan lifetime)
		where T : ICacheableResult
	{
		result.CacheScope ??= scope;
		result.TimeToLive ??= lifetime;
		return result;
	}
}
