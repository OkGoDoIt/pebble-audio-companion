using System.Buffers.Text;
using System.Globalization;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Names for the phone's own authentication. A device token (<c>pad_…</c>) opens <c>/sync/*</c> and nothing else;
/// the <c>pat_</c> bearer scheme opens <c>/mcp</c> and nothing else. Each handler accepts only its own prefix, and
/// each policy names only its own scheme, so neither token works on the other's surface.
/// </summary>
public static class SyncAuth
{
	public const string Scheme = "DeviceToken";

	public const string Policy = "Sync";

	public const string TokenPrefix = "pad_";

	public const string DeviceIdClaim = "pebbleaudio:device_id";

	public static Guid? DeviceId(this ClaimsPrincipal? principal) =>
		Guid.TryParse(principal?.FindFirstValue(DeviceIdClaim), CultureInfo.InvariantCulture, out var id) ? id : null;

	public static string NewToken() => TokenPrefix + Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(32));

	public static byte[] Hash(string token) => SHA256.HashData(Encoding.UTF8.GetBytes(token));
}

/// <summary>
/// Authenticates <c>Authorization: Bearer pad_…</c> against the Devices table. An unlinked phone's token fails.
/// Notes when the phone was last seen, at most once a minute.
/// </summary>
public sealed class DeviceTokenHandler(
	IOptionsMonitor<AuthenticationSchemeOptions> options,
	ILoggerFactory logger,
	UrlEncoder encoder,
	ArchiveDbContext db,
	TimeProvider time)
	: AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
	private const string BearerPrefix = "Bearer ";

	protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
	{
		var header = Request.Headers.Authorization.ToString();
		if (!header.StartsWith(BearerPrefix, StringComparison.OrdinalIgnoreCase))
		{
			return AuthenticateResult.NoResult();
		}

		var token = header[BearerPrefix.Length..].Trim();
		if (!token.StartsWith(SyncAuth.TokenPrefix, StringComparison.Ordinal))
		{
			return AuthenticateResult.Fail("This is not a device token.");
		}

		var hash = SyncAuth.Hash(token);
		var device = await db.Devices
			.AsNoTracking()
			.Where(d => d.TokenHash == hash && d.UnlinkedAt == null)
			.Select(d => new { d.Id, d.UserId, d.LastSeenAt })
			.SingleOrDefaultAsync(Context.RequestAborted);
		if (device is null)
		{
			return AuthenticateResult.Fail("The device token is unknown or the phone was unlinked.");
		}

		var now = time.GetUtcNow();
		if (device.LastSeenAt is null || now - device.LastSeenAt > TimeSpan.FromMinutes(1))
		{
			await db.Devices
				.Where(d => d.Id == device.Id)
				.ExecuteUpdateAsync(s => s.SetProperty(d => d.LastSeenAt, now), Context.RequestAborted);
		}

		var identity = new ClaimsIdentity(Scheme.Name);
		identity.AddClaim(new Claim(ClaimTypes.NameIdentifier, device.UserId.ToString()));
		identity.AddClaim(new Claim(SyncAuth.DeviceIdClaim, device.Id.ToString()));
		return AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name));
	}

	protected override Task HandleChallengeAsync(AuthenticationProperties properties)
	{
		Response.StatusCode = StatusCodes.Status401Unauthorized;
		Response.Headers.WWWAuthenticate = "Bearer";
		return Task.CompletedTask;
	}
}
