using System.Security.Claims;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Jobs;
using PebbleAudio.Server.Sync;

// In the root namespace, so Program.cs needs only its two calls.
namespace PebbleAudio.Server;

/// <summary>
/// The phone ↔ server sync (docs/sync-protocol.md): linking, the device-token scheme, batches, the request
/// channel, clips, and the account endpoints.
/// </summary>
public static class SyncModule
{
	public static IServiceCollection AddSync(this IServiceCollection services)
	{
		services.AddAuthentication()
			.AddScheme<AuthenticationSchemeOptions, DeviceTokenHandler>(SyncAuth.Scheme, _ => { });
		services.AddAuthorizationBuilder()
			.AddPolicy(SyncAuth.Policy, policy => policy
				.AddAuthenticationSchemes(SyncAuth.Scheme)
				.RequireAuthenticatedUser()
				.RequireClaim(SyncAuth.DeviceIdClaim));

		services.AddSingleton<ClipStorage>();
		services.AddSingleton<Ffmpeg>();
		services.AddSingleton<LinkAttemptLimiter>();
		services.AddScoped<PhoneLinkService>();
		services.AddScoped<BatchApplier>();
		services.AddScoped<PhoneRequestService>();
		services.AddScoped<ClipLinks>();
		services.AddScoped<ArchiveWipe>();
		services.AddScoped<IConnectedAssistants, ConnectedAssistants>();
		services.AddScoped<IConnectedAssistantSource, TokenAssistantSource>();
		services.AddJobHandler<ClipTranscodeJob>(ClipTranscodeJob.Type);
		services.AddScoped<ClipRetention>();
		services.AddScoped<SharingScopes>();
		services.AddScoped<ScopeSweep>();
		services.AddScoped<ScopeSweepSchedule>();
		services.AddJobHandler<ScopeSweepJob>(ScopeSweepJob.Type);
		services.AddHostedService<ScopeSweepScheduler>();
		return services;
	}

	public static IEndpointRouteBuilder MapSync(this IEndpointRouteBuilder app)
	{
		var link = app.MapGroup("/link").AddEndpointFilter<SyncProtocolFilter>();
		link.MapPost("", LinkAsync).AllowAnonymous();
		link.MapDelete("", UnlinkAsync).RequireAuthorization(SyncAuth.Policy);

		var sync = app.MapGroup("/sync")
			.RequireAuthorization(SyncAuth.Policy)
			.AddEndpointFilter<SyncProtocolFilter>();
		sync.MapPut("/batch", BatchAsync);
		sync.MapGet("/requests", RequestsAsync);
		sync.MapPost("/requests/{requestId:guid}/result", ResultAsync);
		sync.MapPut("/clips/{requestId:guid}", ClipUploadAsync);
		sync.MapPost("/wipe", WipeAsync);
		sync.MapGet("/status", StatusAsync);
		sync.MapDelete("/access/{kind}/{id}", RevokeAccessAsync);
		sync.MapGet("/preferences", GetPreferencesAsync);
		sync.MapPut("/preferences", PutPreferencesAsync);

		// The signature is the authorization: a widget or a browser plays the clip without a token.
		app.MapGet("/clips/{clipId:guid}.m4a", ServeClipAsync).AllowAnonymous();
		return app;
	}

	// §1

	private static async Task<IResult> LinkAsync(
		HttpContext context,
		LinkRequest body,
		PhoneLinkService links,
		LinkAttemptLimiter limiter,
		TimeProvider time,
		CancellationToken cancellationToken)
	{
		var address = context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
		if (limiter.IsBlocked(address))
		{
			context.Response.Headers.RetryAfter = ((int)LinkAttemptLimiter.Window.TotalSeconds).ToString(System.Globalization.CultureInfo.InvariantCulture);
			return Error(StatusCodes.Status429TooManyRequests, "Too many wrong codes. Try again in a few minutes.");
		}

		var linked = await links.LinkAsync(body.Code, body.DeviceName, body.AppVersion, body.AppBuild, cancellationToken);
		if (linked is null)
		{
			limiter.RecordFailure(address);
			return Error(StatusCodes.Status409Conflict, "That code is not valid. Codes last ten minutes and work once.");
		}

		return Results.Json(
			new LinkResponse(linked.Device.Id.ToString(), linked.Token, linked.Device.UserId.ToString(), time.GetUtcNow()),
			SyncJson.Options,
			statusCode: StatusCodes.Status201Created);
	}

	/// <summary>Unlinks and deletes the server's copy, ending every assistant's access.</summary>
	private static async Task<IResult> UnlinkAsync(ClaimsPrincipal user, ArchiveWipe wipe, CancellationToken cancellationToken)
	{
		var (userId, deviceId) = Caller(user);
		await wipe.UnlinkAsync(userId, deviceId, cancellationToken);
		return Results.NoContent();
	}

	// §3

	private static async Task<IResult> BatchAsync(HttpContext context, BatchApplier applier, CancellationToken cancellationToken)
	{
		var (userId, deviceId) = Caller(context.User);
		if (context.Request.ContentLength > SyncProtocol.MaxBatchBytes)
		{
			return TooLarge();
		}

		using var buffer = new MemoryStream();
		var chunk = new byte[81920];
		int read;
		while ((read = await context.Request.Body.ReadAsync(chunk, cancellationToken)) > 0)
		{
			if (buffer.Length + read > SyncProtocol.MaxBatchBytes)
			{
				return TooLarge();
			}

			buffer.Write(chunk, 0, read);
		}

		JsonDocument document;
		try
		{
			document = JsonDocument.Parse(buffer.GetBuffer().AsMemory(0, (int)buffer.Length));
		}
		catch (JsonException)
		{
			return Error(StatusCodes.Status400BadRequest, "The batch is not JSON.");
		}

		using (document)
		{
			if (document.RootElement.ValueKind != JsonValueKind.Object ||
				!document.RootElement.TryGetProperty("items", out var items) ||
				items.ValueKind != JsonValueKind.Array)
			{
				return Error(StatusCodes.Status400BadRequest, "The batch has no items array.");
			}

			if (items.GetArrayLength() > SyncProtocol.MaxBatchItems)
			{
				return TooLarge();
			}

			var response = await applier.ApplyAsync(userId, deviceId, items, cancellationToken);
			return Results.Json(response, SyncJson.Options);
		}
	}

	// §4

	private static async Task<IResult> RequestsAsync(ClaimsPrincipal user, PhoneRequestService requests, CancellationToken cancellationToken)
	{
		var (userId, _) = Caller(user);
		var pending = await requests.PullAsync(userId, cancellationToken);
		return Results.Json(
			new RequestsResponse([.. pending.Select(r => new RequestWire(r.Id.ToString(), r.Kind.ToWire(), r.CreatedAt, r.ExpiresAt, r.Payload.RootElement))]),
			SyncJson.Options);
	}

	private static async Task<IResult> ResultAsync(
		Guid requestId,
		ClaimsPrincipal user,
		ResultRequest body,
		PhoneRequestService requests,
		CancellationToken cancellationToken)
	{
		var (userId, _) = Caller(user);
		if (!WireNames.TryParse(body.Status, out PhoneRequestState state) ||
			state is PhoneRequestState.Pending or PhoneRequestState.Expired)
		{
			return Error(StatusCodes.Status400BadRequest, "status must be done, failed, or unavailable.");
		}

		return await requests.RecordResultAsync(userId, requestId, state, body.Detail, cancellationToken)
			? Results.NoContent()
			: Results.NotFound();
	}

	private static async Task<IResult> ClipUploadAsync(
		Guid requestId,
		HttpContext context,
		PhoneRequestService requests,
		CancellationToken cancellationToken)
	{
		var (userId, _) = Caller(context.User);
		var request = context.Request;
		if (request.ContentType is not { } contentType || !contentType.StartsWith("audio/ogg", StringComparison.OrdinalIgnoreCase))
		{
			return Error(StatusCodes.Status415UnsupportedMediaType, "A clip is sent as audio/ogg.");
		}

		if (!TryReadOptionalInstant(request.Headers["X-Clip-Start-At"], out var coveredStart) ||
			!TryReadOptionalInstant(request.Headers["X-Clip-End-At"], out var coveredEnd))
		{
			return Error(StatusCodes.Status400BadRequest, "X-Clip-Start-At and X-Clip-End-At are RFC 3339 times.");
		}

		if (!TryReadGaps(request.Headers["X-Clip-Gaps"], out var gaps))
		{
			return Error(StatusCodes.Status400BadRequest, "X-Clip-Gaps is a JSON array of { startedAt, endedAt }.");
		}

		var upload = await requests.ReceiveClipAsync(userId, requestId, coveredStart, coveredEnd, gaps, request.Body, cancellationToken);
		return upload.Outcome switch
		{
			ClipUploadOutcome.Stored => Results.Json(new { clipId = upload.ClipId }, SyncJson.Options, statusCode: StatusCodes.Status201Created),
			ClipUploadOutcome.NotFound => Results.NotFound(),
			ClipUploadOutcome.NotOgg => Error(StatusCodes.Status400BadRequest, "The body is not an Ogg file."),
		};
	}

	// §5

	private static async Task<IResult> WipeAsync(ClaimsPrincipal user, WipeRequest body, ArchiveWipe wipe, TimeProvider time, CancellationToken cancellationToken)
	{
		var (userId, _) = Caller(user);
		if (body.Confirm != "wipe")
		{
			return Error(StatusCodes.Status400BadRequest, "Send { \"confirm\": \"wipe\" } to delete everything.");
		}

		await wipe.WipeAsync(userId, cancellationToken);
		return Results.Json(new { serverTime = time.GetUtcNow() }, SyncJson.Options);
	}

	private static async Task<IResult> StatusAsync(
		ClaimsPrincipal user,
		ArchiveDbContext db,
		ArchiveStatusService archive,
		PhoneRequestService requests,
		IConnectedAssistants assistants,
		TimeProvider time,
		CancellationToken cancellationToken)
	{
		var (userId, deviceId) = Caller(user);
		await requests.ExpireDueAsync(userId, cancellationToken);
		var status = await archive.GetAsync(userId, cancellationToken);
		var lastBatchAt = await db.Devices
			.Where(d => d.Id == deviceId)
			.Select(d => d.LastBatchAt)
			.SingleOrDefaultAsync(cancellationToken);
		var reads = await db.AiReads
			.AsNoTracking()
			.Where(a => a.UserId == userId)
			.OrderByDescending(a => a.At)
			.ThenByDescending(a => a.Id)
			.Take(20)
			.Select(a => new AiReadWire(a.At, a.Client, a.Tool, a.EntityIds))
			.ToListAsync(cancellationToken);
		var counts = status.Counts;
		var byKind = new Dictionary<string, int>
		{
			[SyncKind.Conversation.ToWire()] = counts.Conversations,
			[SyncKind.Transcript.ToWire()] = counts.Transcripts,
			[SyncKind.Recap.ToWire()] = counts.Recaps,
			[SyncKind.Brief.ToWire()] = counts.Briefs,
			[SyncKind.FollowUp.ToWire()] = counts.FollowUps,
			[SyncKind.Note.ToWire()] = counts.Notes,
			[SyncKind.Person.ToWire()] = counts.People,
			[SyncKind.Coverage.ToWire()] = counts.CoverageDays,
		};

		// For a backup import (§5): where what a phone sent begins (a backup import's own devices do not count), and
		// when the archive was last deleted, so it adds only what the phone no longer has.
		var phoneSince = await db.Conversations
			.Where(c => c.UserId == userId && db.SyncItems.Any(s =>
				s.UserId == userId && s.Kind == SyncKind.Conversation && s.EntityId == c.Id &&
				db.Devices.Any(d => d.Id == s.DeviceId && d.AppBuild != SyncProtocol.ImportBuild)))
			.MinAsync(c => (DateTimeOffset?)c.StartedAt, cancellationToken);
		var wipedAt = await db.SyncPreferences.Where(p => p.UserId == userId).Select(p => p.WipedAt).SingleOrDefaultAsync(cancellationToken);

		return Results.Json(
			new StatusResponse(
				time.GetUtcNow(),
				lastBatchAt,
				status.PendingRequests,
				byKind,
				reads,
				await assistants.ListAsync(userId, cancellationToken),
				phoneSince,
				wipedAt),
			SyncJson.Options);
	}

	private static async Task<IResult> RevokeAccessAsync(
		string kind,
		string id,
		ClaimsPrincipal user,
		IConnectedAssistants assistants,
		CancellationToken cancellationToken)
	{
		var (userId, _) = Caller(user);
		return await assistants.RevokeAsync(userId, kind, id, cancellationToken) ? Results.NoContent() : Results.NotFound();
	}

	private static async Task<IResult> GetPreferencesAsync(
		ClaimsPrincipal user,
		PhoneRequestService requests,
		SharingScopes scopes,
		CancellationToken cancellationToken)
	{
		var (userId, _) = Caller(user);
		var preferences = await requests.GetPreferencesAsync(userId, cancellationToken);
		return Results.Json(PreferencesWire.From(preferences, await scopes.GetAsync(userId, cancellationToken)), SyncJson.Options);
	}

	/// <summary>
	/// Stores what the phone allowed. A changed sharing scope takes effect at once: what now falls outside it is
	/// deleted before the answer goes back.
	/// </summary>
	private static async Task<IResult> PutPreferencesAsync(
		ClaimsPrincipal user,
		PreferencesUpdate body,
		PhoneRequestService requests,
		SharingScopes scopes,
		ScopeSweep sweep,
		ClipRetention clips,
		TimeProvider time,
		CancellationToken cancellationToken)
	{
		var (userId, deviceId) = Caller(user);
		SharingScopeKind? kind = null;
		if (body.Scope is { } scope)
		{
			if (!WireNames.TryParse(scope.Kind, out SharingScopeKind parsed))
			{
				return Error(StatusCodes.Status400BadRequest, "scope.kind must be all, since, or lastDays.");
			}

			if (parsed == SharingScopeKind.Since && scope.Since is null)
			{
				return Error(StatusCodes.Status400BadRequest, "scope.since is an RFC 3339 time for kind since.");
			}

			// A later start would delete everything now and drop every batch item until then, which the phone counts
			// as held. Only a phone bug or a wrong clock sends one; an hour covers clock drift.
			if (parsed == SharingScopeKind.Since && scope.Since > time.GetUtcNow() + SharingScopes.SinceClockSkew)
			{
				return Error(StatusCodes.Status400BadRequest, "scope.since is in the future; send a time up to now.");
			}

			if (parsed == SharingScopeKind.LastDays && scope.Days is not (>= 1 and <= SharingScopes.MaxDays))
			{
				return Error(StatusCodes.Status400BadRequest, $"scope.days is a whole number from 1 to {SharingScopes.MaxDays} for kind lastDays.");
			}

			kind = parsed;
		}

		var preferences = await requests.SetPreferencesAsync(userId, deviceId, body.Clips, body.Edits, cancellationToken);
		if (body.Clips == false)
		{
			// No audio for assistants any more: what the server has goes too, and links already given stop working.
			await clips.RemoveAllAsync(userId, cancellationToken);
		}

		if (kind is { } scopeKind && await scopes.SetAsync(userId, deviceId, scopeKind, body.Scope!.Since, body.Scope.Days, cancellationToken))
		{
			await sweep.RunAsync(userId, cancellationToken);
		}

		return Results.Json(PreferencesWire.From(preferences, await scopes.GetAsync(userId, cancellationToken)), SyncJson.Options);
	}

	// Clips

	private static async Task<IResult> ServeClipAsync(
		Guid clipId,
		string? exp,
		string? sig,
		HttpContext context,
		ClipLinks links,
		ClipStorage storage,
		ArchiveDbContext db,
		TimeProvider time,
		CancellationToken cancellationToken)
	{
		if (!links.Verify(clipId, exp, sig))
		{
			return Results.StatusCode(StatusCodes.Status403Forbidden);
		}

		var path = await db.Clips
			.AsNoTracking()
			.Where(c => c.Id == clipId && c.Status == ClipStatus.Ready)
			.Select(c => c.Path)
			.SingleOrDefaultAsync(cancellationToken);
		if (path is null)
		{
			return Results.NotFound();
		}

		var file = storage.Resolve(path);
		if (!File.Exists(file))
		{
			return Results.NotFound();
		}

		var remaining = long.Parse(exp!, System.Globalization.CultureInfo.InvariantCulture) - time.GetUtcNow().ToUnixTimeSeconds();
		context.Response.Headers.CacheControl = $"private, max-age={Math.Max(0, remaining)}";
		return TypedResults.PhysicalFile(file, "audio/mp4", enableRangeProcessing: true);
	}

	// Helpers

	private static (Guid UserId, Guid DeviceId) Caller(ClaimsPrincipal user) =>
		(user.UserId() ?? throw new InvalidOperationException("A sync request reached its handler without a user."),
			user.DeviceId() ?? throw new InvalidOperationException("A sync request reached its handler without a device."));

	private static IResult Error(int status, string message) =>
		Results.Json(new { error = message }, SyncJson.Options, statusCode: status);

	private static IResult TooLarge() =>
		Results.Json(
			new
			{
				error = "The batch is over the limit; send half.",
				maxItems = SyncProtocol.MaxBatchItems,
				maxBytes = SyncProtocol.MaxBatchBytes,
			},
			SyncJson.Options,
			statusCode: StatusCodes.Status413PayloadTooLarge);

	private static bool TryReadOptionalInstant(string? header, out DateTimeOffset? value)
	{
		value = null;
		if (string.IsNullOrEmpty(header))
		{
			return true;
		}

		if (!SyncJson.TryParseInstant(header, out var parsed))
		{
			return false;
		}

		value = parsed;
		return true;
	}

	private static bool TryReadGaps(string? header, out List<ClipGap> gaps)
	{
		gaps = [];
		if (string.IsNullOrWhiteSpace(header))
		{
			return true;
		}

		try
		{
			foreach (var gap in JsonSerializer.Deserialize<List<GapHeader?>>(header, SyncJson.Options) ?? [])
			{
				if (gap?.StartedAt is not { } start || gap.EndedAt is not { } end)
				{
					return false;
				}

				gaps.Add(new ClipGap { StartedAt = start, EndedAt = end });
			}

			return true;
		}
		catch (JsonException)
		{
			return false;
		}
	}

	internal sealed record GapHeader(DateTimeOffset? StartedAt, DateTimeOffset? EndedAt);

	internal sealed record LinkRequest(string? Code, string? DeviceName, string? AppVersion, string? AppBuild);

	internal sealed record LinkResponse(string DeviceId, string DeviceToken, string UserId, DateTimeOffset ServerTime);

	internal sealed record RequestsResponse(IReadOnlyList<RequestWire> Requests);

	internal sealed record RequestWire(string Id, string Kind, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, JsonElement Payload);

	internal sealed record ResultRequest(string? Status, string? Detail);

	internal sealed record WipeRequest(string? Confirm);

	internal sealed record StatusResponse(
		DateTimeOffset ServerTime,
		DateTimeOffset? LastBatchAt,
		int PendingRequests,
		IReadOnlyDictionary<string, int> Counts,
		IReadOnlyList<AiReadWire> AiReads,
		IReadOnlyList<AccessEntry> Access,
		DateTimeOffset? PhoneSince,
		DateTimeOffset? WipedAt);

	internal sealed record AiReadWire(DateTimeOffset At, string Client, string Tool, IReadOnlyList<string> Ids);

	internal sealed record PreferencesWire(bool Clips, bool Edits, ScopeWire Scope)
	{
		public static PreferencesWire From(SyncPreferences preferences, AccountScope scope) =>
			new(preferences.Clips, preferences.Edits, new ScopeWire(scope.Kind.ToWire(), scope.Since, scope.Days));
	}

	/// <summary>The sharing scope as §5 writes it: <c>since</c> only for that kind, <c>days</c> only for <c>lastDays</c>.</summary>
	internal sealed record ScopeWire(
		string Kind,
		[property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] DateTimeOffset? Since,
		[property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Days);

	internal sealed record PreferencesUpdate(bool? Clips, bool? Edits, ScopeUpdate? Scope);

	internal sealed record ScopeUpdate(string? Kind, DateTimeOffset? Since, int? Days);
}
