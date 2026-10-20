using System.Globalization;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// The numbers sync-protocol.md fixes for both halves. They are the contract, not business settings: the phone
/// builds its batches to the same limits and halves a batch when it gets a 413.
/// </summary>
public static class SyncProtocol
{
	/// <summary>The request header that carries the app's protocol version (§7).</summary>
	public const string VersionHeader = "X-Sync-Protocol";

	/// <summary>The oldest protocol this server still speaks. An app sending less gets a 426.</summary>
	public const int MinimumVersion = 1;

	/// <summary>§3: at most this many items per batch.</summary>
	public const int MaxBatchItems = 200;

	/// <summary>§3: at most this many bytes per batch body.</summary>
	public const long MaxBatchBytes = 8L * 1024 * 1024;

	/// <summary>§1: a link code is this long and lasts this long.</summary>
	public const int LinkCodeLength = 8;

	public static readonly TimeSpan LinkCodeLifetime = TimeSpan.FromMinutes(10);
}

/// <summary>
/// Answers 426 with <c>{ "minimum": n }</c> when a request's <c>X-Sync-Protocol</c> is missing or older than this
/// server speaks (§7), so the app can tell the person to update rather than fail on a changed meaning.
/// </summary>
public sealed class SyncProtocolFilter : IEndpointFilter
{
	public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
	{
		var header = context.HttpContext.Request.Headers[SyncProtocol.VersionHeader].ToString();
		if (!int.TryParse(header, NumberStyles.None, CultureInfo.InvariantCulture, out var version) ||
			version < SyncProtocol.MinimumVersion)
		{
			return Results.Json(
				new { minimum = SyncProtocol.MinimumVersion },
				SyncJson.Options,
				statusCode: StatusCodes.Status426UpgradeRequired);
		}

		return await next(context);
	}
}
