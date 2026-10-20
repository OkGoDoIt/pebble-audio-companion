using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Auth;

/// <summary>
/// Creates, checks, and revokes the <c>pat_</c> bearer tokens that assistants and command-line tools use.
/// A token is shown once when it is created; the database keeps only its SHA-256 hash.
/// </summary>
public sealed class ApiTokenService(ArchiveDbContext db, TimeProvider time)
{
	public const string Prefix = "pat_";

	/// <summary>
	/// Creates a token and returns it with the secret, which cannot be recovered later.
	/// </summary>
	public async Task<(ApiToken Token, string Secret)> CreateAsync(
		Guid userId,
		string name,
		TokenAccess access,
		CancellationToken cancellationToken)
	{
		var secret = Prefix + Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(32));
		var token = new ApiToken
		{
			Id = Guid.CreateVersion7(),
			UserId = userId,
			Name = name.Trim(),
			Access = access,
			TokenHash = Hash(secret),
			Preview = secret[..(Prefix.Length + 4)],
			CreatedAt = time.GetUtcNow(),
		};

		db.ApiTokens.Add(token);
		await db.SaveChangesAsync(cancellationToken);
		return (token, secret);
	}

	/// <summary>
	/// Returns the live token with this secret, or null. Notes the time of use at most once a minute.
	/// </summary>
	public async Task<ApiToken?> FindActiveAsync(string secret, CancellationToken cancellationToken)
	{
		if (!secret.StartsWith(Prefix, StringComparison.Ordinal))
		{
			return null;
		}

		var hash = Hash(secret);
		var token = await db.ApiTokens
			.AsNoTracking()
			.SingleOrDefaultAsync(t => t.TokenHash == hash && t.RevokedAt == null, cancellationToken);
		if (token is null)
		{
			return null;
		}

		var now = time.GetUtcNow();
		if (token.LastUsedAt is null || now - token.LastUsedAt > TimeSpan.FromMinutes(1))
		{
			await db.ApiTokens
				.Where(t => t.Id == token.Id)
				.ExecuteUpdateAsync(s => s.SetProperty(t => t.LastUsedAt, now), cancellationToken);
			token.LastUsedAt = now;
		}

		return token;
	}

	/// <summary>
	/// The user's live tokens, newest first.
	/// </summary>
	public Task<List<ApiToken>> ListAsync(Guid userId, CancellationToken cancellationToken) =>
		db.ApiTokens
			.AsNoTracking()
			.Where(t => t.UserId == userId && t.RevokedAt == null)
			.OrderByDescending(t => t.CreatedAt)
			.ToListAsync(cancellationToken);

	/// <summary>
	/// Revokes a token at once; the next request that carries it gets a 401.
	/// </summary>
	public async Task<bool> RevokeAsync(Guid userId, Guid tokenId, CancellationToken cancellationToken)
	{
		var now = time.GetUtcNow();
		var changed = await db.ApiTokens
			.Where(t => t.Id == tokenId && t.UserId == userId && t.RevokedAt == null)
			.ExecuteUpdateAsync(s => s.SetProperty(t => t.RevokedAt, now), cancellationToken);
		return changed > 0;
	}

	public static byte[] Hash(string secret) => SHA256.HashData(Encoding.UTF8.GetBytes(secret));
}
