namespace PebbleAudio.Server.Sync;

/// <summary>
/// One kind of assistant access to the archive (OAuth connections, personal tokens). <c>GET /sync/status</c> lists
/// every source's entries as <c>access</c>, and <c>DELETE /sync/access/{kind}/{id}</c> revokes one
/// (sync-protocol.md §5). Register each source as an <see cref="IConnectedAssistantSource"/>.
/// </summary>
public interface IConnectedAssistantSource
{
	/// <summary>
	/// The assistants that can read the user's archive right now. Revoked or expired access is not listed.
	/// </summary>
	Task<IReadOnlyList<ConnectedAssistant>> ListAsync(Guid userId, CancellationToken cancellationToken);

	/// <summary>
	/// Revokes one entry. Returns false when this source has no such entry (another kind, or already gone).
	/// </summary>
	Task<bool> RevokeAsync(Guid userId, string kind, string id, CancellationToken cancellationToken);
}

/// <summary>
/// One <c>access</c> entry: <c>{ kind, id, name, scopes, connectedAt, lastUsedAt }</c>.
/// </summary>
/// <param name="Kind"><c>oauth</c> or <c>token</c>.</param>
/// <param name="Id">The source's own id for it, passed back to <see cref="IConnectedAssistantSource.RevokeAsync"/>.</param>
/// <param name="Name">What the person sees, for example <c>ChatGPT</c>.</param>
/// <param name="Scopes">For example <c>archive:read</c>; <c>archive:write</c> means it can also add to the archive.</param>
/// <param name="ConnectedAt">When the access was granted.</param>
/// <param name="LastUsedAt">When it last opened the archive, if ever.</param>
public sealed record ConnectedAssistant(
	string Kind,
	string Id,
	string Name,
	IReadOnlyList<string> Scopes,
	DateTimeOffset ConnectedAt,
	DateTimeOffset? LastUsedAt);
