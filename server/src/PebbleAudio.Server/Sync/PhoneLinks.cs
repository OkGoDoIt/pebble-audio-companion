using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Threading.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using PebbleAudio.Server.Data;
using QRCoder;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// Linking a phone (sync-protocol.md §1): one-time codes minted in the admin area, the exchange of a code for a
/// device token, and the list of linked phones. Codes and tokens are stored only as SHA-256 hashes.
/// </summary>
public sealed class PhoneLinkService(ArchiveDbContext db, TimeProvider time)
{
	/// <summary>No I, L, O, 0, or 1: nothing a person could misread when typing it.</summary>
	private const string Alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

	public const int NameLength = 80;

	/// <summary>
	/// Mints a code for <paramref name="userId"/>. Any earlier unused code stops working, so only the one on screen
	/// links a phone.
	/// </summary>
	public async Task<MintedCode> MintAsync(Guid userId, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		await db.LinkCodes
			.Where(c => c.UserId == userId && c.UsedAt == null && c.ExpiresAt > now)
			.ExecuteUpdateAsync(s => s.SetProperty(c => c.ExpiresAt, now), cancellationToken);

		for (var attempt = 0; ; attempt++)
		{
			var code = new string(RandomNumberGenerator.GetItems<char>(Alphabet, SyncProtocol.LinkCodeLength));
			var row = new LinkCode
			{
				Id = Guid.CreateVersion7(),
				UserId = userId,
				CodeHash = Hash(code),
				CreatedAt = now,
				ExpiresAt = now + SyncProtocol.LinkCodeLifetime,
			};
			db.LinkCodes.Add(row);
			try
			{
				await db.SaveChangesAsync(cancellationToken);
				return new MintedCode(code, row.ExpiresAt);
			}
			catch (DbUpdateException ex) when (attempt < 3 && ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
			{
				// The same code was minted before (one in 10^11); draw another.
				db.ChangeTracker.Clear();
			}
		}
	}

	/// <summary>
	/// Exchanges a live, unused code for a new device and its token. Null when the code is unknown, used, or
	/// expired.
	/// </summary>
	public async Task<LinkedPhone?> LinkAsync(
		string? code,
		string? deviceName,
		string? appVersion,
		string? appBuild,
		CancellationToken cancellationToken)
	{
		var normalized = Normalize(code);
		if (normalized.Length != SyncProtocol.LinkCodeLength)
		{
			return null;
		}

		var hash = Hash(normalized);
		var now = time.GetUtcNow();
		await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
		var row = await db.LinkCodes
			.AsNoTracking()
			.SingleOrDefaultAsync(c => c.CodeHash == hash && c.UsedAt == null && c.ExpiresAt > now, cancellationToken);
		if (row is null)
		{
			return null;
		}

		var device = new Device
		{
			Id = Guid.CreateVersion7(),
			UserId = row.UserId,
			Name = CleanName(deviceName) ?? "iPhone",
			AppVersion = Clip(appVersion, 40),
			AppBuild = Clip(appBuild, 40),
			LinkedAt = now,
		};
		var token = SyncAuth.NewToken();
		device.TokenHash = SyncAuth.Hash(token);

		// Claimed with a condition, so two phones racing for one code cannot both win it.
		var claimed = await db.LinkCodes
			.Where(c => c.Id == row.Id && c.UsedAt == null)
			.ExecuteUpdateAsync(
				s => s.SetProperty(c => c.UsedAt, now).SetProperty(c => c.DeviceId, device.Id),
				cancellationToken);
		if (claimed == 0)
		{
			return null;
		}

		db.Devices.Add(device);
		await db.SaveChangesAsync(cancellationToken);
		await transaction.CommitAsync(cancellationToken);
		return new LinkedPhone(device, token);
	}

	/// <summary>The user's linked phones, most recently linked first.</summary>
	public Task<List<Device>> ListAsync(Guid userId, CancellationToken cancellationToken) =>
		db.Devices
			.AsNoTracking()
			.Where(d => d.UserId == userId && d.UnlinkedAt == null)
			.OrderByDescending(d => d.LinkedAt)
			.ToListAsync(cancellationToken);

	public async Task<bool> RenameAsync(Guid userId, Guid deviceId, string? name, CancellationToken cancellationToken)
	{
		if (CleanName(name) is not { } cleaned)
		{
			return false;
		}

		return await db.Devices
			.Where(d => d.Id == deviceId && d.UserId == userId && d.UnlinkedAt == null)
			.ExecuteUpdateAsync(s => s.SetProperty(d => d.Name, cleaned), cancellationToken) > 0;
	}

	/// <summary>
	/// Revokes the phone's token at once. Its data stays; linking again starts a new device.
	/// </summary>
	public async Task<bool> UnlinkAsync(Guid userId, Guid deviceId, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		return await db.Devices
			.Where(d => d.Id == deviceId && d.UserId == userId && d.UnlinkedAt == null)
			.ExecuteUpdateAsync(s => s.SetProperty(d => d.UnlinkedAt, now), cancellationToken) > 0;
	}

	/// <summary>What a person might type for a code: case, spaces, and dashes are not part of it.</summary>
	public static string Normalize(string? code) =>
		new((code ?? "").Where(char.IsAsciiLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

	/// <summary><c>K7QM3XWD</c> as <c>K7QM-3XWD</c>, easier to read off a screen.</summary>
	public static string Display(string code) =>
		code.Length == SyncProtocol.LinkCodeLength ? $"{code[..4]}-{code[4..]}" : code;

	/// <summary>
	/// The link the QR code carries: <c>{origin}/link?code=…</c>, a universal link the app opens from the Camera (the
	/// app-site association claims <c>/link*</c>). Without the app it is the /link page, which shows the code. The app
	/// still accepts the older <c>pebbleaudio://link?code=…&amp;origin=…</c>.
	/// </summary>
	public static string InvitationUrl(string code, string publicOrigin) =>
		$"{publicOrigin}/link?code={Uri.EscapeDataString(code)}";

	private static byte[] Hash(string normalizedCode) => SHA256.HashData(Encoding.UTF8.GetBytes(normalizedCode));

	private static string? CleanName(string? name) => Clip(name, NameLength);

	private static string? Clip(string? value, int length)
	{
		var trimmed = value?.Trim();
		if (string.IsNullOrEmpty(trimmed))
		{
			return null;
		}

		return trimmed.Length > length ? trimmed[..length] : trimmed;
	}
}

/// <param name="Code">The code, shown once; only its hash is stored.</param>
/// <param name="ExpiresAt">When it stops working.</param>
public sealed record MintedCode(string Code, DateTimeOffset ExpiresAt);

/// <param name="Device">The new device.</param>
/// <param name="Token">Its token, returned to the phone once.</param>
public sealed record LinkedPhone(Device Device, string Token);

/// <summary>
/// Slows down guessing at <c>POST /link</c>: each address gets ten wrong codes per ten minutes, then a 429 until
/// the window turns. Right codes cost nothing, since only the admin area can mint them.
/// </summary>
public sealed class LinkAttemptLimiter : IDisposable
{
	public const int FailuresPerWindow = 10;

	public static readonly TimeSpan Window = TimeSpan.FromMinutes(10);

	private readonly PartitionedRateLimiter<string> _failures = PartitionedRateLimiter.Create<string, string>(
		address => RateLimitPartition.GetFixedWindowLimiter(address, _ => new FixedWindowRateLimiterOptions
		{
			PermitLimit = FailuresPerWindow,
			Window = Window,
			QueueLimit = 0,
			AutoReplenishment = true,
		}));

	public bool IsBlocked(string address) => _failures.GetStatistics(address)?.CurrentAvailablePermits <= 0;

	public void RecordFailure(string address)
	{
		using var lease = _failures.AttemptAcquire(address);
	}

	public void Dispose() => _failures.Dispose();
}

/// <summary>
/// Draws a QR code as inline SVG: one path of dark modules on a white tile with the standard quiet zone. The
/// tile stays white in dark mode, because cameras read dark-on-light codes most reliably.
/// </summary>
public static class LinkQrCode
{
	public static string Svg(string text, string label)
	{
		using var generator = new QRCodeGenerator();
		using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
		var matrix = data.ModuleMatrix;
		var size = matrix.Count;

		var path = new StringBuilder();
		for (var y = 0; y < size; y++)
		{
			var row = matrix[y];
			for (var x = 0; x < size; x++)
			{
				if (!row[x])
				{
					continue;
				}

				// Runs of dark modules become one rectangle each.
				var start = x;
				while (x + 1 < size && row[x + 1])
				{
					x++;
				}

				path.Append(CultureInfo.InvariantCulture, $"M{start} {y}h{x - start + 1}v1h-{x - start + 1}z");
			}
		}

		var escaped = System.Net.WebUtility.HtmlEncode(label);
		return $"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" role="img" aria-label="{escaped}" shape-rendering="crispEdges"><rect width="{size}" height="{size}" fill="#fff"/><path d="{path}" fill="#000"/></svg>""";
	}
}
