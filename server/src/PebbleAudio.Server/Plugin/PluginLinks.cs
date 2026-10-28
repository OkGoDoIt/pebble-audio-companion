using System.Security.Cryptography;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;
using PebbleAudio.Server.Sync;

namespace PebbleAudio.Server.Plugin;

/// <summary>
/// Connecting the Pebble plugin: the phone app asks for a one-time code (<c>POST /sync/plugin-code</c>, under its
/// device token) and shows it beside the plugin's install, and the plugin's settings page exchanges it at
/// <c>POST /plugin/link</c> for a read-only personal token named <see cref="TokenName"/>, which then lists, and is
/// disconnected, in Who can read under its own heading. Codes look and behave like a phone's (eight characters, ten
/// minutes, once) but live in their own table, so a plugin code never links a phone and a phone code never makes a
/// token.
/// </summary>
public sealed class PluginLinkService(ArchiveDbContext db, ApiTokenService tokens, TimeProvider time)
{
	/// <summary>What the token is called in Who can read and on the phone's privacy screen.</summary>
	public const string TokenName = "Pebble plugin";

	/// <summary>Mints a code; any earlier unused plugin code stops working, so only the one on screen connects.</summary>
	public async Task<MintedCode> MintAsync(Guid userId, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		await db.PluginLinkCodes
			.Where(c => c.UserId == userId && c.UsedAt == null && c.ExpiresAt > now)
			.ExecuteUpdateAsync(s => s.SetProperty(c => c.ExpiresAt, now), cancellationToken);

		for (var attempt = 0; ; attempt++)
		{
			var code = new string(RandomNumberGenerator.GetItems<char>(PhoneLinkService.Alphabet, SyncProtocol.LinkCodeLength));
			var row = new PluginLinkCode
			{
				Id = Guid.CreateVersion7(),
				UserId = userId,
				CodeHash = PhoneLinkService.Hash(code),
				CreatedAt = now,
				ExpiresAt = now + SyncProtocol.LinkCodeLifetime,
			};
			db.PluginLinkCodes.Add(row);
			try
			{
				await db.SaveChangesAsync(cancellationToken);
				return new MintedCode(code, row.ExpiresAt);
			}
			catch (DbUpdateException ex) when (attempt < 3 && ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
			{
				db.ChangeTracker.Clear();
			}
		}
	}

	/// <summary>
	/// Whether the plugin is connected (a live personal token named for it), and when it last read with one. What the
	/// phone's Settings › Watch shows (<c>GET /sync/plugin</c>).
	/// </summary>
	public async Task<PluginConnection> ConnectionAsync(Guid userId, CancellationToken cancellationToken)
	{
		var uses = await db.ApiTokens
			.AsNoTracking()
			.Where(t => t.UserId == userId && t.RevokedAt == null && t.Name == TokenName)
			.Select(t => t.LastUsedAt)
			.ToListAsync(cancellationToken);
		return new PluginConnection(uses.Count > 0, uses.Max());
	}

	/// <summary>An access entry that is the plugin, not an assistant: the name its link gives it.</summary>
	public static bool IsPlugin(AccessEntry entry) =>
		entry.Kind == TokenAssistantSource.KindName && string.Equals(entry.Name.Trim(), TokenName, StringComparison.OrdinalIgnoreCase);

	/// <summary>
	/// Exchanges a live, unused code for a new read-only token, returned once. Null when the code is unknown, used, or
	/// expired. Case, spaces, and dashes do not matter.
	/// </summary>
	public async Task<string?> ExchangeAsync(string? code, CancellationToken cancellationToken)
	{
		var normalized = PhoneLinkService.Normalize(code);
		if (normalized.Length != SyncProtocol.LinkCodeLength)
		{
			return null;
		}

		var hash = PhoneLinkService.Hash(normalized);
		var now = time.GetUtcNow();
		await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
		var row = await db.PluginLinkCodes
			.AsNoTracking()
			.SingleOrDefaultAsync(c => c.CodeHash == hash && c.UsedAt == null && c.ExpiresAt > now, cancellationToken);
		if (row is null)
		{
			return null;
		}

		// Claimed with a condition, so two plugins racing for one code cannot both win it.
		var claimed = await db.PluginLinkCodes
			.Where(c => c.Id == row.Id && c.UsedAt == null)
			.ExecuteUpdateAsync(s => s.SetProperty(c => c.UsedAt, now), cancellationToken);
		if (claimed == 0)
		{
			return null;
		}

		var (token, secret) = await tokens.CreateAsync(row.UserId, TokenName, TokenAccess.Read, cancellationToken);
		await db.PluginLinkCodes
			.Where(c => c.Id == row.Id)
			.ExecuteUpdateAsync(s => s.SetProperty(c => c.ApiTokenId, token.Id), cancellationToken);
		await transaction.CommitAsync(cancellationToken);
		return secret;
	}
}

/// <param name="Connected">A live token named for the plugin exists.</param>
/// <param name="LastUsedAt">The latest read with one; null before the first.</param>
public sealed record PluginConnection(bool Connected, DateTimeOffset? LastUsedAt);
