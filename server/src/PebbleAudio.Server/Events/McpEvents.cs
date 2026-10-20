#pragma warning disable MCPEXP002 // Custom JSON-RPC methods (McpServerRequestHandler) are experimental in SDK 2.2.0.

using System.Security.Claims;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Jobs;

namespace PebbleAudio.Server.Events;

/// <summary>
/// Wires MCP Events into the MCP server: the three <c>events/*</c> methods, the capability advertisement, the
/// webhook client, and the delivery job.
/// </summary>
public static class McpEvents
{
	/// <summary>The extension id in SEP-3415, which moves the capability under <c>extensions</c>.</summary>
	public const string ExtensionId = "io.modelcontextprotocol/events";

	public static IServiceCollection AddMcpEvents(this IServiceCollection services)
	{
		services.AddScoped<IEventPublisher, EventPublisher>();
		services.AddScoped<McpEventsMethods>();
		services.AddScoped<EventSubscriptions>();
		services.AddSingleton<EventSecrets>();
		services.AddSingleton<WebhookClient>();
		services.AddHttpClient(WebhookClient.HttpClientName)
			.ConfigurePrimaryHttpMessageHandler(PublicHttp.CreateHandler);
		services.AddJobHandler<EventDeliveryJob>(EventDeliveryJob.Type);
		services.AddOptions<McpServerOptions>().Configure<IServiceScopeFactory>(Register);
		return services;
	}

	private static void Register(McpServerOptions options, IServiceScopeFactory scopes)
	{
		options.RequestHandlers ??= [];
		options.RequestHandlers.Add(Method("events/list", scopes, (m, user, p, ct) => m.ListAsync(user, p, ct)));
		options.RequestHandlers.Add(Method("events/subscribe", scopes, (m, user, p, ct) => m.SubscribeAsync(user, p, ct)));
		options.RequestHandlers.Add(Method("events/unsubscribe", scopes, (m, user, p, ct) => m.UnsubscribeAsync(user, p, ct)));

		// The SDK's ServerCapabilities has no events member and server/discover cannot be replaced, so the capability
		// is added to the outgoing result: top-level capabilities.events, which ChatGPT reads, and the SEP-3415
		// extension key, for clients that follow the draft.
		options.Filters.Message.OutgoingFilters.Add(next => async (context, cancellationToken) =>
		{
			if (context.JsonRpcMessage is JsonRpcResponse { Result: JsonObject result } &&
				result["capabilities"] is JsonObject capabilities &&
				(result.ContainsKey("supportedVersions") || result.ContainsKey("protocolVersion")))
			{
				capabilities["events"] ??= new JsonObject();
				if (capabilities["extensions"] is not JsonObject extensions)
				{
					extensions = new JsonObject();
					capabilities["extensions"] = extensions;
				}

				extensions[ExtensionId] ??= new JsonObject();
			}

			await next(context, cancellationToken);
		});
	}

	private static McpServerRequestHandler Method(
		string name,
		IServiceScopeFactory scopes,
		Func<McpEventsMethods, ClaimsPrincipal, JsonObject?, CancellationToken, Task<JsonNode>> invoke) => new()
	{
		Method = name,
		Handler = async (request, cancellationToken) =>
		{
			await using var scope = scopes.CreateAsyncScope();
			var methods = scope.ServiceProvider.GetRequiredService<McpEventsMethods>();
			var user = request.Context?.User ?? new ClaimsPrincipal();
			return await invoke(methods, user, request.Params as JsonObject, cancellationToken);
		},
	};
}

/// <summary>
/// The user's event subscriptions, for the admin area.
/// </summary>
public sealed class EventSubscriptions(ArchiveDbContext db)
{
	public Task<List<EventSubscription>> ListAsync(Guid userId, CancellationToken cancellationToken) =>
		db.EventSubscriptions.AsNoTracking()
			.Where(s => s.UserId == userId)
			.OrderByDescending(s => s.CreatedAt)
			.ToListAsync(cancellationToken);

	public async Task<bool> RemoveAsync(Guid userId, string id, CancellationToken cancellationToken) =>
		await db.EventSubscriptions.Where(s => s.Id == id && s.UserId == userId).ExecuteDeleteAsync(cancellationToken) > 0;
}
