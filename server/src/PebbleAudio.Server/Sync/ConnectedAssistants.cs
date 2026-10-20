using System.Globalization;
using PebbleAudio.Server.Auth;

namespace PebbleAudio.Server.Sync;

/// <summary>
/// One assistant that can read the archive right now, as the phone's privacy screen names it
/// (sync-protocol.md §5, <c>access</c>).
/// </summary>
/// <param name="Kind"><c>oauth</c> or <c>token</c>.</param>
/// <param name="Id">Its id within its kind, for <c>DELETE /sync/access/{kind}/{id}</c>.</param>
/// <param name="Name">A human name: ChatGPT, Claude, or what the person called a token.</param>
/// <param name="Scopes">What it may do; <c>archive:write</c> means it can also add follow-ups and notes.</param>
/// <param name="ConnectedAt">When it was given access.</param>
/// <param name="LastUsedAt">When it last used it, if ever.</param>
public sealed record AccessEntry(
	string Kind,
	string Id,
	string Name,
	IReadOnlyList<string> Scopes,
	DateTimeOffset ConnectedAt,
	DateTimeOffset? LastUsedAt);

/// <summary>
/// Every assistant with access to a user's archive, from every kind of access there is.
/// </summary>
public interface IConnectedAssistants
{
	Task<IReadOnlyList<AccessEntry>> ListAsync(Guid userId, CancellationToken cancellationToken);

	/// <summary>Revokes one assistant's access at once. False when there is no such live access.</summary>
	Task<bool> RevokeAsync(Guid userId, string kind, string id, CancellationToken cancellationToken);

	/// <summary>
	/// Ends every assistant's access to the user's archive, from every source, on the caller's database context (so
	/// inside its transaction, if one is open). Returns how many were live.
	/// </summary>
	Task<int> RevokeAllAsync(Guid userId, CancellationToken cancellationToken);
}

/// <summary>
/// One kind of access. Personal tokens are one source; OAuth grants register another with
/// <c>services.AddScoped&lt;IConnectedAssistantSource, …&gt;()</c>.
/// </summary>
public interface IConnectedAssistantSource
{
	/// <summary>The <c>kind</c> its entries carry, for example <c>token</c>.</summary>
	string Kind { get; }

	/// <summary>Live access only: nothing revoked or expired.</summary>
	Task<IReadOnlyList<AccessEntry>> ListAsync(Guid userId, CancellationToken cancellationToken);

	Task<bool> RevokeAsync(Guid userId, string id, CancellationToken cancellationToken);

	/// <summary>Ends all of this kind of access for the user, including anything not yet live. Returns how many were live.</summary>
	Task<int> RevokeAllAsync(Guid userId, CancellationToken cancellationToken);
}

/// <summary>Asks every registered source and lists what they say, most recently used first.</summary>
public sealed class ConnectedAssistants(IEnumerable<IConnectedAssistantSource> sources) : IConnectedAssistants
{
	public async Task<IReadOnlyList<AccessEntry>> ListAsync(Guid userId, CancellationToken cancellationToken)
	{
		var entries = new List<AccessEntry>();
		foreach (var source in sources)
		{
			entries.AddRange(await source.ListAsync(userId, cancellationToken));
		}

		return [.. entries.OrderByDescending(e => e.LastUsedAt ?? e.ConnectedAt)];
	}

	public async Task<bool> RevokeAsync(Guid userId, string kind, string id, CancellationToken cancellationToken)
	{
		foreach (var source in sources.Where(s => s.Kind == kind))
		{
			if (await source.RevokeAsync(userId, id, cancellationToken))
			{
				return true;
			}
		}

		return false;
	}

	public async Task<int> RevokeAllAsync(Guid userId, CancellationToken cancellationToken)
	{
		var revoked = 0;
		foreach (var source in sources)
		{
			revoked += await source.RevokeAllAsync(userId, cancellationToken);
		}

		return revoked;
	}
}

/// <summary>The personal access tokens (<c>pat_…</c>) made in the admin area, named by the person.</summary>
public sealed class TokenAssistantSource(ApiTokenService tokens) : IConnectedAssistantSource
{
	public const string KindName = "token";

	public string Kind => KindName;

	public async Task<IReadOnlyList<AccessEntry>> ListAsync(Guid userId, CancellationToken cancellationToken) =>
		[
			.. (await tokens.ListAsync(userId, cancellationToken)).Select(t => new AccessEntry(
				KindName,
				t.Id.ToString(),
				t.Name,
				ArchiveScopes.For(t.Access),
				t.CreatedAt,
				t.LastUsedAt)),
		];

	public Task<bool> RevokeAsync(Guid userId, string id, CancellationToken cancellationToken) =>
		Guid.TryParse(id, CultureInfo.InvariantCulture, out var tokenId)
			? tokens.RevokeAsync(userId, tokenId, cancellationToken)
			: Task.FromResult(false);

	public Task<int> RevokeAllAsync(Guid userId, CancellationToken cancellationToken) =>
		tokens.RevokeAllAsync(userId, cancellationToken);
}
