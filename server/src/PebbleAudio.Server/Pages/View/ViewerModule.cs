using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Mcp;
using PebbleAudio.Server.Pages.View;

// In the root namespace, so Program.cs needs only its two calls.
namespace PebbleAudio.Server;

/// <summary>
/// The conversation viewer (<c>/</c>, <c>/c/{id}</c>, <c>/d/{day}</c>, <c>/b/week/{day}</c>, <c>/b/month/{month}</c>, Razor
/// Pages in <c>Pages/View</c>), its clip endpoints, the Apple app-site association that opens those links in the
/// iPhone app, and the MCP Apps widgets that show the same things inside an assistant.
/// </summary>
public static class ViewerModule
{
	/// <summary>The iPhone app and its side-by-side development build.</summary>
	public static readonly string[] AppleAppIds = ["R73F7TNT65.dev.audiocompanion.app", "R73F7TNT65.dev.audiocompanion.app.dev"];

	/// <summary>The paths the app opens instead of Safari: the link code, a conversation, a day, a brief.</summary>
	public static readonly string[] AppLinkPaths = ["/link*", "/c/*", "/d/*", "/b/*"];

	public static JsonSerializerOptions Json { get; } = new(JsonSerializerDefaults.Web)
	{
		DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
	};

	public static IServiceCollection AddViewer(this IServiceCollection services)
	{
		services.AddScoped<ViewerReader>();
		services.AddMcpServer().WithWidgets();
		return services;
	}

	public static IEndpointRouteBuilder MapViewer(this IEndpointRouteBuilder app)
	{
		// Served as is: application/json, no redirect, no sign-in (Apple's CDN fetches it).
		app.MapGet("/.well-known/apple-app-site-association", () => Results.Json(
			new
			{
				applinks = new
				{
					details = new[]
					{
						new
						{
							appIDs = AppleAppIds,
							components = AppLinkPaths.Select(path => new Dictionary<string, string> { ["/"] = path }).ToArray(),
						},
					},
				},
			},
			contentType: "application/json")).AllowAnonymous();

		// The page's clip calls. They answer 401 rather than the cookie's redirect, since a script reads them.
		app.MapPost("/c/{conversationId}/clip", RequestClipAsync).AllowAnonymous();
		app.MapGet("/c/{conversationId}/clip", ClipAroundAsync).AllowAnonymous();
		app.MapGet("/c/{conversationId}/clip/{requestId:guid}", ClipAsync).AllowAnonymous();

		if (app.ServiceProvider.GetRequiredService<IWebHostEnvironment>().IsDevelopment())
		{
			// The composed widget documents, for looking at them in a browser beside a stand-in host.
			app.MapGet("/dev/widgets/{name}.html", (string name, WidgetLibrary widgets) =>
				Widgets.All.Any(w => w.File == name) ? Results.Content(widgets.Html(name), "text/html; charset=utf-8") : Results.NotFound());
		}

		return app;
	}

	public sealed record ClipAsk(int? Start, int? End);

	private static async Task<IResult> RequestClipAsync(
		string conversationId,
		ClipAsk body,
		HttpContext context,
		IAntiforgery antiforgery,
		ViewerReader viewer,
		CancellationToken cancellationToken)
	{
		if (context.User.UserId() is null)
		{
			return Results.Unauthorized();
		}

		if (!await antiforgery.IsRequestValidAsync(context))
		{
			return Results.BadRequest();
		}

		var call = await viewer.BeginAsync(context.User, cancellationToken);
		var conversation = await FindAsync(viewer, call, conversationId, cancellationToken);
		if (conversation is null)
		{
			return Results.NotFound();
		}

		var duration = conversation.EndedAt is { } ended ? (int)Math.Round((ended - conversation.StartedAt).TotalSeconds) : int.MaxValue;
		var from = Math.Clamp(body.Start ?? 0, 0, Math.Max(0, duration - 1));
		var to = Math.Clamp(body.End ?? from + (int)call.Settings.ClipMaxDuration.TotalSeconds, from + 1, duration);
		try
		{
			return Results.Json(await viewer.RequestClipAsync(call, conversation, from, to, cancellationToken), Json);
		}
		catch (ArgumentOutOfRangeException)
		{
			return Results.BadRequest();
		}
	}

	/// <summary>Where the clip around a moment stands, without asking the phone for anything.</summary>
	private static async Task<IResult> ClipAroundAsync(
		string conversationId,
		int? t,
		HttpContext context,
		ViewerReader viewer,
		CancellationToken cancellationToken)
	{
		if (context.User.UserId() is null)
		{
			return Results.Unauthorized();
		}

		var call = await viewer.BeginAsync(context.User, cancellationToken);
		var conversation = await FindAsync(viewer, call, conversationId, cancellationToken);
		if (conversation is null)
		{
			return Results.NotFound();
		}

		var end = conversation.EndedAt ?? call.Now;
		var duration = Math.Max(1, (int)Math.Round((end - conversation.StartedAt).TotalSeconds));
		var moment = Math.Clamp(t ?? 0, 0, duration);
		var (from, to) = ViewerReader.ClipSpan(duration, moment, (int)call.Settings.ClipMaxDuration.TotalSeconds);
		context.Response.Headers.CacheControl = "no-store";
		return Results.Json(await viewer.ClipStateAsync(call, conversation, from, to, moment, cancellationToken), Json);
	}

	private static async Task<IResult> ClipAsync(
		string conversationId,
		Guid requestId,
		HttpContext context,
		ViewerReader viewer,
		CancellationToken cancellationToken)
	{
		if (context.User.UserId() is null)
		{
			return Results.Unauthorized();
		}

		var call = await viewer.BeginAsync(context.User, cancellationToken);
		var conversation = await FindAsync(viewer, call, conversationId, cancellationToken);
		var state = conversation is null ? null : await viewer.ClipRequestAsync(call, conversation, requestId, cancellationToken);
		context.Response.Headers.CacheControl = "no-store";
		return state is null ? Results.NotFound() : Results.Json(state, Json);
	}

	private static Task<Data.Conversation?> FindAsync(ViewerReader viewer, ToolCall call, string id, CancellationToken cancellationToken) =>
		viewer.Conversations(call).SingleOrDefaultAsync(c => c.Id == id, cancellationToken);
}
